import Foundation
import JarvisCore

/// Apple Reminders through EventKit (no AppleScript, no private database).
public struct RemindersIntegration: AppIntegration {
    public let id = IntegrationID.reminders
    public let displayName = LocalizedText(en: "Reminders", es: "Recordatorios")
    public let summary = LocalizedText(
        en: "Create, list, complete, edit and delete reminders and reminder lists.",
        es: "Crea, lista, completa, edita y elimina recordatorios y listas de recordatorios."
    )
    public let symbolName = "checklist"

    private let store: any ReminderStoring

    public init(backend: EventKitBackend) {
        self.store = backend
    }

    init(store: any ReminderStoring) {
        self.store = store
    }

    public var permissionRequirements: [PermissionRequirement] { [EventKitRequirements.reminders] }

    // MARK: Discovery

    public var tools: [ToolDescriptor] {
        let id = self.id
        func tool(_ name: ToolName, _ title: String, _ summary: String, _ parameters: [ToolParameter] = [], _ constraints: [ToolConstraint] = [], safety: ToolSafety = .modifying, deduplicate: Bool = false, examples: [ToolExample] = []) -> ToolDescriptor {
            ToolDescriptor(name: name, integration: id, title: title, summary: summary, parameters: parameters, constraints: constraints, safety: safety, timeout: 30, deduplicate: deduplicate, examples: examples)
        }
        let selector: [ToolParameter] = [
            .string("id", "Exact reminder id (from reminders.list).", maxLength: 200),
            .string("title", "Title (or part of it) of the reminder.", maxLength: 500),
            .string("list", "Restrict to this reminders list.", maxLength: 200),
        ]
        return [
            tool(.remindersCreate, "Create a reminder", "Creates a reminder, optionally in a named list and with a due date/time.", [
                .string("title", "What to be reminded of.", required: true, maxLength: 500),
                .string("list", "Reminders list name; default list when omitted.", maxLength: 200),
                .string("list_id", "Exact list id (skips name matching).", maxLength: 200),
                .dateOrDateTime("due", "Due date (yyyy-MM-dd) or date-time with offset."),
                .string("notes", "Notes for the reminder.", maxLength: 5_000),
                .choice("priority", ["none", "low", "medium", "high"], "Priority.", default: "none"),
                .boolean("create_list_if_missing", "Create the list when it does not exist."),
            ], deduplicate: true, examples: [
                ToolExample("Add buy milk to my Shopping reminders list", arguments: ["title": "Buy milk", "list": "Shopping"]),
                ToolExample("Remind me tomorrow at 6 PM to submit my assignment", arguments: ["title": "Submit my assignment", "due": "2026-10-18T18:00:00-04:00"]),
            ]),
            tool(.remindersList, "List reminders", "Lists reminders filtered by list, status and due date.", [
                .string("list", "Only this list.", maxLength: 200),
                .choice("status", ["pending", "completed", "all"], "Which reminders.", default: "pending"),
                .dateOrDateTime("due_from", "Only reminders due on/after this moment."),
                .dateOrDateTime("due_to", "Only reminders due before this moment."),
                .string("query", "Only reminders whose title contains this text.", maxLength: 200),
                .integer("limit", "Maximum reminders.", min: 1, max: 200, default: 50),
            ], safety: .readOnly, examples: [ToolExample("Show my pending reminders", arguments: ["status": "pending"])]),
            tool(.remindersComplete, "Complete or reopen a reminder", "Marks a reminder completed (or not completed).", selector + [
                .boolean("completed", "false reopens the reminder.", default: true),
            ], [.atLeastOne(["id", "title"])], examples: [ToolExample("Mark buy milk as done", arguments: ["title": "Buy milk"])]),
            tool(.remindersUpdate, "Edit a reminder", "Changes a reminder's title, due date, notes, list or priority.", selector + [
                .string("new_title", "New title.", maxLength: 500),
                .dateOrDateTime("new_due", "New due date or date-time."),
                .boolean("clear_due", "Remove the due date."),
                .string("new_notes", "New notes.", maxLength: 5_000),
                .string("new_list", "Move to this list.", maxLength: 200),
                .choice("new_priority", ["none", "low", "medium", "high"], "New priority."),
            ], [.atLeastOne(["id", "title"]), .atLeastOne(["new_title", "new_due", "clear_due", "new_notes", "new_list", "new_priority"])]),
            tool(.remindersDelete, "Delete a reminder", "Deletes a reminder after confirmation.", selector, [.atLeastOne(["id", "title"])], safety: .destructive),
            tool(.remindersListLists, "List reminder lists", "Lists the user's reminder lists.", safety: .readOnly),
            tool(.remindersCreateList, "Create a reminders list", "Creates a new reminders list.", [
                .string("name", "Name of the new list.", required: true, maxLength: 200),
            ], deduplicate: true, examples: [ToolExample("Create a reminders list called Groceries", arguments: ["name": "Groceries"])]),
        ]
    }

