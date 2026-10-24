import AppKit
import JarvisCore
import JarvisIntegrations
import ServiceManagement
import SwiftUI

struct CapabilitySettingsSections: View {
    @Environment(AppModel.self) private var model
    @State private var workflows: [String] = []
    @State private var feedback: String?
    @State private var loading = false
    @State private var agentStatus = SMAppService.agent(plistName: ConditionService.plistName).status
    var body: some View {
        Section {
            ForEach(model.settings.capabilities.fileRoots, id: \.self) { path in
                HStack {
                    Text(path).font(.caption).textSelection(.enabled)
                    Spacer()
                    Button(role: .destructive) {
                        model.update { $0.capabilities.fileRoots.removeAll { $0 == path } }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless).help(model.t("Remove access", "Retirar acceso"))
                }
            }
            Button(model.t("Choose an allowed folder…", "Elegir una carpeta permitida…")) { chooseFolder() }
            Text(
                model.t(
                    "Files tools can read and modify only these folders. Changes never overwrite an existing file. Trash and bulk operations ask for confirmation.",
                    "Las herramientas de archivos solo pueden leer y modificar estas carpetas. Nunca sobrescriben un archivo existente. La Papelera y los cambios masivos requieren confirmación."
                )
            )
            .font(.caption).foregroundStyle(.secondary)
        } header: {
            Label(model.t("Files and Finder", "Archivos y Finder"), systemImage: "folder")
        }
        Section {
            Button(
                loading
                    ? model.t("Loading…", "Cargando…") : model.t("Load installed Shortcuts", "Cargar Atajos instalados")
            ) { loadWorkflows() }.disabled(loading)
            ForEach(Array(Set(workflows + model.settings.capabilities.approvedWorkflows)).sorted(), id: \.self) {
                name in
                Toggle(
                    name,
                    isOn: Binding(
                        get: { model.settings.capabilities.approvedWorkflows.contains(name) },
                        set: { allowed in
                            model.update { settings in
                                settings.capabilities.approvedWorkflows.removeAll { $0 == name }
                                if allowed { settings.capabilities.approvedWorkflows.append(name) }
                            }
                        }))
            }
            CommitTextField(
                title: model.t("Focus Shortcut", "Atajo para Concentración"),
                value: model.settings.capabilities.focusShortcut
            ) { name in model.update { $0.capabilities.focusShortcut = name } }
            Text(
                model.t(
                    "Approve only Shortcuts you trust. Jarvis reviews input before each execution. Focus input is JSON with enabled, mode and until; the Shortcut must implement the requested end time.",
                    "Aprueba solo Atajos de confianza. Jarvis muestra la entrada antes de cada ejecución. Concentración recibe JSON con enabled, mode y until; el Atajo debe aplicar la hora de finalización."
                )
            )
            .font(.caption).foregroundStyle(.secondary)
            if let feedback { Text(feedback).font(.caption).foregroundStyle(.secondary) }
        } header: {
            Label(
                model.t("Workflows and third-party apps", "Flujos y apps de terceros"),
                systemImage: "point.3.connected.trianglepath.dotted")
        }
        Section {
            Toggle(
                model.t("Enable future weather checks", "Activar comprobaciones futuras del tiempo"),
                isOn: Binding(
                    get: { model.settings.capabilities.backgroundConditionsEnabled }, set: setConditionsEnabled))
            Text(
                agentStatus == .enabled
                    ? model.t("Background agent enabled by macOS.", "Agente autorizado por macOS.")
                    : agentStatus == .requiresApproval
                        ? model.t(
                            "Approve Jarvis in System Settings > General > Login Items & Extensions.",
                            "Autoriza Jarvis en Ajustes del Sistema > General > Ítems de inicio y extensiones.")
                        : model.t("Background agent is not enabled.", "El agente no está activado.")
            )
            .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(model.t("Allow agent notifications…", "Permitir notificaciones del agente…")) {
                    authorizeAgentNotifications()
                }
                Button(model.t("Refresh status", "Actualizar estado")) {
                    agentStatus = SMAppService.agent(plistName: ConditionService.plistName).status
                }
            }
            Text(
                model.t(
                    "The signed agent checks saved conditions every 15 minutes even with Jarvis closed. Requires a stable installed app, macOS approval and notifications for Jarvis Condition Agent. Sleep or offline periods delay checks; expired jobs do not fire. These are Jarvis notifications, not Clock alarms or Reminders items.",
                    "El agente firmado comprueba las condiciones guardadas cada 15 minutos incluso con Jarvis cerrado. Requiere instalar la app en una ubicación estable, autorización de macOS y notificaciones de Jarvis Condition Agent. La suspensión o la falta de conexión retrasan las comprobaciones; las caducadas no se ejecutan. Son notificaciones de Jarvis, no alarmas de Reloj ni elementos de Recordatorios."
                )
            )
            .font(.caption).foregroundStyle(.secondary)
        } header: {
            Label(model.t("Future conditions", "Condiciones futuras"), systemImage: "calendar.badge.clock")
        }
        Section {
            Text(
                model.t(
                    "Mail creates real drafts; sending requires reviewing all recipients and content. Messages drafts stay in the current Jarvis session. Delivery cannot be independently verified. Messages history is unavailable through its public API.",
                    "Mail crea borradores reales; para enviar debes revisar los destinatarios y el contenido. Los borradores de Mensajes permanecen en la sesión de Jarvis. La entrega no se puede verificar de forma independiente. La API pública de Mensajes no permite leer el historial."
                )
            )
            .font(.caption).foregroundStyle(.secondary)
            Text(
                model.t(
                    "Safari and Chrome page reading require Allow JavaScript from Apple Events in the browser's developer menu. Jarvis never enables this setting itself.",
                    "Para leer páginas de Safari y Chrome hace falta Permitir JavaScript de eventos de Apple en el menú de desarrollador del navegador. Jarvis no activa este ajuste por su cuenta."
                )
            )
            .font(.caption).foregroundStyle(.secondary)
        } header: {
            Label(model.t("Communication and browsers", "Comunicación y navegadores"), systemImage: "envelope")
        }
    }
    private func setConditionsEnabled(_ enabled: Bool) {
        let service = SMAppService.agent(plistName: ConditionService.plistName)
        do {
            if enabled {
                if service.status != .enabled && service.status != .requiresApproval { try service.register() }
            } else {
                try service.unregister()
            }
            model.update { $0.capabilities.backgroundConditionsEnabled = enabled }
            feedback = nil
        } catch {
            feedback =
                model.t("Could not change the background agent: ", "No se pudo cambiar el agente: ")
                + error.localizedDescription
        }
        agentStatus = service.status
    }
    private func authorizeAgentNotifications() {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LoginItems/Jarvis Condition Agent.app")
        guard FileManager.default.fileExists(atPath: url.path) else {
            feedback = model.t(
                "The signed agent is missing from this app build.", "Falta el agente firmado en esta compilación.")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--authorize-notifications"]
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error {
                Task { @MainActor in
                    feedback =
                        model.t("Could not open the agent: ", "No se pudo abrir el agente: ")
                        + error.localizedDescription
                }
            }
        }
    }
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = model.t("Allow folder", "Permitir carpeta")
        guard panel.runModal() == .OK else { return }
        model.update { settings in settings.capabilities.fileRoots += panel.urls.map(\.path).filter { $0 != "/" } }
    }
    private func loadWorkflows() {
        loading = true
        Task {
            defer { loading = false }
            do {
                workflows = Array(try await ShortcutsCLIRunner().installedShortcutNames()).sorted()
                feedback = nil
            } catch {
                feedback =
                    model.t("Could not list Shortcuts: ", "No se pudieron listar los Atajos: ")
                    + error.localizedDescription
            }
        }
    }
}
