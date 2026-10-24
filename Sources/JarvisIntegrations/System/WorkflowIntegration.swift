import Foundation
import JarvisCore

/// Explicit user-approved Shortcuts are the extension mechanism for Focus, third-party apps and future adapters.
public struct WorkflowIntegration: AppIntegration {
    public let id: IntegrationID = "workflows"
    public let displayName = LocalizedText(en: "Approved workflows", es: "Flujos aprobados")
    public let summary = LocalizedText(
        en: "Runs explicitly approved Shortcuts. Every execution asks for confirmation.",
        es: "Ejecuta Atajos aprobados explícitamente. Cada ejecución pide confirmación.")
    public let symbolName = "point.3.connected.trianglepath.dotted"
    public let permissionRequirements: [PermissionRequirement] = []
    private let shortcuts: any ShortcutsRunning
    public init(shortcuts: any ShortcutsRunning = ShortcutsCLIRunner()) { self.shortcuts = shortcuts }
    public var tools: [ToolDescriptor] {
        [
            ToolDescriptor(
                name: "workflows.list", integration: id, title: "List approved workflows",
                summary: "Shows only workflows the user explicitly approved and whether they are installed.",
                safety: .readOnly),
            ToolDescriptor(
                name: "workflows.run", integration: id, title: "Run approved workflow",
                summary:
                    "Runs one user-approved Shortcut after confirmation. Text input is data; the model cannot add to the allowlist. An exit code does not verify external side effects.",
                parameters: [
                    .string("name", "Exact approved Shortcut name.", required: true, maxLength: 200),
                    .string("input", "Optional text input.", maxLength: 20000),
                ], safety: .modifying, timeout: 60, deduplicate: true, requiresConfirmation: true),
            ToolDescriptor(
                name: "workflows.focus", integration: id, title: "Set Focus through Shortcut",
                summary:
                    "Runs the configured, explicitly approved Focus Shortcut with JSON input {enabled,mode,until}. The Shortcut must implement an end time. This is unavailable until the user approves and installs the workflow; output is not independent verification.",
                parameters: [
                    .boolean("enabled", "Enable Focus.", required: true),
                    .string("mode", "Focus name.", maxLength: 100),
                    .integer("duration_minutes", "Minutes until Focus ends.", min: 1, max: 1440, default: 60),
                ], safety: .modifying, timeout: 60, requiresConfirmation: true),
        ]
    }
    public func status() async -> IntegrationStatus {
        IntegrationStatus(
            state: .ready,
            detail: LocalizedText(
                en: "Approve workflows in Integration settings before running them.",
                es: "Aprueba los flujos en Ajustes de Integraciones antes de ejecutarlos."))
    }
    public func authorization(for tool: ToolDescriptor) async -> AuthorizationState { .authorized }
    public func requestAuthorization(for tool: ToolDescriptor) async -> AuthorizationState { .authorized }
    public func execute(_ call: ValidatedToolCall, context: ExecutionContext) async throws -> ToolOutcome {
        let approved = context.settings.capabilities.approvedWorkflows
        let installed = try await shortcuts.installedShortcutNames()
        if call.descriptor.name.rawValue == "workflows.list" {
            return .done(
                ToolOutput(
                    message: context.language.pick("Approved workflows listed.", "Flujos aprobados consultados."),
                    data: [
                        "workflows": .array(
                            approved.map { ["name": .string($0), "installed": .bool(installed.contains($0))] })
                    ], verification: .notApplicable))
        }
        let focus = call.descriptor.name.rawValue == "workflows.focus"
        let name = focus ? context.settings.capabilities.focusShortcut : call.string("name") ?? ""
        guard approved.contains(name), installed.contains(name) else {
            throw integrationFailure(
                "workflow_not_approved",
                "Install and explicitly approve that Shortcut in Settings > Integrations first.",
                "Instala y aprueba explícitamente ese Atajo en Ajustes > Integraciones primero.")
        }
        var input = call.string("input")
        if focus {
            input = JSONValue.object([
                "enabled": .bool(call.bool("enabled") == true),
                "mode": .string(call.string("mode") ?? "Do Not Disturb"),
                "until": .string(
                    ISODates.string(
                        from: context.now.addingTimeInterval(Double(call.int("duration_minutes") ?? 60) * 60),
                        timeZone: context.timeZone)),
            ]).canonicalString()
        }
        if !context.isConfirmed {
            return .confirm(
                ConfirmationRequest(
                    prompt: context.language.pick(
                        "Run the approved Shortcut “\(name)”? It may affect other apps or services.",
                        "¿Ejecutar el Atajo aprobado «\(name)»? Puede afectar a otras apps o servicios.")
                        + (input.map { "\n" + $0 } ?? ""), call: call.call, destructive: false))
        }
        let output = try await shortcuts.run(name: name, input: input, timeout: 50)
        return .done(
            ToolOutput(
                message: context.language.pick(
                    "Shortcut ran. Check its output for the effect.",
                    "El Atajo se ejecutó. Consulta su salida para comprobar el efecto."),
                data: ["workflow": .string(name), "output": .string(String(output.text.prefix(20000)))],
                verification: .unverified(
                    context.language.pick(
                        "The Shortcut exited successfully; effects in other apps were not independently read back.",
                        "El Atajo terminó correctamente; no se releyeron independientemente sus efectos en otras apps.")
                )))
    }
}
