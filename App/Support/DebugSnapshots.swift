#if DEBUG
    import AppKit
    import JarvisCore
    import JarvisIntegrations
    import SwiftUI

    /// Developer-only: renders the app's own views into PNG files without showing any window or capturing the screen.
    ///
    ///     open -g -n "Jarvis Apple Integrations.app" --args -JarvisSnapshotDir /tmp/jarvis-ui
    ///
    /// Compiled into Debug builds only. Used to review every screen in both appearances.
    @MainActor
    enum DebugSnapshots {
        private static var fixtureDirectory: URL?
        private static var fixtureSuite: String?
        static func makeModelsIfRequested() -> (AppModel, AppShell)? {
            guard
                UserDefaults.standard.string(forKey: "JarvisSnapshotDir") != nil
                    || UserDefaults.standard.string(forKey: "JarvisSelfTestOutput") != nil
            else { return nil }
            let suite = "jarvis.preview." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            fixtureSuite = suite
            defaults.set(false, forKey: PreferenceKey.showMenuBarIcon)
            defaults.set(false, forKey: PreferenceKey.hotkeyEnabled)
            let store = UserDefaultsSettingsStore(defaults: defaults)
            var settings = JarvisSettings()
            settings.ipcEnabled = false
            settings.saveHistory = false
            store.save(settings)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
            fixtureDirectory = folder
            let fixtures = IntegrationCatalog.makeDefault().map { SnapshotIntegration($0) }
            let environment = AppEnvironment(
                settingsStore: store, history: HistoryStore(fileURL: folder.appendingPathComponent("history.json")),
                integrations: fixtures, ipcSocketURL: folder.appendingPathComponent("jarvis.sock"))
            return (AppModel(environment: environment, systemDiscoveryEnabled: false), AppShell(defaults: defaults))
        }
        static func prepareSampleConversation(_ model: AppModel) {
            let text = "Busca mis recordatorios de mañana y crea una nota resumen."
            let result = EngineResponse(
                input: text, language: .es, status: .completed,
                message: "Creé «Resumen de mañana» con tus dos tareas pendientes.",
                results: [
                    ToolResult(
                        callID: UUID(), tool: .remindersList, status: .completed,
                        message: "2 recordatorios consultados."),
                    ToolResult(
                        callID: UUID(), tool: .notesCreate, status: .completed, message: "Nota de ejemplo guardada.",
                        verification: .verified("Datos de ejemplo para revisar la interfaz.")),
                ], interpreter: "preview")
            model.messages = [ChatMessage(id: result.id, text: text, date: Date(), phase: .finished(result))]
            let pending = ChatMessage(
                id: UUID(), text: "¿Qué tengo esta semana?", date: Date(),
                phase: .running([
                    StepInfo(id: UUID(), tool: .calendarListEvents, title: "Consultar el calendario", state: .running)
                ]), partialReply: "Estoy revisando tu agenda…")
            model.messages.append(pending)
            model.settings.languagePreference = .spanish
            model.historyEntries = [
                HistoryEntry(
                    id: result.id, date: Date(), text: text, language: .es, status: .completed, summary: result.message,
                    tools: result.results.map { $0.tool.rawValue }, source: "preview")
            ]
        }
        struct Scene {
            let name: String
            let size: CGSize
            /// Prepares the model (selection, sample conversation …) before the view is created.
            let prepare: @MainActor (AppModel) -> Void
            let makeView: @MainActor (AppModel, AppShell) -> AnyView
        }

        static func run(model: AppModel, shell: AppShell, directory: String) async {
            defer {
                if let fixtureSuite { UserDefaults.standard.removePersistentDomain(forName: fixtureSuite) }
                if let fixtureDirectory { try? FileManager.default.removeItem(at: fixtureDirectory) }
            }
            let folder = URL(fileURLWithPath: directory, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

            let main = CGSize(width: 960, height: 680)
            let settings = CGSize(width: 680, height: 560)
            var scenes: [Scene] = [
                Scene(
                    name: "chat", size: main, prepare: { $0.selection = .chat },
                    makeView: { m, s in AnyView(MainWindowView().environment(m).environment(s)) }),
                Scene(
                    name: "history", size: main, prepare: { $0.selection = .history },
                    makeView: { m, s in AnyView(MainWindowView().environment(m).environment(s)) }),
            ]
            for id in [
                "music", "reminders", "notes", "calendar", "clock", "contacts", "weather", "files", "mail",
                "conditions",
            ] {
                scenes.append(
                    Scene(
                        name: "integration-\(id)", size: main,
                        prepare: { $0.selection = .integration(IntegrationID(id)) },
                        makeView: { m, s in AnyView(MainWindowView().environment(m).environment(s)) }))
            }
            scenes.append(
                Scene(
                    name: "menubar", size: CGSize(width: 420, height: 520), prepare: { _ in },
                    makeView: { m, s in AnyView(MenuBarContent().environment(m).environment(s)) }))
            let settingViews: [(String, AnyView)] = [
                ("general", AnyView(GeneralSettingsView())), ("intelligence", AnyView(IntelligenceSettingsView())),
                ("permissions", AnyView(PermissionsSettingsView())),
                ("integrations", AnyView(IntegrationSettingsView())), ("privacy", AnyView(PrivacySettingsView())),
                ("advanced", AnyView(AdvancedSettingsView())),
            ]
            for (tab, view) in settingViews {
                scenes.append(
                    Scene(
                        name: "settings-\(tab)", size: settings, prepare: { _ in },
                        makeView: { m, s in AnyView(view.environment(m).environment(s)) }))
            }

            for (suffix, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", NSAppearance.Name.aqua)] {
                for scene in scenes {
                    scene.prepare(model)
                    try? await Task.sleep(for: .milliseconds(900))
                    render(
                        scene.makeView(model, shell), size: scene.size, appearance: appearance,
                        to: folder.appendingPathComponent("\(scene.name)-\(suffix).png"))
                }
            }
        }

        private static func render(_ view: AnyView, size: CGSize, appearance: NSAppearance.Name, to url: URL) {
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(
                contentRect: host.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
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

    /// A rendering fixture can advertise schemas but cannot execute any real integration.
    private struct SnapshotIntegration: AppIntegration {
        let id: IntegrationID
        let displayName: LocalizedText
        let summary: LocalizedText
        let symbolName: String
        let tools: [ToolDescriptor]
        let permissionRequirements: [PermissionRequirement] = []
        init(_ integration: any AppIntegration) {
            id = integration.id
            displayName = integration.displayName
            summary = integration.summary
            symbolName = integration.symbolName
            tools = integration.tools
        }
        func status() async -> IntegrationStatus { IntegrationStatus(state: .ready) }
        func authorization(for tool: ToolDescriptor) async -> AuthorizationState { .authorized }
        func requestAuthorization(for tool: ToolDescriptor) async -> AuthorizationState { .authorized }
        func execute(_ call: ValidatedToolCall, context: ExecutionContext) async throws -> ToolOutcome {
            throw JarvisError.failed(
                "preview_only", en: "Rendering fixture cannot execute tools.",
                es: "La vista de ejemplo no ejecuta herramientas.")
        }
    }
#endif
