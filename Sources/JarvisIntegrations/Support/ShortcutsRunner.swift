import Foundation
import JarvisCore

public struct ShortcutRunOutput: Sendable, Equatable {
    public var text: String
    public init(text: String) { self.text = text }
}

public enum ShortcutsError: Error, Sendable, Equatable {
    /// The `shortcuts` command-line tool is missing (very old macOS).
    case toolUnavailable
    case notInstalled(String)
    case failed(status: Int32, message: String)
    case timedOut
}

/// Runs the user's Shortcuts by name. This is the *only* route Jarvis uses to reach Clock alarms and timers:
/// Apple exposes them as Shortcuts actions (App Intents), not through AppleScript or EventKit.
public protocol ShortcutsRunning: Sendable {
    /// Names of the shortcuts the user has (used to detect which Jarvis shortcuts are installed).
    func installedShortcutNames() async throws -> Set<String>
    /// Runs `name` with `input` (text, usually JSON) and returns the text it outputs.
    func run(name: String, input: String?, timeout: TimeInterval) async throws -> ShortcutRunOutput
}

/// Implementation on top of `/usr/bin/shortcuts` (`shortcuts list`, `shortcuts run`).
public struct ShortcutsCLIRunner: ShortcutsRunning {
    public static let executable = "/usr/bin/shortcuts"
    private let processRunner: any ProcessRunning
    private var fileManager: FileManager { .default }

    public init(processRunner: any ProcessRunning = SystemProcessRunner()) {
        self.processRunner = processRunner
    }

    public func installedShortcutNames() async throws -> Set<String> {
        guard fileManager.isExecutableFile(atPath: Self.executable) else { throw ShortcutsError.toolUnavailable }
        let output: ProcessOutput
        do {
            output = try await processRunner.run(executable: Self.executable, arguments: ["list"], timeout: 20, maxOutputBytes: 1_000_000)
        } catch ProcessRunnerError.timedOut {
            throw ShortcutsError.timedOut
        }
        guard output.status == 0 else { throw ShortcutsError.failed(status: output.status, message: output.standardError) }
        return Set(output.standardOutput.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    public func run(name: String, input: String?, timeout: TimeInterval) async throws -> ShortcutRunOutput {
        guard fileManager.isExecutableFile(atPath: Self.executable) else { throw ShortcutsError.toolUnavailable }

        // Input and output travel through files in a private, single-use directory (never through argv or a shell).
        let directory = fileManager.temporaryDirectory.appendingPathComponent("jarvis-shortcut-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fileManager.removeItem(at: directory) }

        var arguments = ["run"]
        if let input {
            let inputURL = directory.appendingPathComponent("input.txt")
            try Data(input.utf8).write(to: inputURL, options: .atomic)
            arguments += ["--input-path", inputURL.path]
        }
        let outputURL = directory.appendingPathComponent("output.txt")
        arguments += ["--output-path", outputURL.path, "--output-type", "public.utf8-plain-text", "--", name]

        let output: ProcessOutput
        do {
            output = try await processRunner.run(executable: Self.executable, arguments: arguments, timeout: timeout, maxOutputBytes: 4_000_000)
        } catch ProcessRunnerError.timedOut {
            throw ShortcutsError.timedOut
        }
        guard output.status == 0 else {
            let message = output.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ShortcutsError.failed(status: output.status, message: message.isEmpty ? output.standardOutput : message)
        }
        let produced = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? output.standardOutput
        return ShortcutRunOutput(text: produced.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
