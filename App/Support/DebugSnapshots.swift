#if DEBUG
import AppKit
import JarvisCore
import SwiftUI

/// Developer-only: renders the app's own views into PNG files without showing any window or capturing the screen.
///
///     open -g -n "Jarvis Apple Integrations.app" --args -JarvisSnapshotDir /tmp/jarvis-ui
///
/// Compiled into Debug builds only. Used to review every screen in both appearances.
@MainActor
enum DebugSnapshots {
    struct Scene {
        let name: String
        let size: CGSize
        /// Prepares the model (selection, sample conversation …) before the view is created.
        let prepare: @MainActor (AppModel) -> Void
        let makeView: @MainActor (AppModel, AppShell) -> AnyView
    }

    static func run(model: AppModel, shell: AppShell, directory: String) async {
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let main = CGSize(width: 960, height: 680)
        let settings = CGSize(width: 680, height: 560)
        var scenes: [Scene] = [
            Scene(name: "chat", size: main, prepare: { $0.selection = .chat }, makeView: { m, s in AnyView(MainWindowView().environment(m).environment(s)) }),
            Scene(name: "history", size: main, prepare: { $0.selection = .history }, makeView: { m, s in AnyView(MainWindowView().environment(m).environment(s)) }),
        ]
        for id in ["music", "reminders", "notes", "calendar", "clock", "contacts"] {
            scenes.append(Scene(name: "integration-\(id)", size: main, prepare: { $0.selection = .integration(IntegrationID(id)) }, makeView: { m, s in AnyView(MainWindowView().environment(m).environment(s)) }))
        }
        scenes.append(Scene(name: "menubar", size: CGSize(width: 420, height: 520), prepare: { _ in }, makeView: { m, s in AnyView(MenuBarContent().environment(m).environment(s)) }))
        for tab in ["general", "permissions", "integrations", "privacy", "advanced"] {
            scenes.append(Scene(name: "settings-\(tab)", size: settings, prepare: { _ in UserDefaults.standard.set(tab, forKey: "pref.settingsTab") }, makeView: { m, s in AnyView(SettingsView().environment(m).environment(s)) }))
        }

        for (suffix, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", NSAppearance.Name.aqua)] {
            for scene in scenes {
                scene.prepare(model)
                try? await Task.sleep(for: .milliseconds(900))
                render(scene.makeView(model, shell), size: scene.size, appearance: appearance, to: folder.appendingPathComponent("\(scene.name)-\(suffix).png"))
            }
        }
    }

    private static func render(_ view: AnyView, size: CGSize, appearance: NSAppearance.Name, to url: URL) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: url)
        }
    }
}
#endif
