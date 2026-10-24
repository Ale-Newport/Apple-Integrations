import JarvisCore
import JarvisInterpreter
import XCTest

@testable import JarvisIntegrations

/// Explicit opt-in smoke test. Only synthetic data and an in-memory Notes sink reach the local model.
private actor SyntheticAssistantTools: AppIntegration {
    nonisolated let id: IntegrationID = "fixtures"
    nonisolated let displayName = LocalizedText("Synthetic test")
    nonisolated let summary = LocalizedText("In-memory only")
    nonisolated let symbolName = "testtube.2"
    nonisolated let permissionRequirements: [PermissionRequirement] = []
    nonisolated let tools = IntegrationCatalog.makeDefault().flatMap(\.tools).map { descriptor in
        ToolDescriptor(
            name: descriptor.name, integration: "fixtures", title: descriptor.title, summary: descriptor.summary,
            parameters: descriptor.parameters, constraints: descriptor.constraints, safety: descriptor.safety,
            availability: descriptor.availability, timeout: descriptor.timeout, deduplicate: descriptor.deduplicate,
            examples: descriptor.examples, requiresConfirmation: descriptor.requiresConfirmation)
    }
    private(set) var notes: [String] = []
    func status() async -> IntegrationStatus { IntegrationStatus(state: .ready) }
    func authorization(for tool: ToolDescriptor) async -> AuthorizationState { .authorized }
    func requestAuthorization(for tool: ToolDescriptor) async -> AuthorizationState { .authorized }
    func execute(_ call: ValidatedToolCall, context: ExecutionContext) async throws -> ToolOutcome {
        switch call.descriptor.name.rawValue {
        case "reminders.list":
            return .done(
                ToolOutput(
                    message: "Two synthetic tasks.",
                    data: [
                        "reminders": [
                            ["id": "synthetic-milk", "title": "Comprar leche", "completed": false],
                            ["id": "synthetic-study", "title": "Estudiar Swift", "completed": false],
                        ]
                    ], verification: .notApplicable))
        case "notes.create":
            let text = call.string("content") ?? ""
            notes.append(text)
            return .done(
                ToolOutput(
                    message: "Synthetic note saved in memory.",
                    data: [
                        "id": "synthetic-note", "title": call.arguments["title"] ?? .null, "content": .string(text),
                    ], verification: .verified("In-memory fixture readback.")))
        default:
            throw JarvisError.unsupported(
                LocalizedText("Live tests permit only synthetic reminder reads and note creation."), alternative: nil)
        }
    }
}

final class LiveAgentTests: XCTestCase {
    func testLocalModelCompletesSyntheticDependentWorkflow() async throws {
        guard let model = ProcessInfo.processInfo.environment["JARVIS_LIVE_MODEL"], !model.isEmpty else {
            throw XCTSkip(
                "Set JARVIS_LIVE_MODEL to run against an already installed local Ollama model; uses synthetic data only."
            )
        }
        var settings = JarvisSettings()
        settings.model.enabled = true
        settings.model.model = model
        settings.model.maxRounds = 8
        settings.saveHistory = false
        let fixture = SyntheticAssistantTools()
        let engine = ActionEngine(
            registry: ToolRegistry(integrations: [fixture]),
            interpreter: ConfiguredAgentInterpreter(
                secrets: InMemorySecretStore(), transport: ModelURLSessionTransport()),
            settings: InMemorySettings(settings))
        let response = await engine.process(
            CommandRequest(
                text:
                    "Busca mis recordatorios pendientes para mañana y crea una nota llamada Resumen con todos sus títulos.",
                source: .test, session: "synthetic-live"))
        let notes = await fixture.notes
        XCTAssertEqual(notes.count, 1, "\(response.status): \(response.message) · \(response.results.map(\.tool))")
        XCTAssertTrue(
            notes.first?.contains("Comprar leche") == true,
            "\(notes) · \(response.message) · \(response.results.map(\.tool))")
        XCTAssertTrue(notes.first?.contains("Estudiar Swift") == true)
        XCTAssertEqual(response.status, .completed, "\(response.message)")
    }
}