    // MARK: Authorization

    public func status() async -> IntegrationStatus {
        let access = await store.access()
        let requirement = EventKitRequirements.reminders
        let state = EventKitRequirements.state(for: access, requirement: requirement)
        let entry = IntegrationStatus.PermissionEntry(requirement: requirement, state: state)
        switch access {
        case .authorized: return IntegrationStatus(state: .ready, permissions: [entry])
        case .notDetermined: return IntegrationStatus(state: .needsPermission, detail: requirement.rationale, permissions: [entry])
        case .restricted: return IntegrationStatus(state: .restricted, detail: requirement.rationale, permissions: [entry])
        case .denied, .writeOnly: return IntegrationStatus(state: .denied, detail: requirement.rationale, permissions: [entry])
        }
    }

    public func authorization(for tool: ToolDescriptor) async -> AuthorizationState {
        EventKitRequirements.state(for: await store.access(), requirement: EventKitRequirements.reminders)
    }

    public func requestAuthorization(for tool: ToolDescriptor) async -> AuthorizationState {
        var access = try? await store.requestAccess()
        if access == nil { access = await store.access() }
        return EventKitRequirements.state(for: access ?? .denied, requirement: EventKitRequirements.reminders)
    }

    // MARK: Execution

    public func execute(_ call: ValidatedToolCall, context: ExecutionContext) async throws -> ToolOutcome {
        do {
            switch call.descriptor.name {
            case .remindersCreate: return try await create(call, context)
            case .remindersList: return try await list(call, context)
            case .remindersComplete: return try await complete(call, context)
            case .remindersUpdate: return try await update(call, context)
            case .remindersDelete: return try await delete(call, context)
            case .remindersListLists: return try await listLists(context)
            case .remindersCreateList: return try await createList(call, context)
            default:
                throw JarvisError.failed("unknown_tool", en: "Reminders does not provide \(call.descriptor.name).", es: "Recordatorios no ofrece \(call.descriptor.name).")
            }
        } catch let failure as EventKitFailure {
            throw Self.map(failure)
        }
    }

    static func map(_ failure: EventKitFailure) -> JarvisError {
        switch failure {
        case .notAuthorized:
            return .permissionRequired(EventKitRequirements.reminders)
        case .notFound:
            return .notFound("reminder_not_found", en: "That reminder or list no longer exists.", es: "Ese recordatorio o lista ya no existe.")
        case .readOnly(let name):
            return .failed("list_read_only", en: "The list “\(name)” is read-only (shared as view-only or subscribed), so nothing can be added to it.", es: "La lista «\(name)» es de solo lectura (compartida solo para ver o suscrita), así que no se puede añadir nada.")
        case .saveFailed(let message):
            return .failed("save_failed", en: "Reminders could not save the change: \(message)", es: "Recordatorios no pudo guardar el cambio: \(message)")
        case .noWritableSource:
            return .failed("no_source", en: "No account that supports reminder lists is available.", es: "No hay ninguna cuenta que admita listas de recordatorios.")
        }
    }

    // MARK: Helpers

    private enum ListChoice {
        case use(ReminderListInfo)
        case missing(String)
        case ambiguous([ReminderListInfo])
        case readOnly(String)
    }

