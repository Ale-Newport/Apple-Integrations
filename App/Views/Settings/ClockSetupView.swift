import AppKit
import JarvisCore
import JarvisIntegrations
import SwiftUI

/// The Clock app has no scripting interface, so alarms and timers go through a few small Shortcuts the user builds
/// once. This view shows which exist, what is missing and the exact steps to build each one.
struct ClockSetupView: View {
    @Environment(AppModel.self) private var model
    @State private var expanded: Set<ClockShortcut> = []

    private var names: ShortcutNames { model.settings.shortcutNames }

    private var missing: [ClockShortcut] {
        ClockShortcut.allCases.filter { model.shortcutPresence[$0] == false }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.t("Clock shortcuts (one-time setup)", "Atajos del Reloj (configuración única)")).font(.headline)
            Text(model.t(
                "macOS gives apps no direct way to create alarms or timers. Jarvis uses small shortcuts that call the Clock app's own Shortcuts actions. The first and fifth are enough to create alarms and timers; the others let Jarvis list, switch off, delete and — above all — verify them.",
                "macOS no ofrece a las apps una forma directa de crear alarmas o temporizadores. Jarvis usa pequeños atajos que llaman a las acciones propias de la app Reloj. Con el primero y el quinto basta para crear alarmas y temporizadores; los demás permiten listar, desactivar, eliminar y, sobre todo, verificar."
            ))
            .font(.callout).foregroundStyle(.secondary)

            if !model.shortcutsToolAvailable {
                Label(model.t("The Shortcuts command-line tool is not available on this Mac.", "La herramienta de línea de comandos de Atajos no está disponible en este Mac."), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }

            ForEach(ClockShortcut.allCases, id: \.self) { shortcut in
                row(shortcut)
            }

            HStack {
                Button(model.t("Open Shortcuts", "Abrir Atajos")) { model.openShortcutsApp() }
                Button(model.t("Check again", "Comprobar de nuevo")) { model.refreshShortcutPresence() }
                Button(model.t("Copy steps for missing shortcuts", "Copiar pasos de los atajos que faltan")) { copyMissingSteps() }
                    .disabled(missing.isEmpty)
            }
            Text(model.t(
                "Finally, run each shortcut once from the Shortcuts app and choose “Always Allow” if macOS asks. Full guide: docs/SHORTCUTS_SETUP.md",
                "Por último, ejecuta cada atajo una vez desde la app Atajos y elige «Permitir siempre» si macOS lo pide. Guía completa: docs/SHORTCUTS_SETUP.md"
            ))
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func row(_ shortcut: ClockShortcut) -> some View {
        let name = shortcut.name(in: names)
        let present = model.shortcutPresence[shortcut]
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: present == true ? "checkmark.circle.fill" : (present == false ? "circle.dashed" : "ellipsis.circle"))
                    .foregroundStyle(present == true ? Color.green : (shortcut.isEssentialForCreating ? Color.orange : Color.secondary))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(name).font(.system(.callout, design: .monospaced))
                        Text(shortcut.isEssentialForCreating ? model.t("required", "necesario") : model.t("optional", "opcional"))
                            .font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                    Text(shortcut.purpose.resolved(model.language)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if present != true {
                    Button(expanded.contains(shortcut) ? model.t("Hide steps", "Ocultar pasos") : model.t("Show steps", "Ver pasos")) {
                        if expanded.contains(shortcut) { expanded.remove(shortcut) } else { expanded.insert(shortcut) }
                    }
                    .buttonStyle(.link)
                } else {
                    Text(model.t("Found", "Encontrado")).font(.caption).foregroundStyle(.green)
                }
            }
            if present != true, expanded.contains(shortcut) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(shortcut.steps(name: name, language: model.language).enumerated()), id: \.offset) { index, step in
                        Text("\(index + 1). \(step)").font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                    Text(model.t("Input Jarvis sends: ", "Entrada que envía Jarvis: ") + shortcut.inputExample)
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                    Text(model.t("Output: ", "Salida: ") + shortcut.outputDescription.resolved(model.language))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.leading, 26)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private func copyMissingSteps() {
        let instructions = ClockShortcut.instructions(missing: missing, names: names, language: model.language)
        let text = ([instructions.title] + instructions.steps).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        model.notice = model.t("Steps copied.", "Pasos copiados.")
    }
}
