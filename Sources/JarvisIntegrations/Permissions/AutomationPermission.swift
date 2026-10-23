import AppKit
import ApplicationServices
import CoreServices
import JarvisCore

/// macOS Automation ("Apple Events") consent for controlling another app, for example Music or Notes.
///
/// Status checks never show a prompt. ``request(bundleIdentifier:)`` shows the system dialog the first time.
/// macOS can only answer for an app that is running, so the request launches the target in the background
/// (without activating it) when necessary.
public struct AutomationPermission: Sendable {
    public enum Status: Sendable, Equatable {
        case granted
        case notDetermined
        case denied
        /// The target is not running, so macOS cannot report the state without launching it.
        case targetNotRunning
        case unavailable
    }

    public let bundleIdentifier: String

    public init(bundleIdentifier: String) {
        self.bundleIdentifier = bundleIdentifier
    }

    public static func isInstalled(_ bundleIdentifier: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }

    public static func isRunning(_ bundleIdentifier: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    /// Checks the current state without prompting.
    public func status() -> Status {
        guard Self.isInstalled(bundleIdentifier) else { return .unavailable }
        guard Self.isRunning(bundleIdentifier) else { return .targetNotRunning }
        return Self.determine(bundleIdentifier, askUser: false)
    }

    /// Asks macOS for permission, launching the target quietly if needed. Suspends until the user answers.
    public func request() async -> Status {
        guard Self.isInstalled(bundleIdentifier) else { return .unavailable }
        if !Self.isRunning(bundleIdentifier) {
            await Self.launchInBackground(bundleIdentifier)
        }
        let id = bundleIdentifier
        // The call blocks while the prompt is on screen, so keep it off the cooperative thread pool.
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.determine(id, askUser: true))
            }
        }
    }

    private static func determine(_ bundleIdentifier: String, askUser: Bool) -> Status {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier)
        let result = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, askUser)
        switch Int(result) {
        case Int(noErr): return .granted
        case -1743: return .denied                       // errAEEventNotPermitted
        case -1744: return .notDetermined                // errAEEventWouldRequireUserConsent
        case -600: return .targetNotRunning              // procNotFound
        default: return .denied
        }
    }

    @MainActor
    private static func openApplication(_ url: URL) async {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.hides = true
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    private static func launchInBackground(_ bundleIdentifier: String) async {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return }
        await openApplication(url)
        // Give the process a moment to register with the Apple Event system.
        for _ in 0..<20 where !isRunning(bundleIdentifier) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? await Task.sleep(for: .milliseconds(300))
    }

    /// The `x-apple.systempreferences:` URL for the Automation privacy pane.
    public static let settingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
}

extension PermissionRequirement {
    /// Standard requirement description for controlling `appName` through Apple Events.
    static func automation(appName: String, bundleIdentifier: String, reason: LocalizedText) -> PermissionRequirement {
        PermissionRequirement(
            id: "automation.\(bundleIdentifier)",
            title: LocalizedText(en: "Control “\(appName)”", es: "Controlar «\(appName)»"),
            rationale: reason,
            settingsURL: AutomationPermission.settingsURL
        )
    }
}