    private func resolveList(name: String?, id: String?, lists: [ReminderListInfo], settings: JarvisSettings, requireWritable: Bool) -> ListChoice {
        let usable: [ReminderListInfo] = requireWritable ? lists.filter(\.allowsModifications) : lists
        if let id {
            if let found = lists.first(where: { $0.id == id }) { return .use(found) }
            return .missing(id)
        }
        let wanted: String? = name ?? settings.defaultReminderList
        if let wanted {
            let matches = NameMatcher.bestMatches(usable, query: wanted, minimumScore: 80) { $0.title }
            if matches.count == 1 { return .use(matches[0]) }
            if matches.count > 1 { return .ambiguous(matches) }
            // A list that exists but cannot be written to is a different problem from a list that does not exist.
            if requireWritable, let locked = NameMatcher.bestMatches(lists, query: wanted, minimumScore: 80, name: { $0.title }).first {
                return .readOnly(locked.title)
            }
            // An unknown *name* is an error; an unknown *default* falls back to the system default list.
            if name != nil { return .missing(wanted) }
        }
        if let fallback = usable.first(where: \.isDefault) ?? usable.first { return .use(fallback) }
        return .missing(wanted ?? "")
    }

    private func dueSpec(_ text: String?, timeZone: TimeZone) -> DueSpec? {
        guard let text, let parsed = ISODates.parse(text, timeZone: timeZone) else { return nil }
        switch parsed {
        case .date(let parts): return .date(year: parts.year, month: parts.month, day: parts.day)
        case .dateTime(let date): return .dateTime(date)
        }
    }

    private func describeDue(_ reminder: ReminderInfo, _ context: ExecutionContext) -> String {
        guard let due = reminder.due else { return "" }
        return Formatting.dateTime(due, calendar: context.calendar, language: context.language, includeTime: reminder.dueHasTime)
    }

    private static func priorityValue(_ name: String?) -> Int {
        switch name {
        case "high": return 1
        case "medium": return 5
        case "low": return 9
        default: return 0
        }
    }

    private func sameDue(_ reminder: ReminderInfo, _ spec: DueSpec?, calendar: Calendar) -> Bool {
        switch (reminder.due, spec) {
        case (nil, nil):
            return true
        case (let due?, .dateTime(let date)?):
            return reminder.dueHasTime && abs(due.timeIntervalSince(date)) < 60
        case (let due?, .date(let year, let month, let day)?):
            let parts = calendar.dateComponents([.year, .month, .day], from: due)
            return !reminder.dueHasTime && parts.year == year && parts.month == month && parts.day == day
        default:
            return false
        }
    }

    private func appended(_ base: String, dueText: String, _ language: Language) -> String {
        if dueText.isEmpty { return base + "." }
        return base + language.pick(" — due \(dueText).", " — vence \(dueText).")
    }

    // MARK: reminders.create

