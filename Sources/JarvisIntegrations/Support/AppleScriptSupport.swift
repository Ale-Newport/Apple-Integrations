import Foundation
import JarvisCore

/// Abstraction over the Automation permission so integrations can be tested without macOS prompts.
protocol AutomationAccess: Sendable {
    func status() -> AutomationPermission.Status
    func request() async -> AutomationPermission.Status
    var isRunning: Bool { get }
    var isInstalled: Bool { get }
}

struct SystemAutomationAccess: AutomationAccess {
    let permission: AutomationPermission

    init(bundleIdentifier: String) { permission = AutomationPermission(bundleIdentifier: bundleIdentifier) }

    func status() -> AutomationPermission.Status { permission.status() }
    func request() async -> AutomationPermission.Status { await permission.request() }
    var isRunning: Bool { AutomationPermission.isRunning(permission.bundleIdentifier) }
    var isInstalled: Bool { AutomationPermission.isInstalled(permission.bundleIdentifier) }
}

extension AppleScriptFailure {
    /// The text after the `TAG|` prefix of a script-defined error (`NOT_FOUND|playlist` → `playlist`).
    var detail: String {
        guard let bar = message.firstIndex(of: "|") else { return message }
        return String(message[message.index(after: bar)...])
    }

    var tag: String {
        guard let bar = message.firstIndex(of: "|") else { return message }
        return String(message[..<bar])
    }

    /// Maps a failed script to a localized, user-facing ``JarvisError`` common to every AppleScript-driven app.
    func jarvisError(app: String, requirement: PermissionRequirement) -> JarvisError {
        switch kind {
        case .notAuthorized, .consentRequired:
            return .permissionRequired(requirement)
        case .appUnavailable:
            return .unavailable(LocalizedText(
                en: "\(app) could not be opened. Make sure it is installed and not blocked.",
                es: "No se pudo abrir \(app). Comprueba que está instalada y no está bloqueada."
            ))
        case .timeout:
            return .failed(code: "app_timeout", LocalizedText(
                en: "\(app) did not answer in time. It may be showing a dialog (sign-in, update, sync) — check the app and try again.",
                es: "\(app) no respondió a tiempo. Puede estar mostrando un diálogo (inicio de sesión, actualización, sincronización); revisa la app e inténtalo de nuevo."
            ))
        case .cancelled:
            return .cancelled
        case .custom, .scriptError:
            return .failed(code: "script_error", LocalizedText(
                en: "\(app) reported an error: \(message)",
                es: "\(app) informó de un error: \(message)"
            ))
        }
    }
}

/// Small helpers for building result text.
enum Formatting {
    /// `3:05`, `1:02:03`
    static func clock(_ seconds: Int) -> String {
        let total = max(0, seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }

    static func bullets(_ lines: [String]) -> String {
        lines.map { "• " + $0 }.joined(separator: "\n")
    }

    static func quoted(_ text: String, _ language: Language) -> String {
        language == .es ? "«\(text)»" : "“\(text)”"
    }

    static func dateTime(_ date: Date, calendar: Calendar, language: Language, includeTime: Bool = true) -> String {
        let formatter = DateFormatter()
        formatter.locale = language.locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(includeTime ? "EEEMMMdjmm" : "EEEMMMd")
        return formatter.string(from: date)
    }

    static func time(_ date: Date, calendar: Calendar, language: Language) -> String {
        let formatter = DateFormatter()
        formatter.locale = language.locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return formatter.string(from: date)
    }

    static func day(_ date: Date, calendar: Calendar, language: Language) -> String {
        let formatter = DateFormatter()
        formatter.locale = language.locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEEEMMMMd")
        return formatter.string(from: date)
    }
}
