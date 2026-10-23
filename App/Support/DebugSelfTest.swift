#if DEBUG
import AppKit
import JarvisCore
import SwiftUI

/// Developer-only: drives the real `InputBar` with synthetic key events delivered straight to an invisible,
/// off-screen window of this process (no Accessibility permission, nothing on screen), and reports what happened.
///
///     open -g -n "Jarvis Apple Integrations.app" --args -JarvisSelfTestOutput /tmp/selftest.txt
@MainActor
enum DebugSelfTest {
    static func run(outputPath: String) async {
        var report: [String] = []
        func note(_ line: String) { report.append(line) }
        func check(_ name: String, _ ok: Bool, _ detail: String = "") { note("\(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : " — \(detail)")") }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-selftest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "jarvis.selftest.\(UUID().uuidString)"
        let store = UserDefaultsSettingsStore(defaults: UserDefaults(suiteName: suite)!, key: "settings")
        var settings = JarvisSettings()
        settings.ipcEnabled = false
        store.save(settings)
        let environment = AppEnvironment(
            settingsStore: store, history: HistoryStore(fileURL: directory.appendingPathComponent("history.json")),
            integrations: [], ipcSocketURL: directory.appendingPathComponent("jarvis.sock")
        )
        let model = AppModel(environment: environment)

        let host = NSHostingView(rootView: InputBar().environment(model))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 90)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.setFrameOrigin(NSPoint(x: -6000, y: -6000))
        window.orderFrontRegardless()
        window.makeKey()
        try? await Task.sleep(for: .milliseconds(600))
        // Focus the real text control exactly as a click would (SwiftUI's @FocusState needs a visible, active window).
        func findEditable(_ view: NSView) -> NSView? {
            if let textView = view as? NSTextView, textView.isEditable { return textView }
            if let field = view as? NSTextField, field.isEditable { return field }
            for subview in view.subviews { if let found = findEditable(subview) { return found } }
            return nil
        }
        if let control = findEditable(host) { window.makeFirstResponder(control) }
        note("focused control: \(findEditable(host).map { String(describing: Swift.type(of: $0)) } ?? "none")")
        try? await Task.sleep(for: .milliseconds(200))

        func send(_ type: NSEvent.EventType, _ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode
            ) else { return }
            window.sendEvent(event)
        }
        func press(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) async {
            send(.keyDown, characters, keyCode: keyCode, modifiers: modifiers)
            send(.keyUp, characters, keyCode: keyCode, modifiers: modifiers)
            try? await Task.sleep(for: .milliseconds(120))
        }
        func typeText(_ text: String) async {
            for character in text { await press(String(character), keyCode: 0) }
        }
        let returnKey: UInt16 = 36
        let upArrow: UInt16 = 126

        note("first responder: \(String(describing: window.firstResponder.map { String(describing: Swift.type(of: $0)) }))")

        // A. typing reaches the model
        await typeText("ayuda")
        check("typing fills the command field", model.input == "ayuda", "input=\(model.input.debugDescription)")

        // B. Return submits
        await press("\r", keyCode: returnKey)
        try? await Task.sleep(for: .milliseconds(400))
        check("Return runs the command", model.messages.count == 1, "messages=\(model.messages.count)")
        check("the field is cleared after Return", model.input.isEmpty, "input=\(model.input.debugDescription)")

        // B2. Return in an empty field does nothing
        await press("\r", keyCode: returnKey)
        check("Return in an empty field runs nothing", model.messages.count == 1, "messages=\(model.messages.count)")

        // C. Shift+Return adds a line and does not submit
        await typeText("uno")
        await press("\r", keyCode: returnKey, modifiers: .shift)
        await typeText("dos")
        check("Shift+Return does not run the command", model.messages.count == 1, "messages=\(model.messages.count)")
        check("Shift+Return inserts a line break at the caret", model.input == "uno\ndos", "input=\(model.input.debugDescription)")

        // D. Option+Return (the native macOS way) does the same
        await press("\r", keyCode: returnKey, modifiers: .option)
        await typeText("tres")
        check("Option+Return also inserts a line break", model.input == "uno\ndos\ntres" && model.messages.count == 1, "input=\(model.input.debugDescription) messages=\(model.messages.count)")

        // E. Return submits the multi-line text as one command
        await press("\r", keyCode: returnKey)
        try? await Task.sleep(for: .milliseconds(400))
        check("Return submits multi-line text as one command", model.messages.count == 2 && model.messages.last?.text == "uno\ndos\ntres",
              "messages=\(model.messages.count) last=\(model.messages.last?.text.debugDescription ?? "nil")")

        // F. Up arrow recalls the previous command
        try? await Task.sleep(for: .milliseconds(500))
        await press(String(UnicodeScalar(NSUpArrowFunctionKey)!), keyCode: upArrow)
        check("↑ in an empty field recalls the last command", model.input == "uno\ndos\ntres", "input=\(model.input.debugDescription) history=\(model.historyEntries.count)")

        window.orderOut(nil)
        try? await Task.sleep(for: .milliseconds(100))
        try? report.joined(separator: "\n").appending("\n").write(toFile: outputPath, atomically: true, encoding: .utf8)
        NSApplication.shared.terminate(nil)
    }
}
#endif
