import AppKit
import Foundation
import JarvisCore
import JarvisInterpreter
import JarvisIntegrations
import JarvisIPC
import ServiceManagement

/// The composition root: builds the Action Engine and everything it needs, once, for the whole app.
///
/// The UI, the menu bar item and the local IPC server all talk to the *same* engine instance, so a confirmation
/// requested from one front-end is visible to — and resolvable by — the same rules as every other.
@MainActor
final class AppEnvironment {
    let settingsStore: UserDefaultsSettingsStore
    let history: HistoryStore
    let integrations: [any AppIntegration]
    let registry: ToolRegistry
    let engine: ActionEngine
    let ipc: IPCController

    init(
        settingsStore: UserDefaultsSettingsStore = UserDefaultsSettingsStore(),
        history: HistoryStore = HistoryStore(),
        integrations: [any AppIntegration] = IntegrationCatalog.makeDefault(),
        interpreter: (any CommandInterpreting)? = nil,
        ipcSocketURL: URL = JarvisPaths.socketFile()
    ) {
        self.settingsStore = settingsStore
        self.history = history
        self.integrations = integrations
        let registry = ToolRegistry(integrations: integrations)
        self.registry = registry
        // Rules first; an AI interpreter can be plugged in here later (see docs/ARCHITECTURE.md).
        let engine = ActionEngine(
            registry: registry,
            interpreter: interpreter ?? HybridCommandInterpreter(),
            settings: settingsStore,
            history: history,
            fallbackLanguage: AppModel.systemLanguage
        )
        self.engine = engine
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        self.ipc = IPCController(engine: engine, integrations: integrations, appVersion: version, socketURL: ipcSocketURL)
    }

    /// JSON description of every integration's state, returned for IPC `status` requests.
    static func statusJSON(_ integrations: [any AppIntegration]) async -> JSONValue {
        var entries: [JSONValue] = []
        for integration in integrations {
            let status = await integration.status()
            var object: JSONObject = [
                "id": .string(integration.id.rawValue), "name": .string(integration.displayName.en), "state": .string(status.state.rawValue),
            ]
            if let detail = status.detail { object["detail"] = .string(detail.en) }
            object["permissions"] = .array(status.permissions.map { entry in
                let state: String
                switch entry.state {
                case .authorized: state = "authorized"
                case .notDetermined: state = "not_determined"
                case .denied: state = "denied"
                case .restricted: state = "restricted"
                case .unavailable: state = "unavailable"
                }
                return .object(["id": .string(entry.requirement.id), "state": .string(state)])
            })
            entries.append(.object(object))
        }
        return .object(["integrations": .array(entries)])
    }
}

/// Starts and stops the local control channel according to the user's setting.
@MainActor
@Observable
final class IPCController {
    private(set) var isRunning = false
    private(set) var lastError: String?
    let socketPath: String

    private let engine: ActionEngine
    private let integrations: [any AppIntegration]
    private let appVersion: String
    private var server: IPCServer?

    init(engine: ActionEngine, integrations: [any AppIntegration], appVersion: String, socketURL: URL = JarvisPaths.socketFile()) {
        self.engine = engine
        self.integrations = integrations
        self.appVersion = appVersion
        self.socketPath = socketURL.path
    }

    func apply(enabled: Bool) {
        if enabled { start() } else { stop() }
    }

    func start() {
        guard server == nil else { return }
        let integrations = self.integrations
        let handler = EngineIPCHandler(engine: engine, appVersion: appVersion) { await AppEnvironment.statusJSON(integrations) }
        let candidate = IPCServer(socketURL: URL(fileURLWithPath: socketPath), handler: handler)
        do {
            try candidate.start()
            server = candidate
            isRunning = true
            lastError = nil
        } catch IPCError.alreadyRunning {
            lastError = "Another copy of Jarvis is already listening on the control channel."
            isRunning = false
        } catch {
            lastError = "Could not open the control channel: \(error)"
            isRunning = false
        }
    }

    func stop() {
        server?.stop()
        server = nil
        isRunning = false
    }
}

/// Wraps `SMAppService` so the UI can offer “Open at login”.
@MainActor
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
