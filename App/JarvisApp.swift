import AppKit
import JarvisCore
import SwiftUI

@main
struct JarvisApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel
    @State private var shell: AppShell

    init() {
        let model = AppModel(environment: AppEnvironment())
        let shell = AppShell()
        _model = State(initialValue: model)
        _shell = State(initialValue: shell)
        AppDelegate.model = model
        shell.start { model.toggleMainWindow() }
    }

    var body: some Scene {
        Window("Jarvis", id: "main") {
            MainWindowView()
                .environment(model)
                .environment(shell)
                .preferredColorScheme(shell.appearance.colorScheme)
        }
        .defaultSize(width: 960, height: 680)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Jarvis") {
                Button(model.t("Focus Command Field", "Ir al campo de comandos")) {
                    model.selection = .chat
                    model.requestFocus()
                }
                .keyboardShortcut("l", modifiers: .command)
                Button(model.t("Stop All", "Detener todo")) { model.cancelAll() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!model.hasRunningCommands)
                Button(model.t("Clear Conversation", "Limpiar conversación")) { model.clearConversation() }
                    .keyboardShortcut("k", modifiers: .command)
                    .disabled(model.messages.isEmpty)
                Divider()
                Button(model.t("Show Chat", "Mostrar el chat")) { model.selection = .chat }
                    .keyboardShortcut("1", modifiers: .command)
                Button(model.t("Show History", "Mostrar el historial")) { model.selection = .history }
                    .keyboardShortcut("2", modifiers: .command)
            }
        }

        #if DEBUG
        Window("Menu bar preview", id: "menubar-preview") {
            MenuBarContent().environment(model).environment(shell)
        }
        .defaultSize(width: 440, height: 520)
        #endif

        MenuBarExtra(isInserted: Binding(get: { shell.showMenuBarIcon }, set: { shell.setShowMenuBarIcon($0) })) {
            MenuBarContent()
                .environment(model)
                .environment(shell)
                .preferredColorScheme(shell.appearance.colorScheme)
        } label: {
            Image(systemName: model.hasRunningCommands ? "sparkles" : "sparkle")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
                .environment(shell)
        }
    }
}
