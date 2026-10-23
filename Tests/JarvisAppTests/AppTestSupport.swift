import Foundation
import JarvisCore
import XCTest

/// A scripted interpreter: each command text maps to the tool calls it should produce.
struct ScriptedInterpreter: CommandInterpreting {
    let identifier = "scripted"
    let script: [String: [ToolCall]]

    func interpret(_ request: InterpretationRequest) async throws -> Interpretation {
        guard let steps = script[request.text] else { return .unrecognized(hint: nil) }
        return .plan(ToolPlan(steps: steps, language: request.language, interpreter: identifier))
    }
}

/// Lets a stub integration hold a command open until the test releases it.
actor Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false

    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}

final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func add(_ value: String) { lock.withLock { values.append(value) } }
    var all: [String] { lock.withLock { values } }
}

/// A fake Apple integration with a configurable permission state and handler. Nothing here touches a real app.
final class StubIntegration: AppIntegration, @unchecked Sendable {
    let id: IntegrationID
    let displayName = LocalizedText(en: "Stub", es: "Stub")
    let summary = LocalizedText(en: "A stub integration", es: "Una integración de prueba")
    let symbolName = "questionmark"
    let tools: [ToolDescriptor]
    let permissionRequirements: [PermissionRequirement]
    let calls = CallLog()
    /// Executions the engine marked as confirmed by the user.
    let confirmedCalls = CallLog()
    let requests = CallLog()

    private let lock = NSLock()
    private var _authorization: AuthorizationState = .authorized
    private let handler: @Sendable (ValidatedToolCall, ExecutionContext) async throws -> ToolOutcome

    var authorization: AuthorizationState {
        get { lock.withLock { _authorization } }
        set { lock.withLock { _authorization = newValue } }
    }

    static let requirement = PermissionRequirement(id: "stub", title: LocalizedText(en: "Stub access", es: "Acceso"), rationale: LocalizedText(en: "Needed", es: "Necesario"))

    init(id: IntegrationID = "stub", tools: [ToolDescriptor], handler: @escaping @Sendable (ValidatedToolCall, ExecutionContext) async throws -> ToolOutcome) {
        self.id = id
        self.tools = tools
        self.permissionRequirements = [Self.requirement]
        self.handler = handler
    }

    func status() async -> IntegrationStatus {
        IntegrationStatus(state: authorization.isAuthorized ? .ready : .needsPermission)
    }

    func authorization(for tool: ToolDescriptor) async -> AuthorizationState { authorization }

    func requestAuthorization(for tool: ToolDescriptor) async -> AuthorizationState {
        requests.add(tool.name.rawValue)
        return authorization
    }

    func execute(_ call: ValidatedToolCall, context: ExecutionContext) async throws -> ToolOutcome {
        calls.add(call.descriptor.name.rawValue)
        if context.isConfirmed { confirmedCalls.add(call.descriptor.name.rawValue) }
        return try await handler(call, context)
    }
}

func stubTool(_ name: ToolName, integration: IntegrationID = "stub", safety: ToolSafety = .readOnly, parameters: [ToolParameter] = []) -> ToolDescriptor {
    ToolDescriptor(name: name, integration: integration, title: name.rawValue, summary: "Stub \(name.rawValue)", parameters: parameters, safety: safety, timeout: 10)
}

extension AppEnvironment {
    /// An environment that cannot touch the user's data: temporary history, a throw-away settings suite and a
    /// private socket path. IPC stays off unless a test turns it on.
    @MainActor
    static func isolated(integrations: [any AppIntegration], interpreter: any CommandInterpreting, directory: URL) -> AppEnvironment {
        let suite = "jarvis.app.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = UserDefaultsSettingsStore(defaults: defaults, key: "settings")
        var settings = JarvisSettings()
        settings.ipcEnabled = false
        store.save(settings)
        return AppEnvironment(
            settingsStore: store,
            history: HistoryStore(fileURL: directory.appendingPathComponent("history.json")),
            integrations: integrations,
            interpreter: interpreter,
            ipcSocketURL: directory.appendingPathComponent("jarvis.sock")
        )
    }
}

@MainActor
extension XCTestCase {
    /// Polls until `condition` holds (UI state is updated from tasks, so tests wait instead of sleeping blindly).
    func waitUntil(_ description: String = "condition", timeout: TimeInterval = 5, _ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("Timed out waiting for \(description)", file: file, line: line)
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-app-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}
