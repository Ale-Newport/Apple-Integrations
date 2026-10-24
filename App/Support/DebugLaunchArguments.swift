#if DEBUG
    import AppKit
    import Foundation
    import JarvisCore

    /// Developer-only launch arguments for inspecting every screen and state without clicking through the UI, e.g.
    ///
    ///     open -n "Jarvis Apple Integrations.app" --args -JarvisScreen history
    ///     open -n "Jarvis Apple Integrations.app" --args -JarvisSubmit "help||pon una alarma a las 7:30"
    ///     open -n "Jarvis Apple Integrations.app" --args -JarvisOpenSettings YES -pref.settingsTab permissions
    ///
    /// Compiled into Debug builds only. `-pref.appearance light|dark` also works because `UserDefaults` reads launch arguments.
    extension AppModel {
        private static var appliedDebugArguments = false

        func applyDebugLaunchArguments(shell: AppShell, openSettings: () -> Void, openWindow: (String) -> Void) {
            guard !Self.appliedDebugArguments else { return }
            Self.appliedDebugArguments = true
            let defaults = UserDefaults.standard

            if let output = defaults.string(forKey: "JarvisSelfTestOutput") {
                Task { @MainActor in await DebugSelfTest.run(outputPath: output) }
                return
            }
            if let directory = defaults.string(forKey: "JarvisSnapshotDir") {
                Task { @MainActor in
                    DebugSnapshots.prepareSampleConversation(self)
                    await DebugSnapshots.run(model: self, shell: shell, directory: directory)
                    NSApplication.shared.terminate(nil)
                }
                return
            }
            if let screen = defaults.string(forKey: "JarvisScreen") {
                switch screen {
                case "chat": selection = .chat
                case "history": selection = .history
                default: selection = .integration(IntegrationID(screen))
                }
            }
            if defaults.bool(forKey: "JarvisOpenSettings") { openSettings() }
            if defaults.bool(forKey: "JarvisMenuBarPreview") { openWindow("menubar-preview") }
            if let commands = defaults.string(forKey: "JarvisSubmit") {
                for text in commands.components(separatedBy: "||") { submit(text) }
            }
        }
    }
#endif