    private func create(_ call: ValidatedToolCall, _ context: ExecutionContext) async throws -> ToolOutcome {
        let language = context.language
        let title = call.string("title") ?? ""
        let lists = try await store.lists()

        var target: ReminderListInfo
        switch resolveList(name: call.string("list"), id: call.string("list_id"), lists: lists, settings: context.settings, requireWritable: true) {
        case .use(let list):
            target = list
        case .ambiguous(let matches):
            let requested = call.string("list") ?? ""
            var options: [ClarificationOption] = []
            for list in matches {
                options.append(ClarificationOption(label: list.title, detail: list.sourceName, call: call.call.adding(["list_id": .string(list.id)])))
            }
            return .clarify(Clarification(
                question: language.pick("You have several lists called “\(requested)”. Which one?", "Tienes varias listas llamadas «\(requested)». ¿Cuál?"),
                options: options
            ))
        case .readOnly(let name):
            throw EventKitFailure.readOnly(name)
        case .missing(let name):
            if call.bool("create_list_if_missing") == true {
                target = try await store.createList(title: name, preferredSourceID: lists.first(where: \.isDefault)?.sourceID)
            } else {
                var withoutList = call.call
                withoutList.arguments["list"] = nil
                withoutList.arguments["list_id"] = nil
                var options = [ClarificationOption(
                    label: language.pick("Create the list “\(name)” and add it there", "Crear la lista «\(name)» y añadirlo ahí"),
                    call: call.call.adding(["create_list_if_missing": true])
                )]
                if let fallback = lists.first(where: { $0.isDefault && $0.allowsModifications }) {
                    options.append(ClarificationOption(
                        label: language.pick("Add it to “\(fallback.title)” instead", "Añadirlo a «\(fallback.title)» en su lugar"),
                        call: withoutList.adding(["list_id": .string(fallback.id)])
                    ))
                }
                let existing = lists.prefix(8).map(\.title).joined(separator: ", ")
                return .clarify(Clarification(
                    question: language.pick("There is no Reminders list called “\(name)”. Your lists: \(existing).", "No existe una lista de Recordatorios llamada «\(name)». Tus listas: \(existing)."),
                    options: options
                ))
            }
        }

        let due = dueSpec(call.string("due"), timeZone: context.timeZone)
        let notes = call.string("notes")

        // Not a second copy of something already pending in the same list.
        let existing = try await store.reminders(in: [target.id], calendar: context.calendar)
        let foldedTitle = TextFolding.fold(title)
        if let duplicate = existing.first(where: { !$0.isCompleted && TextFolding.fold($0.title) == foldedTitle && sameDue($0, due, calendar: context.calendar) }) {
            var data = duplicate.json(calendar: context.calendar).objectValue ?? [:]
            data["created"] = false
            return .done(ToolOutput(
                message: language.pick("That reminder already exists in “\(target.title)”, so I didn't add a second copy.", "Ese recordatorio ya existe en «\(target.title)», así que no añadí una segunda copia."),
                data: .object(data),
                verification: .verified(language.pick("The existing reminder was found in Reminders.", "Se encontró el recordatorio existente en Recordatorios."))
            ))
        }

        let draft = ReminderDraft(title: title, notes: notes, listID: target.id, due: due, priority: Self.priorityValue(call.string("priority")))
        let created = try await store.create(draft, calendar: context.calendar)

        // Verify by reading the reminder back from the store.
        guard let stored = try await store.reminder(id: created.id, calendar: context.calendar),
              stored.title == title, stored.listID == target.id, !stored.isCompleted, sameDue(stored, due, calendar: context.calendar) else {
            throw JarvisError.verificationFailed(LocalizedText(
                en: "Reminders did not return the reminder as saved; please check the app.",
                es: "Recordatorios no devolvió el recordatorio tal como se guardó; revisa la app."
            ))
        }

        var warnings: [String] = []
        if case .dateTime(let date)? = due, date < context.now.addingTimeInterval(-60) {
            warnings.append(language.pick("That time is already in the past, so it won't notify.", "Esa hora ya pasó, así que no habrá aviso."))
        }
        let base: String = language.pick("Reminder created: “\(stored.title)” in \(stored.listTitle)", "Recordatorio creado: «\(stored.title)» en \(stored.listTitle)")
        var data = stored.json(calendar: context.calendar).objectValue ?? [:]
        data["created"] = true
        return .done(ToolOutput(
            message: appended(base, dueText: describeDue(stored, context), language),
            data: .object(data),
            verification: .verified(language.pick("Re-read from Reminders: title, list and due date match.", "Releído desde Recordatorios: título, lista y fecha coinciden.")),
            warnings: warnings
        ))
    }

    // MARK: reminders.list

