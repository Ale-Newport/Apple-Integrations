import Foundation
import JarvisCore

/// A fixed AppleScript program. Sources are compile-time constants: **user input never becomes script text**.
/// Variable data (names, queries, identifiers, note bodies) is passed as `argv` items and read inside the
/// script with `item N of argv`, so it can only ever be data.
public struct AppleScriptSource: Sendable, Hashable {
    public let name: String
    public let text: String

    public init(name: String, text: String) {
        self.name = name
        self.text = text
    }

    /// The non-empty source lines, each passed to `osascript` as its own `-e` option.
    var lines: [String] {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).replacingOccurrences(of: "\r", with: "") }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}

/// Why an AppleScript run failed.
public struct AppleScriptFailure: Error, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// The user has not allowed (or has denied) Jarvis to control the target app (-1743).
        case notAuthorized
        /// macOS would have to ask the user first (-1744).
        case consentRequired
        /// The app is not installed or could not be launched (-600, -10810, -10814, -1728 on `application`).
        case appUnavailable
        /// The app did not answer in time (-1712) or our own deadline passed.
        case timeout
        case cancelled
        /// A script-defined error (`error "…" number 9001…`).
        case custom
        case scriptError
    }

    public var kind: Kind
    public var code: Int?
    public var message: String

    public init(kind: Kind, code: Int?, message: String) {
        self.kind = kind
        self.code = code
        self.message = message
    }

    /// Script-defined error numbers used by the bundled scripts.
    public enum CustomCode {
        public static let notFound = 9001
        public static let ambiguous = 9002
        public static let invalidArgument = 9003
        public static let unsupported = 9004
        public static let verificationFailed = 9005
        public static let empty = 9006
    }
}

public protocol AppleScriptExecuting: Sendable {
    /// Runs `script` with `arguments` (data only) and returns its text result.
    func run(_ script: AppleScriptSource, arguments: [String], timeout: TimeInterval) async throws -> String
}

/// Runs AppleScript through `/usr/bin/osascript` in a child process.
///
/// Why a child process rather than `NSAppleScript` in-process: `NSAppleScript` must be used from the main
/// thread (a slow Notes query would freeze the UI), cannot be cancelled and has no timeout. A child process can
/// be killed on cancellation or deadline, runs fully off the main thread, and macOS still attributes the
/// Automation permission prompt to Jarvis (the responsible process).
///
/// Arguments are separated from the script by `--`, so an argument such as `-e` is data, never an option.
public struct OSAScriptRunner: AppleScriptExecuting {
    public static let executable = "/usr/bin/osascript"
    private let processRunner: any ProcessRunning

    public init(processRunner: any ProcessRunning = SystemProcessRunner()) {
        self.processRunner = processRunner
    }

    /// The exact argument vector used for `script`. Exposed for tests that assert the injection-safety guarantees.
    public static func arguments(for script: AppleScriptSource, data: [String]) -> [String] {
        var vector: [String] = []
        for line in script.lines {
            vector.append("-e")
            vector.append(line)
        }
        vector.append("--")
        vector.append(contentsOf: data.map { $0.replacingOccurrences(of: "\u{0000}", with: "") })
        return vector
    }

    public func run(_ script: AppleScriptSource, arguments: [String], timeout: TimeInterval) async throws -> String {
        let vector = Self.arguments(for: script, data: arguments)
        let output: ProcessOutput
        do {
            output = try await processRunner.run(executable: Self.executable, arguments: vector, timeout: timeout, maxOutputBytes: 8 * 1024 * 1024)
        } catch ProcessRunnerError.timedOut {
            throw AppleScriptFailure(kind: .timeout, code: -1712, message: "The script did not finish within \(Int(timeout)) seconds.")
        } catch ProcessRunnerError.outputTooLarge {
            throw AppleScriptFailure(kind: .scriptError, code: nil, message: "The script produced too much output.")
        } catch ProcessRunnerError.launchFailed(let reason) {
            throw AppleScriptFailure(kind: .appUnavailable, code: nil, message: "osascript could not be started: \(reason)")
        }
        guard output.status == 0 else { throw Self.failure(from: output.standardError) }
        var text = output.standardOutput
        if text.hasSuffix("\n") { text.removeLast() }
        return text
    }

    /// Converts osascript's stderr (`… execution error: <message> (-1743)`) into a typed failure.
    static func failure(from stderr: String) -> AppleScriptFailure {
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let lastLine = trimmed.split(separator: "\n").last.map(String.init) ?? trimmed

        var code: Int?
        var message = lastLine
        if let range = lastLine.range(of: #"\((-?\d+)\)\s*$"#, options: .regularExpression) {
            let token = lastLine[range].dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
            code = Int(token)
            message = String(lastLine[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        if let marker = message.range(of: "execution error: ") { message = String(message[marker.upperBound...]) }
        else if let marker = message.range(of: "syntax error: ") { message = String(message[marker.upperBound...]) }

        let kind: AppleScriptFailure.Kind
        switch code {
        case .some(-1743): kind = .notAuthorized
        case .some(-1744): kind = .consentRequired
        case .some(-600), .some(-10810), .some(-10814), .some(-10004): kind = .appUnavailable
        case .some(-1712): kind = .timeout
        case .some(-128): kind = .cancelled
        case .some(let value) where (9000...9099).contains(value): kind = .custom
        default: kind = .scriptError
        }
        return AppleScriptFailure(kind: kind, code: code, message: message)
    }
}

/// Field/record separators used by the bundled scripts' text results (ASCII "unit" and "record" separators).
/// They cannot occur in names or titles, so no escaping is needed.
public enum ScriptRecords {
    public static let fieldSeparator: Character = "\u{1F}"
    public static let recordSeparator: Character = "\u{1E}"

    /// Splits `text` into records of fields. Empty input yields no records.
    public static func parse(_ text: String) -> [[String]] {
        guard !text.isEmpty else { return [] }
        return text.split(separator: recordSeparator, omittingEmptySubsequences: true)
            .map { $0.split(separator: fieldSeparator, omittingEmptySubsequences: false).map(String.init) }
    }

    public static func fields(_ text: String) -> [String] {
        text.split(separator: fieldSeparator, omittingEmptySubsequences: false).map(String.init)
    }
}

/// AppleScript helper handlers shared by the bundled scripts.
enum ScriptPrelude {
    /// `joinFields({a, b, c})` → a<US>b<US>c ; `joinRecords(rows)` → row<RS>row ; `oneLine(t)` strips separators and line breaks.
    static let handlers = """
    on joinFields(fieldList)
    set AppleScript's text item delimiters to (character id 31)
    set joined to fieldList as text
    set AppleScript's text item delimiters to ""
    return joined
    end joinFields
    on joinRecords(recordList)
    set AppleScript's text item delimiters to (character id 30)
    set joined to recordList as text
    set AppleScript's text item delimiters to ""
    return joined
    end joinRecords
    on oneLine(v)
    if v is missing value then return ""
    set t to v as text
    repeat with c in {10, 13, 30, 31}
    set AppleScript's text item delimiters to (character id (contents of c))
    set parts to text items of t
    set AppleScript's text item delimiters to " "
    set t to parts as text
    end repeat
    set AppleScript's text item delimiters to ""
    return t
    end oneLine
    on indexOf(needle, haystack)
    repeat with i from 1 to count of haystack
    if (item i of haystack) is needle then return i
    end repeat
    return 0
    end indexOf
    """
}
