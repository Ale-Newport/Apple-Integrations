import Foundation
import JarvisCore

/// Shared public Apple Events permission boundary. Scripts remain fixed and arguments are always data.
struct AutomationBridge: Sendable {
    let appName: String
    let requirement: PermissionRequirement
    let scripts: any AppleScriptExecuting
    let access: any AutomationAccess
    init(
        app: String, bundleID: String, scripts: any AppleScriptExecuting = OSAScriptRunner(),
        access: (any AutomationAccess)? = nil
    ) {
        appName = app
        self.scripts = scripts
        requirement = .automation(
            appName: app, bundleIdentifier: bundleID,
            reason: LocalizedText(
                en: "Jarvis controls \(app) only for requested actions.",
                es: "Jarvis controla \(app) para las acciones solicitadas."))
        self.access = access ?? SystemAutomationAccess(bundleIdentifier: bundleID)
    }
    func authorization() -> AuthorizationState {
        switch access.status() {
        case .granted: return .authorized
        case .notDetermined, .targetNotRunning: return .notDetermined(requirement)
        case .denied: return .denied(requirement)
        case .unavailable:
            return .unavailable(LocalizedText(en: "\(appName) is not installed.", es: "\(appName) no está instalada."))
        }
    }
    func request() async -> AuthorizationState {
        _ = await access.request()
        return authorization()
    }
    func status() -> IntegrationStatus {
        let state = authorization()
        let status: IntegrationStatus.State
        switch state {
        case .authorized: status = .ready
        case .denied: status = .denied
        case .unavailable: status = .unavailable
        default: status = .needsPermission
        }
        return IntegrationStatus(state: status, permissions: [.init(requirement: requirement, state: state)])
    }
    func run(_ script: AppleScriptSource, _ args: [String] = [], timeout: TimeInterval = 30) async throws -> String {
        do { return try await scripts.run(script, arguments: args, timeout: timeout) } catch let error
            as AppleScriptFailure
        { throw error.jarvisError(app: appName, requirement: requirement) }
    }
}

func integrationFailure(_ code: String, _ english: String, _ spanish: String) -> JarvisError {
    .failed(code, en: english, es: spanish)
}