    private func list(_ call: ValidatedToolCall, _ context: ExecutionContext) async throws -> ToolOutcome {
        let language = context.language
        let lists = try await store.lists()
        var listIDs: [String]?
        if let name = call.string("list") {
            let matches = NameMatcher.bestMatches(lists, query: name, minimumScore: 80) { $0.title }
            guard !matches.isEmpty else {
                let known = lists.map(\.title).joined(separator: ", ")
                throw JarvisError.notFound("list_not_found", en: "There is no Reminders list called “\(name)”. Your lists: \(known).", es: "No existe una lista de Recordatorios llamada «\(name)». Tus listas: \(known).")
            }
            listIDs = matches.map(\.id)
        }
        let status = call.string("status") ?? "pending"
        let from = call.string("due_from").flatMap { ISODates.date(from: $0, timeZone: context.timeZone) }
        let to = call.string("due_to").flatMap { ISODates.date(from: $0, timeZone: context.timeZone) }
        let query = call.string("query")
        let limit = call.int("limit") ?? 50

        let all = try await store.reminders(in: listIDs, calendar: context.calendar)
        var reminders: [ReminderInfo] = []
        for reminder in all {
            if status == "pending", reminder.isCompleted { continue }
            if status == "completed", !reminder.isCompleted { continue }
            if from != nil || to != nil {
                guard let due = reminder.due else { continue }
                if let from, due < from { continue }
                if let to, due >= to { continue }
            }
            if let query, !TextFolding.fold(reminder.title).contains(TextFolding.fold(query)) { continue }
            reminders.append(reminder)
        }
        reminders.sort(by: Self.dueOrder)
        let shown = Array(reminders.prefix(limit))

        guard !shown.isEmpty else {
            let none: String
            if status == "completed" {
                none = language.pick("No completed reminders match.", "No hay recordatorios completados que coincidan.")
            } else if from != nil {
                none = language.pick("You have no pending reminders for that period.", "No tienes recordatorios pendientes para ese periodo.")
            } else {
                none = language.pick("You have no pending reminders.", "No tienes recordatorios pendientes.")
            }
            return .done(ToolOutput(message: none, data: ["reminders": [], "count": 0], verification: .notApplicable))
        }

        var lines: [String] = []
        let grouped = Dictionary(grouping: shown, by: \.listTitle)
        for listName in grouped.keys.sorted() {
            lines.append(listName + ":")
            for reminder in (grouped[listName] ?? []).prefix(30) {
                let due = describeDue(reminder, context)
                let mark: String = reminder.isCompleted ? "✓ " : ""
                var line: String = "• \(mark)\(reminder.title)"
                if !due.isEmpty { line += " — \(due)" }
                lines.append(line)
            }
        }
        let header = Self.listHeader(total: reminders.count, shown: shown.count, status: status, language: language)
        return .done(ToolOutput(
            message: header + "\n" + lines.joined(separator: "\n"),
            data: ["reminders": .array(shown.map { $0.json(calendar: context.calendar) }), "count": .int(reminders.count)],
            verification: .notApplicable
        ))
    }

    private static func dueOrder(_ left: ReminderInfo, _ right: ReminderInfo) -> Bool {
        switch (left.due, right.due) {
        case let (l?, r?): return l != r ? l < r : left.title < right.title
        case (_?, nil): return true
        case (nil, _?): return false
        default: return left.title.localizedCaseInsensitiveCompare(right.title) == .orderedAscending
        }
    }

    private static func listHeader(total: Int, shown: Int, status: String, language: Language) -> String {
        let plural: String = total == 1 ? "" : "s"
        let truncated: String = shown < total ? language.pick(" (showing \(shown))", " (mostrando \(shown))") : ""
        if language == .en {
            var qualifier = ""
            if status == "pending" { qualifier = "pending " }
            if status == "completed" { qualifier = "completed " }
            return "\(total) \(qualifier)reminder\(plural)\(truncated):"
        }
        var qualifier = ""
        if status == "pending" { qualifier = " pendiente\(plural)" }
        if status == "completed" { qualifier = " completado\(plural)" }
        return "\(total) recordatorio\(plural)\(qualifier)\(truncated):"
    }

    // MARK: Resolving one reminder

    private enum Resolution {
        case found(ReminderInfo)
        case outcome(ToolOutcome)
    }

