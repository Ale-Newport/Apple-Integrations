import AppKit
import JarvisCore
import SwiftUI

struct PrivacySettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmClear = false

    private func showInFinder() {
        let file = JarvisPaths.historyFile()
        if FileManager.default.fileExists(atPath: file.path) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else {
            let folder = JarvisPaths.applicationSupportDirectory()
            JarvisPaths.ensurePrivateDirectory(folder)
            NSWorkspace.shared.open(folder)
        }
    }

    var body: some View {
        Form {
            Section(model.t("Command history", "Historial de comandos")) {
                Toggle(model.t("Remember the commands I run", "Recordar los comandos que ejecuto"), isOn: model.binding(\.saveHistory))
                Text(model.t(
                    "History lets you reuse earlier commands (↑ in the command field, History in the sidebar). It is stored only on this Mac, in a file readable only by you, and is never sent anywhere.",
                    "El historial te permite reutilizar comandos anteriores (↑ en el campo de comandos, Historial en la barra lateral). Se guarda solo en este Mac, en un archivo legible solo por ti, y no se envía a ningún sitio."
                ))
                .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text(model.t("\(model.historyEntries.count) saved commands", "\(model.historyEntries.count) comandos guardados"))
                    Spacer()
                    Button(model.t("Show in Finder", "Mostrar en el Finder")) { showInFinder() }
                    Button(model.t("Delete history…", "Borrar historial…"), role: .destructive) { confirmClear = true }
                        .disabled(model.historyEntries.isEmpty)
                }
            }

            Section(model.t("What Jarvis keeps and shares", "Qué guarda y comparte Jarvis")) {
                bullet("lock.shield", model.t("Your reminders, notes, events and music stay in the Apple apps; Jarvis reads or changes them only to carry out your command.", "Tus recordatorios, notas, eventos y música permanecen en las apps de Apple; Jarvis solo los lee o cambia para ejecutar tu comando."))
                bullet("network.slash", model.t("No cloud service, analytics or account. The built-in understanding of commands runs entirely on this Mac.", "Sin servicios en la nube, analíticas ni cuentas. La comprensión de comandos integrada funciona por completo en este Mac."))
                bullet("doc.text.magnifyingglass", model.t("System logs never include the text of your notes, titles or commands (they are marked private).", "Los registros del sistema nunca incluyen el texto de tus notas, títulos o comandos (se marcan como privados)."))
                bullet("key", model.t("Any API key for an optional AI interpreter would be kept in the macOS Keychain, never in files.", "Cualquier clave de API de un intérprete de IA opcional se guardaría en el llavero de macOS, nunca en archivos."))
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(model.t("Delete all history?", "¿Borrar todo el historial?"), isPresented: $confirmClear) {
            Button(model.t("Delete history", "Borrar historial"), role: .destructive) { model.clearHistory() }
        } message: {
            Text(model.t("Only Jarvis' own record is removed; nothing in your Apple apps is touched.", "Solo se borra el registro de Jarvis; no se toca nada de tus apps de Apple."))
        }
        .onAppear { model.refreshHistory() }
    }

    private func bullet(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 20)
        }
    }
}

struct AdvancedSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmReset = false

    private var controlTool: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/jarvisctl").path
    }

    var body: some View {
        Form {
            Section(model.t("Local control channel", "Canal de control local")) {
                Toggle(model.t("Let other programs on this Mac send commands to Jarvis", "Permitir que otros programas de este Mac envíen comandos a Jarvis"), isOn: model.binding(\.ipcEnabled))
                LabeledContent(model.t("Status", "Estado")) {
                    if model.environment.ipc.isRunning {
                        Label(model.t("Listening", "Escuchando"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else if let error = model.environment.ipc.lastError {
                        Text(error).foregroundStyle(.orange)
                    } else {
                        Text(model.t("Off", "Desactivado")).foregroundStyle(.secondary)
                    }
                }
                LabeledContent(model.t("Socket", "Socket")) {
                    Text(model.environment.ipc.socketPath).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
                Text(model.t(
                    "A Unix-domain socket inside your user folder, restricted to your account (0600). It accepts the same commands as the chat, never leaves this Mac and cannot be reached over the network. Protocol: docs/IPC.md",
                    "Un socket de dominio Unix dentro de tu carpeta de usuario, restringido a tu cuenta (0600). Acepta los mismos comandos que el chat, no sale de este Mac y no es accesible por red. Protocolo: docs/IPC.md"
                ))
                .font(.caption).foregroundStyle(.secondary)
            }

            Section(model.t("Command-line tool", "Herramienta de línea de comandos")) {
                LabeledContent("jarvisctl") {
                    Text(controlTool).font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(2)
                }
                Button(model.t("Copy example", "Copiar ejemplo")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("\"\(controlTool)\" \"Add buy milk to my Shopping reminders list\"", forType: .string)
                    model.notice = model.t("Example copied.", "Ejemplo copiado.")
                }
            }

            Section(model.t("Behaviour", "Comportamiento")) {
                Stepper(value: model.binding(\.duplicateWindowSeconds), in: 0...60, step: 1) {
                    Text(model.t(
                        "Ignore an identical create command repeated within \(Int(model.settings.duplicateWindowSeconds)) s",
                        "Ignorar un comando de creación idéntico repetido en \(Int(model.settings.duplicateWindowSeconds)) s"
                    ))
                }
                Text(model.t("Protects against double-pressing Return or a script retrying. Set to 0 to disable.", "Protege contra pulsar Intro dos veces o un script que reintenta. Pon 0 para desactivarlo."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Button(model.t("Reset all Jarvis settings…", "Restablecer todos los ajustes de Jarvis…"), role: .destructive) { confirmReset = true }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(model.t("Reset settings?", "¿Restablecer ajustes?"), isPresented: $confirmReset) {
            Button(model.t("Reset", "Restablecer"), role: .destructive) { model.update { $0 = JarvisSettings() } }
        } message: {
            Text(model.t("Defaults, shortcut names and preferences go back to their original values. Your data in Apple apps is not affected.", "Los valores predeterminados, nombres de atajos y preferencias vuelven a su estado original. Tus datos en las apps de Apple no se ven afectados."))
        }
    }
}
