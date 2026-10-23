import AppKit
import SwiftUI

/// A button that records the next key combination the user presses (Esc cancels).
///
/// It listens with a *local* event monitor, so it only sees keystrokes sent to Jarvis' own settings window and
/// needs no Accessibility or Input Monitoring permission.
struct ShortcutRecorder: View {
    @Environment(AppModel.self) private var model
    let combo: HotKeyCombo
    let onChange: (HotKeyCombo) -> Void

    @State private var recording = false
    @State private var monitor: Any?
    @State private var hint: String?

    var body: some View {
        HStack(spacing: 8) {
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? model.t("Press the new shortcut…", "Pulsa el nuevo atajo…") : combo.display)
                    .frame(minWidth: 150)
                    .font(.system(.body, design: .rounded).monospaced())
            }
            .help(model.t("Click, then press the key combination you want. Esc cancels.", "Haz clic y pulsa la combinación de teclas que quieras. Esc cancela."))
            .accessibilityLabel(model.t("Global shortcut: \(combo.display)", "Atajo global: \(combo.display)"))
            if let hint {
                Text(hint).font(.caption).foregroundStyle(.orange)
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        hint = nil
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Escape
                stop()
                return nil
            }
            if let captured = HotKeyCombo.from(event) {
                onChange(captured)
                stop()
            } else {
                hint = model.t("Include at least one modifier (⌃ ⌥ ⇧ ⌘).", "Incluye al menos un modificador (⌃ ⌥ ⇧ ⌘).")
            }
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