    private func resolve(_ call: ValidatedToolCall, _ context: ExecutionContext, preferring status: ReminderStatusFilter) async throws -> Resolution {
        let language = context.language
        if let id = call.string("id") {
            guard let found = try await store.reminder(id: id, calendar: context.calendar) else {
                throw JarvisError.notFound("reminder_not_found", en: "That reminder no longer exists.", es: "Ese recordatorio ya no existe.")
            }
            return .found(found)
        }
        let title = call.string("title") ?? ""
        let lists = try await store.lists()
        var listIDs: [String]?
        if let name = call.string("list") {
            let matches = NameMatcher.bestMatches(lists, query: name, minimumScore: 80) { $0.title }
            guard !matches.isEmpty else {
                throw JarvisError.notFound("list_not_found", en: "There is no Reminders list called “\(name)”.", es: "No existe una lista de Recordatorios llamada «\(name)».")
            }
            listIDs = matches.map(\.id)
        }
        let all = try await store.reminders(in: listIDs, calendar: context.calendar)

        let preferred: [ReminderInfo]
        switch status {
        case .pending: preferred = all.filter { !$0.isCompleted }
        case .completed: preferred = all.filter(\.isCompleted)
        case .all: preferred = all
        }
        var matches = Self.bestTitleMatches(preferred, title)
        if matches.isEmpty { matches = Self.bestTitleMatches(all, title) }   // e.g. completing something already completed
        guard !matches.isEmpty else {
            let words = Set(TextFolding.tokens(title).filter { $0.count >= 3 })
            let similar = all.filter { !words.isDisjoint(with: TextFolding.tokens($0.title)) }.prefix(5).map(\.title)
            var hint = ""
            if !similar.isEmpty {
                let joined = similar.joined(separator: ", ")
                hint = language.pick(" Similar reminders: \(joined).", " Recordatorios parecidos: \(joined).")
            }
            throw JarvisError.notFound(code: "reminder_not_found", LocalizedText(
                en: "I couldn't find a reminder called “\(title)”.\(hint)", es: "No encontré un recordatorio llamado «\(title)».\(hint)"
            ))
        }
        if matches.count == 1 { return .found(matches[0]) }

        var options: [ClarificationOption] = []
        for reminder in matches.prefix(6) {
            let detail = [reminder.listTitle, describeDue(reminder, context)].filter { !$0.isEmpty }.joined(separator: " · ")
            options.append(ClarificationOption(
                label: reminder.title, detail: detail,
                call: ToolCall(tool: call.descriptor.name, arguments: Self.replacingSelector(call.arguments, with: reminder.id))
            ))
        }
        return .outcome(.clarify(Clarification(
            question: language.pick("I found \(matches.count) reminders called “\(title)”. Which one?", "Encontré \(matches.count) recordatorios llamados «\(title)». ¿Cuál?"),
            options: options
        )))
    }

    private static func bestTitleMatches(_ pool: [ReminderInfo], _ title: String) -> [ReminderInfo] {
        let ranked = NameMatcher.rank(pool, query: title, minimumScore: 60) { $0.title }
        guard let top = ranked.first?.score else { return [] }
        return ranked.filter { $0.score == top }.map(\.item)
    }

    private static func replacingSelector(_ arguments: JSONObject, with id: String) -> JSONObject {
        var copy = arguments
        copy["title"] = nil
        copy["list"] = nil
        copy["id"] = .string(id)
        return copy
    }

    // MARK: reminders.complete

    private func complete(_ call: ValidatedToolCall, _ context: ExecutionContext) async throws -> ToolOutcome {
        let language = context.language
        let completed = call.bool("completed") ?? true
        let reminder: ReminderInfo
        switch try await resolve(call, context, preferring: completed ? .pending : .completed) {
        case .found(let found): reminder = found
        case .outcome(let outcome): return outcome
        }
        if reminder.isCompleted == completed {
            let already: String = completed
                ? language.pick("“\(reminder.title)” was already completed.", "«\(reminder.title)» ya estaba completado.")
                : language.pick("“\(reminder.title)” was already open.", "«\(reminder.title)» ya estaba pendiente.")
            return .done(ToolOutput(
                message: already, data: reminder.json(calendar: context.calendar),
                verification: .verified(language.pick("Checked in Reminders.", "Comprobado en Recordatorios."))
            ))
        }
        var changes = ReminderChanges()
        changes.completed = completed
        _ = try await store.update(id: reminder.id, changes: changes, calendar: context.calendar)
        guard let stored = try await store.reminder(id: reminder.id, calendar: context.calendar), stored.isCompleted == completed else {
            throw JarvisError.verificationFailed(LocalizedText(en: "Reminders did not keep the change; please check the app.", es: "Recordatorios no conservó el cambio; revisa la app."))
        }
        let message: String = completed
            ? language.pick("Marked “\(stored.title)” as completed.", "Marqué «\(stored.title)» como completado.")
            : language.pick("Reopened “\(stored.title)”.", "Reabrí «\(stored.title)».")
        return .done(ToolOutput(
            message: message, data: stored.json(calendar: context.calendar),
            verification: .verified(language.pick("Re-read from Reminders: completion state matches.", "Releído desde Recordatorios: el estado coincide."))
        ))
    }

