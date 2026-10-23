import AppKit
import Foundation
import JarvisCore
import JarvisIntegrations
import Observation
import SwiftUI

/// State shared by the main window, the menu bar item and the settings screens.
@MainActor
@Observable
final class AppModel {
    let environment: AppEnvironment

    // Conversation
    var messages: [ChatMessage] = []
    var input = ""
    var focusRequest = 0
    var selection: SidebarItem = .chat

    // Data shown around the app
    var settings: JarvisSettings
    var statuses: [IntegrationID: IntegrationStatus] = [:]
    var historyEntries: [HistoryEntry] = []
    var shortcutPresence: [ClockShortcut: Bool] = [:]
    var shortcutsToolAvailable = true
    var notice: String?

    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var recallIndex: Int?
    @ObservationIgnored private var activationObserver: (any NSObjectProtocol)?

    init(environment: AppEnvironment) {
        self.environment = environment
        self.settings = environment.settingsStore.snapshot()
        environment.ipc.apply(enabled: settings.ipcEnabled)
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshStatuses() }
        }
        refreshStatuses()
        refreshHistory()
    }

    // MARK: Language

    static var systemLanguage: Language {
        for identifier in Locale.preferredLanguages {
            if let language = Language(hint: identifier) { return language }
        }
        return .en
    }

    var language: Language { settings.languagePreference.fixedLanguage ?? Self.systemLanguage }

    /// Picks the interface text for the current language.
    func t(_ english: String, _ spanish: String) -> String { language == .es ? spanish : english }

    // MARK: Settings

    func update(_ change: (inout JarvisSettings) -> Void) {
        var copy = settings
        change(&copy)
        settings = copy.sanitized()
        environment.settingsStore.save(settings)
        environment.ipc.apply(enabled: settings.ipcEnabled)
    }

    func binding<Value>(_ keyPath: WritableKeyPath<JarvisSettings, Value>) -> Binding<Value> {
        Binding(get: { self.settings[keyPath: keyPath] }, set: { newValue in self.update { $0[keyPath: keyPath] = newValue } })
    }

    // MARK: Commands

    /// Runs a command typed by the user. Identical in-flight commands are ignored (double Enter).
    func submit(_ raw: String? = nil, allowDuplicate: Bool = false) {
        let text = (raw ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if messages.contains(where: { $0.isRunning && $0.text == text }) { return }
        if raw == nil { input = "" }
        recallIndex = nil
        selection = .chat

        let id = UUID()
        messages.append(ChatMessage(id: id, text: text, date: Date(), phase: .interpreting))
        let request = CommandRequest(text: text, language: nil, source: .app, session: "ui", allowDuplicate: allowDuplicate)
        let engine = environment.engine
        tasks[id] = Task { [weak self] in
            guard let owner = self else { return }
            let response = await engine.process(request) { event in
                Task { @MainActor in owner.apply(event, to: id) }
            }
            owner.finish(id, with: response)
        }
    }

    func cancel(_ id: UUID) { tasks[id]?.cancel() }

    func cancelAll() { tasks.values.forEach { $0.cancel() } }

    var hasRunningCommands: Bool { messages.contains(where: \.isRunning) }

    /// Answers a pending confirmation or clarification with a button.
    func resolve(in message: ChatMessage, token: String, decision: PendingDecision, label: String) {
        guard let index = messages.firstIndex(where: { $0.id == message.id }), !messages[index].resolvedTokens.contains(token) else { return }
        messages[index].resolvedTokens.insert(token)

        let id = UUID()
        messages.append(ChatMessage(id: id, text: label, date: Date(), phase: .interpreting))
        let engine = environment.engine
        let language = self.language
        tasks[id] = Task { [weak self] in
            guard let owner = self else { return }
            let response = await engine.resolve(token: token, decision: decision, language: language, source: .app) { event in
                Task { @MainActor in owner.apply(event, to: id) }
            }
            owner.finish(id, with: response)
        }
    }

    func retry(_ message: ChatMessage) { submit(message.text, allowDuplicate: true) }

    /// Runs one structured tool directly (the menu bar's playback buttons) and shows it in the conversation like
    /// any other command. `label` is what the user sees as the command and what the history records.
    func runTool(_ tool: ToolName, label: String) {
        let id = UUID()
        messages.append(ChatMessage(id: id, text: label, date: Date(), phase: .interpreting))
        let engine = environment.engine
        let language = self.language
        tasks[id] = Task { [weak self] in
            guard let owner = self else { return }
            let response = await engine.execute(ToolCall(tool: tool), language: language, source: .app, session: "ui", allowDuplicate: true) { event in
                Task { @MainActor in owner.apply(event, to: id) }
            }
            owner.finish(id, with: response)
        }
    }

    private func apply(_ event: EngineEvent, to id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }), messages[index].isRunning else { return }
        let registry = environment.registry
        switch event {
        case .planned(_, let steps):
            let infos = steps.map { step in
                StepInfo(id: step.id, tool: step.tool, title: registry.descriptor(for: step.tool)?.title ?? step.tool.rawValue, state: .pending)
            }
            if case .running(let previous) = messages[index].phase {
                messages[index].phase = .running(previous + infos)
            } else { messages[index].phase = .running(infos) }
        case .stepStarted(_, let callID):
            update(step: callID, in: index) { $0.state = .running }
        case .stepFinished(_, let result):
            update(step: result.callID, in: index) { $0.state = .finished(result.status) }
        }
    }

    private func update(step callID: UUID, in index: Int, _ change: (inout StepInfo) -> Void) {
        guard case .running(var steps) = messages[index].phase, let position = steps.firstIndex(where: { $0.id == callID }) else { return }
        change(&steps[position])
        messages[index].phase = .running(steps)
    }

    private func finish(_ id: UUID, with response: EngineResponse) {
        tasks[id] = nil
        if let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].phase = .finished(response)
        }
        refreshHistory()
        if response.status == .permissionRequired || response.status == .setupRequired || response.status == .completed {
            refreshStatuses()
        }
    }

    // MARK: Input helpers

    func requestFocus() { focusRequest += 1 }

    /// Up-arrow in an empty field brings back earlier commands, like a shell.
    func recallPrevious() {
        let commands = historyEntries.map(\.text)
        guard !commands.isEmpty else { return }
        let next = (recallIndex ?? -1) + 1
        guard next < commands.count else { return }
        recallIndex = next
        input = commands[next]
    }

    func recallNext() {
        guard let current = recallIndex else { return }
        if current == 0 {
            recallIndex = nil
            input = ""
        } else {
            recallIndex = current - 1
            input = historyEntries[current - 1].text
        }
    }

    func clearConversation() {
        cancelAll()
        messages.removeAll()
        Task { await environment.engine.clearSession("ui") }
    }

    // MARK: History

    func refreshHistory() {
        Task {
            let entries = await environment.history.all()
            historyEntries = entries
        }
    }

    func deleteHistory(_ ids: Set<UUID>) {
        Task {
            await environment.history.delete(ids: ids)
            refreshHistory()
        }
    }

    func clearHistory() {
        Task {
            await environment.history.clear()
            refreshHistory()
        }
    }

    func rerun(_ entry: HistoryEntry) { submit(entry.text, allowDuplicate: true) }

    func reuse(_ entry: HistoryEntry) {
        selection = .chat
        input = entry.text
        requestFocus()
    }

    // MARK: Integrations and permissions

    func integration(_ id: IntegrationID) -> (any AppIntegration)? { environment.registry.integration(withID: id) }

    func refreshStatuses() {
        let integrations = environment.integrations
        Task {
            var fresh: [IntegrationID: IntegrationStatus] = [:]
            for integration in integrations { fresh[integration.id] = await integration.status() }
            statuses = fresh
        }
        refreshShortcutPresence()
    }

    func refreshShortcutPresence() {
        Task {
            do {
                let installed = try await ShortcutsCLIRunner().installedShortcutNames()
                var presence: [ClockShortcut: Bool] = [:]
                let names = settings.shortcutNames
                for shortcut in ClockShortcut.allCases { presence[shortcut] = installed.contains(shortcut.name(in: names)) }
                shortcutPresence = presence
                shortcutsToolAvailable = true
            } catch {
                shortcutPresence = [:]
                shortcutsToolAvailable = false
            }
        }
    }

    /// Shows the system permission prompt for an integration (it may launch the target app quietly).
    func requestPermission(for integration: any AppIntegration) {
        Task {
            guard let tool = integration.tools.first else { return }
            let state = await integration.requestAuthorization(for: tool)
            switch state {
            case .authorized:
                notice = t("Access granted for \(integration.displayName.en).", "Acceso concedido para \(integration.displayName.es).")
            case .denied, .restricted:
                notice = t("macOS did not grant access. You can change it in System Settings.", "macOS no concedió el acceso. Puedes cambiarlo en Ajustes del Sistema.")
            default:
                notice = nil
            }
            refreshStatuses()
        }
    }

    func openSystemSettings(_ urlString: String?) {
        guard let urlString, let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    func openShortcutsApp() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.shortcuts") { NSWorkspace.shared.open(url) }
    }

    // MARK: Choices for Settings pickers

    enum ChoiceKind: Hashable {
        case reminderLists, calendars, noteFolders
    }

    struct Choice: Hashable, Identifiable {
        var name: String
        /// Account name (Notes accounts, Reminders sources, Calendar sources).
        var group: String
        var id: String { group + "\u{1F}" + name }
    }

    struct ChoiceSet: Equatable {
        var items: [Choice] = []
        var isLoading = false
        var isLoaded = false
        /// Why the list is empty (usually: permission not granted yet).
        var problem: String?
    }

    var choices: [ChoiceKind: ChoiceSet] = [:]

    /// Reads the names the user can pick from (lists, calendars, folders) through the same engine as every command,
    /// so permission checks apply. It is not added to the command history. The system permission prompt only
    /// appears when `allowPrompt` is true (the user pressed a button for it); otherwise a missing permission is
    /// reported in `ChoiceSet.problem`.
    func loadChoices(_ kind: ChoiceKind, force: Bool = false, allowPrompt: Bool = false) {
        let current = choices[kind] ?? ChoiceSet()
        if current.isLoading || (current.isLoaded && !force) { return }
        choices[kind, default: ChoiceSet()].isLoading = true

        let tool: ToolName
        let key: String
        switch kind {
        case .reminderLists:
            tool = .remindersListLists
            key = "lists"
        case .calendars:
            tool = .calendarListCalendars
            key = "calendars"
        case .noteFolders:
            tool = .notesListFolders
            key = "folders"
        }
        let engine = environment.engine
        let registry = environment.registry
        let language = self.language
        Task {
            var set = ChoiceSet(isLoaded: true)
            if let descriptor = registry.descriptor(for: tool), let integration = registry.integration(for: tool) {
                var state = await integration.authorization(for: descriptor)
                if allowPrompt, case .notDetermined = state {
                    state = await integration.requestAuthorization(for: descriptor)
                }
                if !state.isAuthorized {
                    switch state {
                    case .denied, .restricted:
                        set.problem = language.pick("Access is off. Change it in System Settings ▸ Privacy & Security.", "El acceso está desactivado. Cámbialo en Ajustes del Sistema ▸ Privacidad y seguridad.")
                    case .unavailable(let reason):
                        set.problem = reason.resolved(language)
                    default:
                        set.problem = language.pick("Allow access first (Permissions tab).", "Concede primero el acceso (pestaña Permisos).")
                    }
                    choices[kind] = set
                    refreshStatuses()
                    return
                }
            }
            let response = await engine.execute(ToolCall(tool: tool), language: language, source: .app, session: "settings", recordHistory: false)
            if let result = response.results.first, result.status == .completed {
                for entry in result.data?[key]?.arrayValue ?? [] {
                    guard let name = entry["name"]?.stringValue else { continue }
                    // Calendars the user cannot write to are not useful as a default.
                    if kind == .calendars, entry["writable"]?.boolValue == false { continue }
                    set.items.append(Choice(name: name, group: entry["account"]?.stringValue ?? ""))
                }
            } else {
                set.problem = response.results.first?.message ?? response.message
            }
            choices[kind] = set
        }
    }

    // MARK: Windows

    func showMainWindow() {
        NSApp.activate()
        OpenWindowBridge.shared.openMainWindow()
        requestFocus()
    }

    /// The global shortcut: shows Jarvis, or hides it again when it is already the frontmost window.
    func toggleMainWindow() {
        if NSApp.isActive, let window = NSApp.keyWindow, window.identifier?.rawValue.contains("main") == true, window.isVisible {
            NSApp.hide(nil)
        } else {
            selection = .chat
            showMainWindow()
        }
    }
}

/// SwiftUI scenes cannot be opened from outside a view, so a view registers the `openWindow` action here.
@MainActor
final class OpenWindowBridge {
    static let shared = OpenWindowBridge()
    var open: (() -> Void)?

    func openMainWindow() {
        if let open {
            // Re-creates the window if it was closed, or brings the existing one to the front.
            open()
        } else if let existing = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("main") == true && $0.canBecomeMain }) {
            // Very early at launch, before any view has registered the SwiftUI action.
            existing.makeKeyAndOrderFront(nil)
        }
    }
}
