import Foundation
import os

/// Central loggers. Tool names, statuses, durations and error codes are logged as public. Anything the
/// user typed or any data read from their apps (titles, note text, contact names…) must only ever be
/// logged with `privacy: .private`, so it is redacted in release builds and never leaves the machine.
public enum JarvisLog {
    public static let subsystem = "com.newportdiaz.JarvisAppleIntegrations"

    public static let engine = Logger(subsystem: subsystem, category: "engine")
    public static let interpreter = Logger(subsystem: subsystem, category: "interpreter")
    public static let permissions = Logger(subsystem: subsystem, category: "permissions")
    public static let ipc = Logger(subsystem: subsystem, category: "ipc")
    public static let persistence = Logger(subsystem: subsystem, category: "persistence")
    public static let app = Logger(subsystem: subsystem, category: "app")

    public static func integration(_ id: IntegrationID) -> Logger {
        Logger(subsystem: subsystem, category: "integration.\(id.rawValue)")
    }
}