    // MARK: reminders.update

    private func update(_ call: ValidatedToolCall, _ context: ExecutionContext) async throws -> ToolOutcome {
        let language = context.language
        let reminder: ReminderInfo
        switch try await resolve(call, context, preferring: .all) {
        case .found(let found): reminder = found
        case .outcome(let outcome): return outcome
        }

        var changes = ReminderChanges()
        changes.title = call.string("new_title")
        changes.notes = call.string("new_notes")
        if let priority = call.string("new_priority") { changes.priority = Self.priorityValue(priority) }
        if call.bool("clear_due") == true {
            changes.clearDue = true
        } else {
            changes.due = dueSpec(call.string("new_due"), timeZone: context.timeZone)
        }
        if let listName = call.string("new_list") {
            let lists = try await store.lists()
            switch resolveList(name: listName, id: nil, lists: lists, settings: context.settings, requireWritable: true) {
            case .use(let list):
                changes.listID = list.id
            case .missing:
                let known = lists.map(\.title).joined(separator: ", ")
                throw JarvisError.notFound("list_not_found", en: "There is no Reminders list called “\(listName)”. Your lists: \(known).", es: "No existe una lista de Recordatorios llamada «\(listName)». Tus listas: \(known).")
            case .ambiguous:
                throw JarvisError.failed("ambiguous_list", en: "Several lists are called “\(listName)”; please say which account.", es: "Varias listas se llaman «\(listName)»; indica de qué cuenta.")
            case .readOnly(let name):
                throw EventKitFailure.readOnly(name)
            }
        }

        _ = try await store.update(id: reminder.id, changes: changes, calendar: context.calendar)
        guard let stored = try await store.reminder(id: reminder.id, calendar: context.calendar) else {
            throw JarvisError.verificationFailed(LocalizedText(en: "Reminders no longer returns this reminder.", es: "Recordatorios ya no devuelve este recordatorio."))
        }
        var matches = true
        if let title = changes.title, stored.title != title { matches = false }
        if changes.clearDue {
            if stored.due != nil { matches = false }
        } else if let due = changes.due, !sameDue(stored, due, calendar: context.calendar) {
            matches = false
        }
        if let listID = changes.listID, stored.listID != listID { matches = false }
        if let priority = changes.priority, stored.priority != priority { matches = false }
        guard matches else {
            throw JarvisError.verificationFailed(LocalizedText(en: "Reminders did not keep every change; please check the app.", es: "Recordatorios no conservó todos los cambios; revisa la app."))
        }
        let base: String = language.pick("Updated “\(stored.title)” in \(stored.listTitle)", "Actualicé «\(stored.title)» en \(stored.listTitle)")
        return .done(ToolOutput(
            message: appended(base, dueText: describeDue(stored, context), language),
            data: stored.json(calendar: context.calendar),
            verification: .verified(language.pick("Re-read from Reminders: the changes are saved.", "Releído desde Recordatorios: los cambios están guardados."))
        ))
    }

    // MARK: reminders.delete

