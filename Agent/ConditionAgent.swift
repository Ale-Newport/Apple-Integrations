import AppKit
import Foundation
import JarvisCore
import JarvisIntegrations

/// A signed, UI-less application bundle gives UserNotifications a real application identity.
/// launchd starts it for a bounded pass, independently of the foreground Jarvis process.
@main
@MainActor
struct ConditionAgent {
    static func main() {
        let application = NSApplication.shared
        let authorize = CommandLine.arguments.contains("--authorize-notifications")
        application.setActivationPolicy(authorize ? .accessory : .prohibited)
        Task { @MainActor in
            let notifier = SystemConditionNotifications()
            let allowed = await notifier.allowed(request: authorize)
            let status: JSONValue = [
                "notifications_authorized": .bool(allowed),
                "checked_at": .string(ISODates.string(from: Date(), timeZone: .current)),
                "agent_bundle": .string(Bundle.main.bundleIdentifier ?? ""),
            ]
            if JarvisPaths.ensurePrivateDirectory(ConditionService.statusURL.deletingLastPathComponent()) {
                try? JSONEncoder().encode(status).write(to: ConditionService.statusURL, options: .atomic)
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: ConditionService.statusURL.path)
            }
            let defaults = UserDefaults(suiteName: ConditionService.parentBundleID) ?? .standard
            let settings = UserDefaultsSettingsStore(defaults: defaults).snapshot()
            if !authorize && settings.capabilities.backgroundConditionsEnabled {
                await ConditionJobStore().evaluate(isEnabled: {
                    let fresh = UserDefaults(suiteName: ConditionService.parentBundleID) ?? .standard
                    return UserDefaultsSettingsStore(defaults: fresh).snapshot().capabilities
                        .backgroundConditionsEnabled
                })
            }
            application.terminate(nil)
        }
        application.run()
    }
}
