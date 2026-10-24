import Foundation

/// The Jarvis Action Engine.
///
/// ```
/// text → Interpreter → ToolPlan → Validation → Permission check → Duplicate guard → Execution → Verified result → response
/// ```
///
/// The engine is a plain Swift actor with no UI dependency, so it can be hosted by the SwiftUI app, a
/// menu-bar item, the local IPC server or a future voice front-end alike. It owns all cross-cutting
/// behaviour (validation, permissions, confirmation of destructive actions, ambiguity handling, duplicate
/// suppression, timeouts, cancellation, history) so integrations only implement their own tools.
public actor ActionEngine {
    public struct Limits: Sendable {
        public var maxInputCharacters = 20_000
        public var pendingLifetime: TimeInterval = 600
        public var maxPending = 64
        public init() {}
    }

    public nonisolated let registry: ToolRegistry
    private let interpreter: any CommandInterpreting
    private let settingsProvider: any SettingsProviding
    private let history: (any HistoryRecording)?
    private let dateProvider: any DateProviding
    private let limits: Limits
    /// Language used for replies when the text gives no hint and no language is fixed in the settings.
    private let fallbackLanguage: Language

    private var pending = PendingActionStore()
    private var duplicates = DuplicateGuard()
    private var uncertainWrites: [String: Date] = [:]
    private var conversations: [String: [ConversationTurn]] = [:]
    private var sessionRevisions: [String: Int] = [:]
    private struct Workflow: Sendable {
        var request: CommandRequest
        var interpretation: InterpretationRequest
        var results: [ToolResult]
        var round: Int
        var revision: Int
        var completedWrites: Set<String> = []
    }
    private var suspended: [UUID: Workflow] = [:]

    public func clearSession(_ session: String) {
        sessionRevisions[session, default: 0] += 1
        conversations[session] = nil
        for item in pending.items.values where item.session == session {
            _ = pending.take(token: item.token)
            suspended[item.commandID] = nil
        }
    }

    private func remember(_ response: EngineResponse, request: CommandRequest, settings: JarvisSettings) {
        guard response.status != .cancelled else { return }
        guard settings.rememberSession else {
            conversations[request.session] = nil
            return
        }
        // Never retain pending confirmations as authority for a subsequent command.
        var turns = conversations[request.session] ?? []
        turns.append(
            ConversationTurn(
                text: String(request.text.prefix(4000)), results: Array(response.results.suffix(20)),
                summary: String(response.message.prefix(4000))))
        conversations[request.session] = Array(turns.suffix(8))
        if conversations.count > 32, let oldest = conversations.keys.sorted().first(where: { $0 != request.session }) {
            conversations[oldest] = nil
        }
    }

    public init(
        registry: ToolRegistry,
        interpreter: any CommandInterpreting,
        settings: any SettingsProviding,
        history: (any HistoryRecording)? = nil,
        dateProvider: any DateProviding = SystemDateProvider(),
        limits: Limits = Limits(),
        fallbackLanguage: Language = .en
    ) {
        self.registry = registry
        self.interpreter = interpreter
        self.settingsProvider = settings
        self.history = history
        self.dateProvider = dateProvider
        self.limits = limits
        self.fallbackLanguage = fallbackLanguage
    }

    // MARK: - Public API

    /// Interprets and executes a natural-language command.
    public func process(_ request: CommandRequest, onEvent: EngineEventHandler? = nil) async -> EngineResponse {
        let clock = ContinuousClock()
        let began = clock.now
        let startedAt = dateProvider.now()
        let commandID = UUID()
        let settings = settingsProvider.snapshot()
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let language = resolveLanguage(request.language, text: text, settings: settings)

        var response = await handle(
            text: text, request: request, commandID: commandID, language: language, settings: settings, onEvent: onEvent
        )
        response.id = commandID
        response.startedAt = startedAt
        response.durationMs = Self.milliseconds(since: began, clock: clock)
        remember(response, request: request, settings: settings)
        if settings.saveHistory && settings.saveConversations { await history?.updateConversation(response) }
        await record(
            response, request: request, settings: settings,
            isReply: ReplyClassifier.classify(text, optionCount: 0) != nil)
        return response
    }

    /// Runs one structured tool call directly, skipping interpretation (IPC `tool` requests, option buttons).
    ///
    /// `recordHistory: false` is for housekeeping reads (filling Settings pickers) that are not user commands.
    public func execute(
        _ call: ToolCall, language: Language? = nil, source: CommandSource = .app, session: String = "default",
        allowDuplicate: Bool = false, recordHistory: Bool = true, onEvent: EngineEventHandler? = nil
    ) async -> EngineResponse {
        let clock = ContinuousClock()
        let began = clock.now
        let startedAt = dateProvider.now()
        let commandID = UUID()
        let settings = settingsProvider.snapshot()
        let lang = language ?? settings.languagePreference.fixedLanguage ?? fallbackLanguage
        let plan = ToolPlan(steps: [call], language: lang, interpreter: "direct")
        let request = CommandRequest(
            text: "\(call.tool.rawValue)", language: lang, source: source, session: session,
            allowDuplicate: allowDuplicate)
        var response = await run(
            plan: plan, input: request.text, request: request, commandID: commandID, settings: settings,
            onEvent: onEvent)
        response.id = commandID
        response.startedAt = startedAt
        response.durationMs = Self.milliseconds(since: began, clock: clock)
        if recordHistory {
            remember(response, request: request, settings: settings)
            await record(response, request: request, settings: settings, isReply: false)
        }
        return response
    }

    /// Confirms, cancels or chooses an option of a pending request.
    public func resolve(
        token: String, decision: PendingDecision, language: Language? = nil, source: CommandSource = .app,
        onEvent: EngineEventHandler? = nil
    ) async -> EngineResponse {
        let clock = ContinuousClock()
        let began = clock.now
        let startedAt = dateProvider.now()
        let settings = settingsProvider.snapshot()
        let lang = language ?? settings.languagePreference.fixedLanguage ?? fallbackLanguage
        pending.purgeExpired(now: dateProvider.now(), lifetime: limits.pendingLifetime)
        let waitingIDs = Set(pending.items.values.map(\.commandID))
        suspended = suspended.filter { waitingIDs.contains($0.key) }

        var response = await resolveInternal(
            token: token, decision: decision, language: lang, source: source, settings: settings, onEvent: onEvent)
        response.startedAt = startedAt
        response.durationMs = Self.milliseconds(since: began, clock: clock)
        if settings.saveHistory && settings.saveConversations { await history?.updateConversation(response) }
        return response
    }

    /// Number of unresolved confirmations/clarifications (for diagnostics and tests).
    public var pendingCount: Int { pending.items.count }

    // MARK: - Command handling

    private func handle(
        text: String, request: CommandRequest, commandID: UUID, language: Language, settings: JarvisSettings,
        onEvent: EngineEventHandler?
    ) async -> EngineResponse {
        func response(_ status: EngineResponse.Status, _ message: String, interpreter: String = "none")
            -> EngineResponse
        {
            EngineResponse(
                id: commandID, input: text, language: language, status: status, message: message,
                interpreter: interpreter)
        }

        if text.isEmpty {
            return response(
                .unrecognized,
                language.pick(
                    "Type a command, for example “Play my Study playlist”.",
                    "Escribe un comando, por ejemplo «Pon mi lista Study»."))
        }
        if text.count > limits.maxInputCharacters {
            return response(
                .failed,
                language.pick(
                    "That command is too long (limit: \(limits.maxInputCharacters) characters).",
                    "Ese comando es demasiado largo (límite: \(limits.maxInputCharacters) caracteres)."))
        }

        pending.purgeExpired(now: dateProvider.now(), lifetime: limits.pendingLifetime)
        let waitingIDs = Set(pending.items.values.map(\.commandID))
        suspended = suspended.filter { waitingIDs.contains($0.key) }

        // "yes", "cancel", "2", "la primera" … answer the most recent pending question of this session.
        if let waiting = pending.latest(session: request.session),
            let decision = ReplyClassifier.classify(
                text, optionCount: waiting.optionLabels.count, optionLabels: waiting.optionLabels)
        {
            return await resolveInternal(
                token: waiting.token, decision: decision, language: language, source: request.source,
                settings: settings, onEvent: onEvent)
        }

        sessionRevisions[request.session, default: 0] += 1
        let revision = sessionRevisions[request.session] ?? 0
        if sessionRevisions.count > 256, let key = sessionRevisions.keys.first(where: { $0 != request.session }) {
            sessionRevisions[key] = nil
        }
        // A correction/new instruction supersedes unanswered actions from this session.
        // Old confirmation buttons must not apply the scope the user just changed.
        for item in pending.items.values.filter({ $0.session == request.session }) {
            _ = pending.take(token: item.token)
            suspended[item.commandID] = nil
        }

        let calendar = dateProvider.calendar()
        var interpretationRequest = InterpretationRequest(
            text: text, language: language, now: dateProvider.now(), calendar: calendar, settings: settings,
            tools: registry.descriptors
        )
        interpretationRequest.onText = { text in onEvent?(.responseText(commandID: commandID, text: text)) }
        interpretationRequest.conversation = settings.rememberSession ? conversations[request.session] ?? [] : []

        let interpretation: Interpretation
        do {
            interpretation = try await interpreter.interpret(interpretationRequest)
        } catch is CancellationError {
            return response(.cancelled, language.pick("Cancelled.", "Cancelado."))
        } catch {
            JarvisLog.engine.error("Interpreter failed: \(String(describing: type(of: error)), privacy: .public)")
            return response(
                .failed,
                language.pick(
                    "I couldn't work out what to do with that. Try rephrasing it.",
                    "No pude entender qué hacer con eso. Intenta reformularlo."), interpreter: interpreter.identifier)
        }

        switch interpretation {
        case .plan(let plan):
            if plan.continues || interpreter.identifier == "agent", sessionRevisions[request.session] != revision {
                return response(
                    .cancelled,
                    language.pick("Superseded by a newer instruction.", "Sustituido por una instrucción más reciente."))
            }
            if plan.continues {
                let workflow = Workflow(
                    request: request, interpretation: interpretationRequest, results: [], round: 0, revision: revision)
                return await runWorkflow(
                    workflow, next: plan, commandID: commandID, settings: settings, onEvent: onEvent)
            }
            return await run(
                plan: plan, input: text, request: request, commandID: commandID, settings: settings, onEvent: onEvent)

        case .clarification(var clarification):
            if !clarification.options.isEmpty {
                clarification.token = pending.add(
                    session: request.session, commandID: commandID, kind: .clarification(clarification),
                    now: dateProvider.now(), capacity: limits.maxPending
                )
            }
            var result = EngineResponse(
                id: commandID, input: text, language: language, status: .needsClarification,
                message: clarification.question, interpreter: interpreter.identifier)
            result.results = [
                ToolResult(
                    callID: UUID(), tool: "clarification", status: .needsClarification, message: clarification.question,
                    clarification: clarification)
            ]
            return result

        case .reply(let message):
            return response(.reply, message, interpreter: interpreter.identifier)

        case .unrecognized(let hint):
            let base = language.pick("I didn't understand that command.", "No entendí ese comando.")
            return response(.unrecognized, hint.map { base + " " + $0 } ?? base, interpreter: interpreter.identifier)
        }
    }

    /// Observe/replan rather than guessing outputs of dependent tools in advance.
    private func runWorkflow(
        _ initial: Workflow, next initialPlan: ToolPlan?, commandID: UUID, settings: JarvisSettings,
        onEvent: EngineEventHandler?
    ) async -> EngineResponse {
        var state = initial
        var next = initialPlan
        let language = state.interpretation.language
        let maximum = settings.model.maxRounds
        while state.round < maximum {
            guard sessionRevisions[state.request.session] == state.revision else {
                var response = workflowStopped(
                    state, commandID: commandID,
                    message: language.pick(
                        "Stopped because the conversation changed; earlier completed actions are preserved.",
                        "Se detuvo porque cambió la conversación; se conservan las acciones completadas."))
                response.status = .cancelled
                return response
            }
            if Task.isCancelled { break }
            let plan: ToolPlan
            if let ready = next {
                plan = ready
                next = nil
            } else {
                state.interpretation.observations = state.results
                state.interpretation.round = state.round
                do {
                    state.interpretation.onText = { text in onEvent?(.responseText(commandID: commandID, text: text)) }
                    let decision = try await interpreter.interpret(state.interpretation)
                    switch decision {
                    case .plan(let proposed): plan = proposed
                    case .reply(let text):
                        var response = Self.makeResponse(
                            id: commandID, input: state.request.text, language: language, results: state.results,
                            interpreter: "agent")
                        // The result cards are the source of truth; model prose is a summary of those observations.
                        response.message = text
                        if state.results.isEmpty { response.status = .reply }
                        return response
                    case .clarification(let question):
                        var response = Self.makeResponse(
                            id: commandID, input: state.request.text, language: language, results: state.results,
                            interpreter: "agent")
                        response.status = .needsClarification
                        response.message += "\n" + question.question
                        return response
                    case .unrecognized(let hint):
                        return workflowStopped(
                            state, commandID: commandID,
                            message: hint ?? language.pick("The workflow stopped.", "El flujo se ha detenido."))
                    }
                } catch {
                    return workflowStopped(
                        state, commandID: commandID,
                        message: language.pick(
                            "Planning was interrupted. Completed steps are shown below.",
                            "Se interrumpió la planificación. Los pasos completados aparecen debajo."))
                }
            }
            guard sessionRevisions[state.request.session] == state.revision else { continue }
            // Validate the whole batch before any write. AI batches cannot race writes with prerequisite reads.
            let valid =
                !plan.steps.isEmpty && plan.steps.count <= 10
                && plan.steps.allSatisfy { (try? registry.validate($0)) != nil }
            let mutating = plan.steps.filter { registry.descriptor(for: $0.tool)?.isMutating == true }
            guard valid, mutating.isEmpty || plan.steps.count == 1 else {
                return workflowStopped(
                    state, commandID: commandID,
                    message: language.pick(
                        "The model proposed an invalid batch. Nothing in that batch ran.",
                        "El modelo propuso un grupo de acciones inválido. No se ejecutó ese grupo."))
            }
            // A repeated successful mutation in this workflow is never executed, even outside the short duplicate window.
            if let write = mutating.first,
                state.completedWrites.contains(
                    write.tool.rawValue + "|" + JSONValue.object(write.arguments).canonicalString())
            {
                return workflowStopped(
                    state, commandID: commandID,
                    message: language.pick(
                        "Stopped a repeated action to avoid a duplicate.",
                        "Se detuvo una acción repetida para evitar un duplicado."))
            }
            let response = await run(
                plan: plan, input: state.request.text, request: state.request, commandID: commandID, settings: settings,
                onEvent: onEvent, revision: state.revision)
            state.round += 1
            state.results += response.results
            state.interpretation.executedCalls += plan.steps.filter { call in
                response.results.contains { $0.callID == call.id && $0.success }
            }
            if let write = mutating.first,
                response.results.first.map({
                    $0.success || $0.status == .needsConfirmation || $0.status == .needsClarification
                }) == true
            {
                state.completedWrites.insert(
                    write.tool.rawValue + "|" + JSONValue.object(write.arguments).canonicalString())
            }
            if response.results.contains(where: { $0.status == .needsConfirmation || $0.status == .needsClarification })
            {
                suspended[commandID] = state
                return Self.makeResponse(
                    id: commandID, input: state.request.text, language: language, results: state.results,
                    interpreter: "agent")
            }
            // Writes are never automatically retried after unknown outcomes; surface partial completion immediately.
            if response.results.contains(where: { !$0.success }) {
                return Self.makeResponse(
                    id: commandID, input: state.request.text, language: language, results: state.results,
                    interpreter: "agent")
            }
        }
        return workflowStopped(
            state, commandID: commandID,
            message: language.pick(
                "Stopped at the workflow limit or cancellation; completed steps are shown below.",
                "Se alcanzó el límite del flujo o se canceló; los pasos completados aparecen debajo."))
    }

    private func workflowStopped(_ state: Workflow, commandID: UUID, message: String) -> EngineResponse {
        var response = Self.makeResponse(
            id: commandID, input: state.request.text, language: state.interpretation.language, results: state.results,
            interpreter: "agent")
        response.status =
            Task.isCancelled ? .cancelled : (state.results.contains(where: \.success) ? .partial : .failed)
        response.message += (response.message.isEmpty ? "" : "\n") + message
        return response
    }

    // MARK: - Plan execution

    private func run(
        plan: ToolPlan, input: String, request: CommandRequest, commandID: UUID, settings: JarvisSettings,
        onEvent: EngineEventHandler?, revision: Int? = nil
    ) async -> EngineResponse {
        let language = plan.language
        let steps = plan.steps
        guard !steps.isEmpty else {
            return EngineResponse(
                id: commandID, input: input, language: language, status: .unrecognized,
                message: language.pick("There was nothing to do.", "No había nada que hacer."),
                interpreter: plan.interpreter)
        }

        onEvent?(
            .planned(
                commandID: commandID,
                steps: steps.map {
                    PlannedStep(id: $0.id, tool: $0.tool, integration: registry.descriptor(for: $0.tool)?.integration)
                }))

        let calendar = dateProvider.calendar()
        let now = dateProvider.now()
        let base = StepContext(
            language: language, now: now, calendar: calendar, settings: settings, source: request.source,
            session: request.session, commandID: commandID, allowDuplicate: request.allowDuplicate, revision: revision)

        // Steps of the same integration run in order; different integrations run concurrently.
        var groups: [(key: String, indexes: [Int])] = []
        for (index, call) in steps.enumerated() {
            let key = registry.descriptor(for: call.tool)?.integration.rawValue ?? "unknown.\(index)"
            if let position = groups.firstIndex(where: { $0.key == key }) {
                groups[position].indexes.append(index)
            } else {
                groups.append((key, [index]))
            }
        }

        var results = [ToolResult?](repeating: nil, count: steps.count)
        await withTaskGroup(of: [(Int, ToolResult)].self) { taskGroup in
            for group in groups {
                taskGroup.addTask { [self] in
                    var produced: [(Int, ToolResult)] = []
                    var blocker: ToolResult?
                    for index in group.indexes {
                        let call = steps[index]
                        if let blocker {
                            let skipped = Self.skippedResult(for: call, because: blocker, language: language)
                            onEvent?(.stepFinished(commandID: commandID, result: skipped))
                            produced.append((index, skipped))
                            continue
                        }
                        onEvent?(.stepStarted(commandID: commandID, callID: call.id))
                        let result = await self.executeStep(call, context: base, confirmed: false)
                        onEvent?(.stepFinished(commandID: commandID, result: result))
                        produced.append((index, result))
                        if Self.blocksFollowingSteps(result.status) { blocker = result }
                    }
                    return produced
                }
            }
            for await produced in taskGroup {
                for (index, result) in produced { results[index] = result }
            }
        }

        let finished = results.enumerated().map { index, result in
            result ?? Self.skippedResult(for: steps[index], because: nil, language: language)
        }
        var response = Self.makeResponse(
            id: commandID, input: input, language: language, results: finished, interpreter: plan.interpreter)
        if !plan.notes.isEmpty {
            response.message += "\n" + plan.notes.joined(separator: "\n")
            if response.status == .completed { response.status = .partial }
        }
        return response
    }

    private func resolveInternal(
        token: String, decision: PendingDecision, language: Language, source: CommandSource, settings: JarvisSettings,
        onEvent: EngineEventHandler?
    ) async -> EngineResponse {
        guard let item = pending.peek(token: token) else {
            return EngineResponse(
                input: "", language: language, status: .failed,
                message: language.pick(
                    "That request has expired or was already handled.", "Esa solicitud expiró o ya se atendió.")
            )
        }
        let calendar = dateProvider.calendar()
        let context = StepContext(
            language: language, now: dateProvider.now(), calendar: calendar, settings: settings, source: source,
            session: item.session, commandID: item.commandID, allowDuplicate: false)

        switch (item.kind, decision) {
        case (_, .cancel):
            _ = pending.take(token: token)
            let prior = suspended.removeValue(forKey: item.commandID)?.results.filter { $0.success } ?? []
            let message =
                prior.isEmpty
                ? language.pick("Okay, I cancelled that. Nothing was changed.", "Listo, lo cancelé. No se cambió nada.")
                : language.pick(
                    "Cancelled the remaining workflow. Earlier completed steps are preserved.",
                    "Cancelé el resto del flujo. Se conservan los pasos ya completados.")
            await history?.update(id: item.commandID, status: .cancelled, summary: message)
            return EngineResponse(
                id: item.commandID, input: "", language: language, status: .cancelled, message: message, results: prior)

        case (.confirmation(let request), .confirm):
            _ = pending.take(token: token)
            let result = await executeStep(request.call, context: context, confirmed: true)
            onEvent?(.stepFinished(commandID: item.commandID, result: result))
            let response = await resumeWorkflow(
                commandID: item.commandID, result: result, language: language, settings: settings, onEvent: onEvent)
            await history?.update(id: item.commandID, status: response.status, summary: response.message)
            return response

        case (.clarification(let clarification), .choose(let index)) where clarification.options.indices.contains(index):
            _ = pending.take(token: token)
            let option = clarification.options[index]
            let result = await executeStep(option.call, context: context, confirmed: false)
            onEvent?(.stepFinished(commandID: item.commandID, result: result))
            let response = await resumeWorkflow(
                commandID: item.commandID, result: result, language: language, settings: settings, onEvent: onEvent)
            await history?.update(id: item.commandID, status: response.status, summary: response.message)
            return response

        default:
            // The reply does not fit what was asked; the question stays open under the same token.
            return EngineResponse(
                input: "", language: language, status: .failed,
                message: language.pick(
                    "Please answer the question above, or say “cancel”.",
                    "Responde a la pregunta anterior o di «cancelar».")
            )
        }
    }

    private func resumeWorkflow(
        commandID: UUID, result: ToolResult, language: Language, settings: JarvisSettings, onEvent: EngineEventHandler?
    ) async -> EngineResponse {
        guard var state = suspended.removeValue(forKey: commandID) else {
            return Self.makeResponse(
                id: commandID, input: "", language: language, results: [result], interpreter: "confirmation")
        }
        state.results.removeAll { $0.status == .needsConfirmation || $0.status == .needsClarification }
        state.results.append(result)
        guard result.success else {
            if result.status == .needsConfirmation || result.status == .needsClarification {
                suspended[commandID] = state
            }
            return Self.makeResponse(
                id: commandID, input: state.request.text, language: language, results: state.results,
                interpreter: "agent")
        }
        let response = await runWorkflow(state, next: nil, commandID: commandID, settings: settings, onEvent: onEvent)
        remember(response, request: state.request, settings: settings)
        return response
    }

    // MARK: - Single step

    private struct StepContext: Sendable {
        var language: Language
        var now: Date
        var calendar: Calendar
        var settings: JarvisSettings
        var source: CommandSource
        var session: String
        var commandID: UUID
        var allowDuplicate: Bool
        var revision: Int? = nil
    }

    private func executeStep(_ call: ToolCall, context base: StepContext, confirmed: Bool) async -> ToolResult {
        let clock = ContinuousClock()
        let began = clock.now
        let language = base.language

        func finish(_ result: ToolResult) -> ToolResult {
            var copy = result
            copy.durationMs = Self.milliseconds(since: began, clock: clock)
            if copy.assumptions.isEmpty { copy.assumptions = call.assumptions }
            JarvisLog.engine.info(
                "tool=\(call.tool.rawValue, privacy: .public) status=\(copy.status.rawValue, privacy: .public) ms=\(copy.durationMs, privacy: .public)"
            )
            return copy
        }

        // 1. Validation
        let validated: ValidatedToolCall
        do {
            validated = try registry.validate(call)
        } catch {
            return finish(Self.failureResult(for: call, error: error, language: language))
        }
        let descriptor = validated.descriptor

        // 2. Capability exists on this Mac?
        if case .unsupported(let reason, let alternative) = descriptor.availability {
            let text = reason.resolved(language) + (alternative.map { " " + $0.resolved(language) } ?? "")
            return finish(
                ToolResult(
                    callID: call.id, tool: call.tool, status: .unsupported, message: text, errorCode: "unsupported"))
        }
        guard let integration = registry.integration(for: descriptor.name) else {
            return finish(
                ToolResult(
                    callID: call.id, tool: call.tool, status: .failed,
                    message: language.pick(
                        "No integration handles \(call.tool.rawValue).",
                        "Ninguna integración maneja \(call.tool.rawValue)."), errorCode: "no_integration"))
        }

        // 3. Permission check (may show the system prompt the first time)
        var authorization = await integration.authorization(for: descriptor)
        if case .notDetermined = authorization {
            authorization = await integration.requestAuthorization(for: descriptor)
        }
        switch authorization {
        case .authorized:
            break
        case .notDetermined(let requirement), .denied(let requirement), .restricted(let requirement):
            let error = JarvisError.permissionRequired(requirement)
            return finish(
                ToolResult(
                    callID: call.id, tool: call.tool, status: .permissionRequired, message: error.message(in: language),
                    errorCode: "permission_required", permission: requirement))
        case .unavailable(let reason):
            return finish(
                ToolResult(
                    callID: call.id, tool: call.tool, status: .unavailable, message: reason.resolved(language),
                    errorCode: "unavailable"))
        }
        if Task.isCancelled || (base.revision != nil && sessionRevisions[base.session] != base.revision) {
            return finish(
                ToolResult(
                    callID: call.id, tool: call.tool, status: .cancelled,
                    message: JarvisError.cancelled.message(in: language), errorCode: "cancelled"))
        }

        // Unknown write outcomes must be re-read by the user before an explicit retry.
        uncertainWrites = uncertainWrites.filter { dateProvider.now().timeIntervalSince($0.value) < 600 }
        let actionKey = descriptor.name.rawValue + "|" + JSONValue.object(validated.arguments).canonicalString()
        if descriptor.deduplicate, !base.allowDuplicate, uncertainWrites[actionKey] != nil {
            return finish(
                ToolResult(
                    callID: call.id, tool: call.tool, status: .failed,
                    message: language.pick(
                        "The previous attempt may have saved this action. Check the app before explicitly retrying.",
                        "El intento anterior puede haber guardado esta acción. Revisa la app antes de reintentarlo expresamente."
                    ), errorCode: "uncertain_write"))
        }
        // 4. Duplicate protection for creation-style tools
        var duplicateKey: String?
        if descriptor.deduplicate, !base.allowDuplicate {
            let key = descriptor.name.rawValue + "|" + JSONValue.object(validated.arguments).canonicalString()
            let window = base.settings.duplicateWindowSeconds
            if window > 0 {
                guard duplicates.begin(key: key, now: dateProvider.now(), window: window) else {
                    let message = language.pick(
                        "That exact action just ran, so I skipped it to avoid a duplicate. Repeat it in a few seconds if you really meant to.",
                        "Esa misma acción se acaba de ejecutar, así que la omití para evitar un duplicado. Repítela en unos segundos si de verdad lo querías."
                    )
                    return finish(
                        ToolResult(
                            callID: call.id, tool: call.tool, status: .duplicate, message: message,
                            errorCode: "duplicate"))
                }
                duplicateKey = key
            }
        }

        // 5. Execution with a hard deadline
        let execution = ExecutionContext(
            language: language, now: base.now, calendar: base.calendar, settings: base.settings,
            source: base.source, isConfirmed: confirmed, callID: call.id
        )
        let outcome: ToolOutcome
        do {
            outcome = try await Self.runWithDeadline(descriptor.timeout) {
                try await integration.execute(validated, context: execution)
            }
        } catch {
            if let key = duplicateKey { duplicates.end(key: key, now: dateProvider.now(), succeeded: false) }
            let failure = Self.failureResult(for: call, error: error, language: language)
            if descriptor.deduplicate,
                ["timeout", "cancelled", "verification_failed"].contains(failure.errorCode ?? "")
            {
                uncertainWrites[actionKey] = dateProvider.now()
            }
            return finish(failure)
        }

        // 6. Turn the outcome into a verified result
        switch outcome {
        case .done(let output):
            uncertainWrites[actionKey] = nil
            if let key = duplicateKey { duplicates.end(key: key, now: dateProvider.now(), succeeded: true) }
            return finish(
                ToolResult(
                    callID: call.id, tool: call.tool, status: .completed, message: output.message,
                    data: output.data, verification: output.verification, warnings: output.warnings
                ))

        case .confirm(var request):
            if let key = duplicateKey { duplicates.end(key: key, now: dateProvider.now(), succeeded: false) }
            request.token = pending.add(
                session: base.session, commandID: base.commandID, kind: .confirmation(request),
                now: dateProvider.now(), capacity: limits.maxPending
            )
            return finish(
                ToolResult(
                    callID: call.id, tool: call.tool, status: .needsConfirmation, message: request.prompt,
                    confirmation: request
                ))

        case .clarify(var clarification):
            if let key = duplicateKey { duplicates.end(key: key, now: dateProvider.now(), succeeded: false) }
            clarification.token = pending.add(
                session: base.session, commandID: base.commandID, kind: .clarification(clarification),
                now: dateProvider.now(), capacity: limits.maxPending
            )
            return finish(
                ToolResult(
                    callID: call.id, tool: call.tool, status: .needsClarification, message: clarification.question,
                    clarification: clarification
                ))
        }
    }

    // MARK: - Helpers

    private static func runWithDeadline(
        _ seconds: TimeInterval, operation: @escaping @Sendable () async throws -> ToolOutcome
    ) async throws -> ToolOutcome {
        try await withThrowingTaskGroup(of: ToolOutcome.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw JarvisError.timedOut(seconds: seconds)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw JarvisError.cancelled }
            return first
        }
    }

    private static func failureResult(for call: ToolCall, error: any Error, language: Language) -> ToolResult {
        if let jarvis = error as? JarvisError {
            var result = ToolResult(
                callID: call.id, tool: call.tool, status: jarvis.resultStatus,
                message: jarvis.message(in: language), errorCode: jarvis.code
            )
            switch jarvis {
            case .permissionRequired(let requirement): result.permission = requirement
            case .setupRequired(let instructions, _): result.setup = instructions
            default: break
            }
            return result
        }
        if error is CancellationError {
            return ToolResult(
                callID: call.id, tool: call.tool, status: .cancelled,
                message: JarvisError.cancelled.message(in: language), errorCode: "cancelled")
        }
        JarvisLog.engine.error(
            "Unexpected error in \(call.tool.rawValue, privacy: .public): \(String(describing: type(of: error)), privacy: .public)"
        )
        let detail = String(error.localizedDescription.prefix(300))
        return ToolResult(
            callID: call.id, tool: call.tool, status: .failed,
            message: language.pick("Something went wrong: \(detail)", "Algo salió mal: \(detail)"),
            errorCode: "internal_error"
        )
    }

    private static func skippedResult(for call: ToolCall, because blocker: ToolResult?, language: Language)
        -> ToolResult
    {
        let message: String
        if let blocker {
            message = language.pick(
                "Skipped because an earlier step did not complete (\(blocker.tool.rawValue)).",
                "Omitido porque un paso anterior no se completó (\(blocker.tool.rawValue))."
            )
        } else {
            message = language.pick("Skipped.", "Omitido.")
        }
        return ToolResult(callID: call.id, tool: call.tool, status: .skipped, message: message, errorCode: "skipped")
    }

    private static func blocksFollowingSteps(_ status: ToolResult.Status) -> Bool {
        switch status {
        case .failed, .permissionRequired, .setupRequired, .unavailable, .needsConfirmation, .needsClarification,
            .cancelled:
            return true
        case .completed, .unsupported, .skipped, .duplicate: return false
        }
    }

    static func makeResponse(id: UUID, input: String, language: Language, results: [ToolResult], interpreter: String)
        -> EngineResponse
    {
        let status = aggregateStatus(results)
        let lines = results.map { result -> String in
            guard !result.assumptions.isEmpty, result.status == .completed else { return result.message }
            return result.message + " (" + result.assumptions.joined(separator: "; ") + ")"
        }
        return EngineResponse(
            id: id, input: input, language: language, status: status,
            message: lines.joined(separator: "\n"), results: results, interpreter: interpreter
        )
    }

    static func aggregateStatus(_ results: [ToolResult]) -> EngineResponse.Status {
        func map(_ status: ToolResult.Status) -> EngineResponse.Status {
            switch status {
            case .completed: return .completed
            case .failed, .skipped: return .failed
            case .permissionRequired: return .permissionRequired
            case .needsConfirmation: return .needsConfirmation
            case .needsClarification: return .needsClarification
            case .setupRequired: return .setupRequired
            case .unavailable: return .unavailable
            case .unsupported: return .unsupported
            case .cancelled: return .cancelled
            case .duplicate: return .duplicate
            }
        }
        guard !results.isEmpty else { return .unrecognized }
        if results.count == 1 { return map(results[0].status) }
        let statuses = Set(results.map(\.status))
        if statuses == [.completed] { return .completed }
        if statuses.contains(.completed) { return .partial }
        if statuses.count == 1, let only = statuses.first { return map(only) }
        for candidate in [
            ToolResult.Status.permissionRequired, .setupRequired, .needsConfirmation, .needsClarification, .failed,
            .unavailable, .unsupported,
        ] where statuses.contains(candidate) {
            return map(candidate)
        }
        return .failed
    }

    private func resolveLanguage(_ requested: Language?, text: String, settings: JarvisSettings) -> Language {
        if let requested { return requested }
        if let fixed = settings.languagePreference.fixedLanguage { return fixed }
        return LanguageDetector.detect(text, fallback: fallbackLanguage)
    }

    private static func milliseconds(since start: ContinuousClock.Instant, clock: ContinuousClock) -> Int {
        let duration = start.duration(to: clock.now)
        let (seconds, attoseconds) = duration.components
        return Int(seconds * 1_000 + attoseconds / 1_000_000_000_000_000)
    }

    private func record(_ response: EngineResponse, request: CommandRequest, settings: JarvisSettings, isReply: Bool)
        async
    {
        guard settings.saveHistory, let history, !response.input.isEmpty, !isReply else { return }
        var entry = HistoryEntry(
            id: response.id, date: response.startedAt, text: response.input, language: response.language,
            status: response.status, summary: response.message,
            tools: response.results.map(\.tool.rawValue), source: request.source.rawValue
        )
        if settings.saveConversations { entry.conversation = SavedConversation(response) }
        await history.record(entry)
    }
}