    private func delete(_ call: ValidatedToolCall, _ context: ExecutionContext) async throws -> ToolOutcome {
        let language = context.language
        let reminder: ReminderInfo
        switch try await resolve(call, context, preferring: .all) {
        case .found(let found): reminder = found
        case .outcome(let outcome): return outcome
        }
        if !context.isConfirmed {
            let prompt: String = language.pick(
                "Delete the reminder “\(reminder.title)” from “\(reminder.listTitle)”? This cannot be undone.",
                "¿Eliminar el recordatorio «\(reminder.title)» de «\(reminder.listTitle)»? No se puede deshacer."
            )
            return .confirm(ConfirmationRequest(prompt: prompt, call: ToolCall(tool: .remindersDelete, arguments: ["id": .string(reminder.id)]), destructive: true))
        }
        try await store.delete(id: reminder.id)
        let leftover = try await store.reminder(id: reminder.id, calendar: context.calendar)
        guard leftover == nil else {
            throw JarvisError.verificationFailed(LocalizedText(en: "The reminder is still in Reminders after deleting it.", es: "El recordatorio sigue en Recordatorios después de eliminarlo."))
        }
        return .done(ToolOutput(
            message: language.pick("Deleted “\(reminder.title)”.", "Eliminé «\(reminder.title)»."),
            data: ["id": .string(reminder.id), "title": .string(reminder.title), "deleted": true],
            verification: .verified(language.pick("The reminder is no longer in Reminders.", "El recordatorio ya no está en Recordatorios."))
        ))
    }

    // MARK: Lists

    private func listLists(_ context: ExecutionContext) async throws -> ToolOutcome {
        let language = context.language
        let lists = try await store.lists()
        guard !lists.isEmpty else {
            return .done(ToolOutput(message: language.pick("You have no reminder lists.", "No tienes listas de recordatorios."), data: ["lists": [], "count": 0], verification: .notApplicable))
        }
        let all = try await store.reminders(in: nil, calendar: context.calendar)
        let pendingByList = Dictionary(grouping: all.filter { !$0.isCompleted }, by: \.listID).mapValues(\.count)
        var lines: [String] = []
        for list in lists {
            let pending = pendingByList[list.id] ?? 0
            var line: String = "\(list.title) — " + language.pick("\(pending) pending", "\(pending) pendientes")
            if !list.sourceName.isEmpty { line += " (\(list.sourceName))" }
            if !list.allowsModifications { line += language.pick(" · read-only", " · solo lectura") }
            lines.append(line)
        }
        let header: String = language.pick("You have \(lists.count) reminder lists:\n", "Tienes \(lists.count) listas de recordatorios:\n")
        return .done(ToolOutput(
            message: header + Formatting.bullets(lines),
            data: ["lists": .array(lists.map(\.json)), "count": .int(lists.count)], verification: .notApplicable
        ))
    }

    private func createList(_ call: ValidatedToolCall, _ context: ExecutionContext) async throws -> ToolOutcome {
        let language = context.language
        let name = call.string("name") ?? ""
        let lists = try await store.lists()
        let foldedName = TextFolding.fold(name)
        if let existing = lists.first(where: { TextFolding.fold($0.title) == foldedName }) {
            var data = existing.json.objectValue ?? [:]
            data["created"] = false
            return .done(ToolOutput(
                message: language.pick("The list “\(existing.title)” already exists.", "La lista «\(existing.title)» ya existe."),
                data: .object(data),
                verification: .verified(language.pick("Checked in Reminders.", "Comprobado en Recordatorios."))
            ))
        }
        let created = try await store.createList(title: name, preferredSourceID: lists.first(where: \.isDefault)?.sourceID)
        let confirmed = try await store.lists().first { $0.id == created.id }
        guard confirmed != nil else {
            throw JarvisError.verificationFailed(LocalizedText(en: "Reminders does not show the new list; please check the app.", es: "Recordatorios no muestra la lista nueva; revisa la app."))
        }
        var message: String = language.pick("Created the list “\(created.title)”", "Creé la lista «\(created.title)»")
        if !created.sourceName.isEmpty { message += language.pick(" in \(created.sourceName)", " en \(created.sourceName)") }
        var data = created.json.objectValue ?? [:]
        data["created"] = true
        return .done(ToolOutput(
            message: message + ".", data: .object(data),
            verification: .verified(language.pick("The list appears in Reminders.", "La lista aparece en Recordatorios."))
        ))
    }
}
