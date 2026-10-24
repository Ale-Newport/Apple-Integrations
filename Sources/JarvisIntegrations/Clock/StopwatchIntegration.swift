import Foundation
import JarvisCore

/// Explicitly Jarvis-managed; no timer loop and no claim to control Clock's stopwatch.
public actor StopwatchStore {
    private struct State: Codable {
        var started: Date?
        var elapsed: Double = 0
        var laps: [Double] = []
    }
    private let url: URL
    public init(url: URL = JarvisPaths.applicationSupportDirectory().appendingPathComponent("stopwatch.json")) {
        self.url = url
    }
    func run(operation: String, now: Date, confirmed: Bool, call: ToolCall, language: Language) throws -> ToolOutcome {
        var state: State
        if FileManager.default.fileExists(atPath: url.path) {
            state = try JSONDecoder().decode(State.self, from: Data(contentsOf: url))
        } else {
            state = State()
        }
        func elapsed(_ value: State) -> Double {
            value.elapsed + max(0, value.started.map { now.timeIntervalSince($0) } ?? 0)
        }
        if operation == "reset" && !confirmed {
            return .confirm(
                ConfirmationRequest(
                    prompt: language.pick(
                        "Reset the Jarvis stopwatch and remove its laps?",
                        "¿Reiniciar el cronómetro de Jarvis y borrar sus vueltas?"), call: call, destructive: false))
        }
        switch operation {
        case "start", "resume": if state.started == nil { state.started = now }
        case "pause":
            state.elapsed = elapsed(state)
            state.started = nil
        case "lap":
            guard state.started != nil, state.laps.count < 100 else { throw Calculator.Failure.invalidExpression }
            state.laps.append(elapsed(state))
        case "reset": state = State()
        case "status": break
        default: throw Calculator.Failure.invalidExpression
        }
        if operation != "status" {
            guard JarvisPaths.ensurePrivateDirectory(url.deletingLastPathComponent()) else {
                throw CocoaError(.fileWriteNoPermission)
            }
            try JSONEncoder().encode(state).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        let seconds = elapsed(state)
        return .done(
            ToolOutput(
                message: language.pick("Jarvis stopwatch: ", "Cronómetro de Jarvis: ")
                    + String(format: "%.2f s", seconds) + (state.started == nil ? " · paused / en pausa" : ""),
                data: [
                    "elapsed_seconds": .double(seconds), "running": .bool(state.started != nil),
                    "laps_seconds": .array(state.laps.map(JSONValue.double)), "backend": "jarvis_stopwatch",
                    "includes_system_sleep": true,
                ],
                verification: operation == "status"
                    ? .notApplicable
                    : .verified("Persisted Jarvis stopwatch state; elapsed wall time includes system sleep.")))
    }
}
public struct StopwatchIntegration: AppIntegration {
    public let id: IntegrationID = "stopwatch"
    public let displayName = LocalizedText(en: "Jarvis stopwatch", es: "Cronómetro de Jarvis")
    public let summary = LocalizedText(
        en: "Persisted stopwatch with pause, resume and laps. Elapsed wall time includes sleep; separate from Clock.",
        es:
            "Cronómetro persistente con pausa, reanudación y vueltas. Incluye el tiempo en suspensión; independiente de Reloj."
    )
    public let symbolName = "stopwatch"
    public let permissionRequirements: [PermissionRequirement] = []
    private let store: StopwatchStore
    public init(store: StopwatchStore = StopwatchStore()) { self.store = store }
    public var tools: [ToolDescriptor] {
        [
            ToolDescriptor(
                name: "stopwatch.control", integration: id, title: "Jarvis stopwatch",
                summary:
                    "Controls the persisted Jarvis stopwatch, separate from native Clock. Wall time includes sleep. Start/resume preserves elapsed time; reset clears it after confirmation. At most 100 laps.",
                parameters: [
                    .choice(
                        "operation", ["start", "pause", "resume", "lap", "reset", "status"], "Stopwatch action.",
                        required: true)
                ], safety: .modifying)
        ]
    }
    public func status() async -> IntegrationStatus { IntegrationStatus(state: .ready) }
    public func authorization(for tool: ToolDescriptor) async -> AuthorizationState { .authorized }
    public func requestAuthorization(for tool: ToolDescriptor) async -> AuthorizationState { .authorized }
    public func execute(_ call: ValidatedToolCall, context: ExecutionContext) async throws -> ToolOutcome {
        try await store.run(
            operation: call.string("operation") ?? "status", now: context.now, confirmed: context.isConfirmed,
            call: call.call, language: context.language)
    }
}
