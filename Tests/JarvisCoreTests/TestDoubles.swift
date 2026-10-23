import Foundation
@testable import JarvisCore

/// A scriptable integration for engine tests. Nothing here touches Apple apps.
final class MockIntegration: AppIntegration, @unchecked Sendable {
    let id: IntegrationID
    let displayName: LocalizedText
    let summary = LocalizedText("mock")
    let symbolName = "puzzlepiece"
    let tools: [ToolDescriptor]
    let permissionRequirements: [PermissionRequirement]

    private let lock = NSLock()
    private var _authorization: AuthorizationState
    private var _requestResult: AuthorizationState?
    private var _calls: [(tool: ToolName, arguments: JSONObject, confirmed: Bool)] = []
    private var _requests = 0
    var handler: @Sendable (ValidatedToolCall, ExecutionContext) async throws -> ToolOutcome

    init(
        id: IntegrationID,
        tools: [ToolDescriptor],
        authorization: AuthorizationState = .authorized,
        handler: @escaping @Sendable (ValidatedToolCall, ExecutionContext) async throws -> ToolOutcome = { call, _ in
            .done(ToolOutput(message: "ran \(call.descriptor.name)", data: ["ok": true], verification: .verified("mock read-back")))
        }
    ) {
        self.id = id
        self.displayName = LocalizedText(id.rawValue)
        self.tools = tools
        self.permissionRequirements = []
        self._authorization = authorization
        self.handler = handler
    }

    var authorizationState: AuthorizationState {
        get { lock.lock(); defer { lock.unlock() }; return _authorization }
        set { lock.lock(); _authorization = newValue; lock.unlock() }
    }

    var stateAfterRequest: AuthorizationState? {
        get { lock.lock(); defer { lock.unlock() }; return _requestResult }
        set { lock.lock(); _requestResult = newValue; lock.unlock() }
    }

    var calls: [(tool: ToolName, arguments: JSONObject, confirmed: Bool)] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    func status() async -> IntegrationStatus { IntegrationStatus(state: .ready) }

    func authorization(for tool: ToolDescriptor) async -> AuthorizationState { authorizationState }

    func requestAuthorization(for tool: ToolDescriptor) async -> AuthorizationState {
        recordRequest()
    }

    private func recordRequest() -> AuthorizationState {
        lock.withLock {
            _requests += 1
            if let result = _requestResult { _authorization = result }
            return _authorization
        }
    }

    func execute(_ call: ValidatedToolCall, context: ExecutionContext) async throws -> ToolOutcome {
        record(call, confirmed: context.isConfirmed)
        return try await handler(call, context)
    }

    private func record(_ call: ValidatedToolCall, confirmed: Bool) {
        lock.withLock { _calls.append((call.descriptor.name, call.arguments, confirmed)) }
    }
}

/// An interpreter that returns whatever the test dictates.
struct StubInterpreter: CommandInterpreting {
    let identifier = "stub"
    var result: @Sendable (InterpretationRequest) -> Interpretation

    init(_ result: @escaping @Sendable (InterpretationRequest) -> Interpretation) { self.result = result }

    init(plan steps: [ToolCall]) {
        self.result = { request in .plan(ToolPlan(steps: steps, language: request.language, interpreter: "stub")) }
    }

    func interpret(_ request: InterpretationRequest) async throws -> Interpretation { result(request) }
}

actor HistoryRecorder: HistoryRecording {
    private(set) var entries: [HistoryEntry] = []
    private(set) var updates: [(UUID, EngineResponse.Status)] = []

    func record(_ entry: HistoryEntry) { entries.append(entry) }
    func update(id: UUID, status: EngineResponse.Status, summary: String) { updates.append((id, status)) }
}

enum Fixtures {
    static func tool(
        _ name: ToolName,
        integration: IntegrationID = "mock",
        safety: ToolSafety = .modifying,
        parameters: [ToolParameter] = [],
        constraints: [ToolConstraint] = [],
        availability: ToolAvailability = .supported,
        timeout: TimeInterval = 5,
        deduplicate: Bool = false
    ) -> ToolDescriptor {
        ToolDescriptor(
            name: name, integration: integration, title: name.rawValue, summary: "test tool",
            parameters: parameters, constraints: constraints, safety: safety, availability: availability,
            timeout: timeout, deduplicate: deduplicate
        )
    }

    static let requirement = PermissionRequirement(
        id: "mock.permission",
        title: LocalizedText(en: "Mock access", es: "Acceso simulado"),
        rationale: LocalizedText(en: "Needed for tests.", es: "Necesario para pruebas."),
        settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
    )

    static func engine(
        integrations: [any AppIntegration],
        interpreter: any CommandInterpreting,
        settings: JarvisSettings = JarvisSettings(),
        history: (any HistoryRecording)? = nil,
        limits: ActionEngine.Limits = ActionEngine.Limits(),
        fallbackLanguage: Language = .en
    ) -> ActionEngine {
        ActionEngine(
            registry: ToolRegistry(integrations: integrations),
            interpreter: interpreter,
            settings: InMemorySettings(settings),
            history: history,
            dateProvider: FixedDateProvider(now: Date(timeIntervalSince1970: 1_792_000_000), timeZone: TimeZone(identifier: "Europe/London")!),
            limits: limits,
            fallbackLanguage: fallbackLanguage
        )
    }
}
