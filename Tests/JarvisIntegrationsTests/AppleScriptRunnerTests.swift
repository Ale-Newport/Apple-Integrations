import XCTest
import JarvisCore
@testable import JarvisIntegrations

/// Records the argument vector instead of launching anything.
private final class RecordingProcessRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _invocations: [(executable: String, arguments: [String])] = []
    var output = ProcessOutput(status: 0, standardOutput: "ok\n", standardError: "")
    var error: (any Error)?

    var invocations: [(executable: String, arguments: [String])] { lock.withLock { _invocations } }

    func run(executable: String, arguments: [String], timeout: TimeInterval, maxOutputBytes: Int) async throws -> ProcessOutput {
        lock.withLock { _invocations.append((executable, arguments)) }
        if let error { throw error }
        return output
    }
}

final class AppleScriptRunnerTests: XCTestCase {
    private let script = AppleScriptSource(name: "test", text: "on run argv\nreturn item 1 of argv\nend run\n")

    func testScriptLinesComeFirstThenADoubleDashThenOnlyData() async throws {
        let process = RecordingProcessRunner()
        let runner = OSAScriptRunner(processRunner: process)
        _ = try await runner.run(script, arguments: ["-e", "do shell script \"x\"", "--help"], timeout: 5)

        let call = try XCTUnwrap(process.invocations.first)
        XCTAssertEqual(call.executable, "/usr/bin/osascript")
        XCTAssertEqual(call.arguments, ["-e", "on run argv", "-e", "return item 1 of argv", "-e", "end run", "--", "-e", "do shell script \"x\"", "--help"])
        // Everything after the separator is data: osascript will never parse it as an option.
        let separator = try XCTUnwrap(call.arguments.firstIndex(of: "--"))
        XCTAssertEqual(call.arguments[..<separator].filter { $0 == "-e" }.count, 3)
    }

    func testNulBytesAreRemovedFromData() async throws {
        let process = RecordingProcessRunner()
        _ = try await OSAScriptRunner(processRunner: process).run(script, arguments: ["a\u{0000}b"], timeout: 5)
        XCTAssertEqual(process.invocations.first?.arguments.last, "ab")
    }

    func testOutputLosesOnlyTheFinalNewline() async throws {
        let process = RecordingProcessRunner()
        process.output = ProcessOutput(status: 0, standardOutput: "line1\nline2\n\n", standardError: "")
        let text = try await OSAScriptRunner(processRunner: process).run(script, arguments: [], timeout: 5)
        XCTAssertEqual(text, "line1\nline2\n")
    }

    func testErrorsAreParsedIntoTypedFailures() async {
        let cases: [(String, AppleScriptFailure.Kind, Int?)] = [
            ("execution error: Not authorized to send Apple events to Music. (-1743)", .notAuthorized, -1743),
            ("execution error: Music got an error: AppleEvent timed out. (-1712)", .timeout, -1712),
            ("execution error: Application isn't running. (-600)", .appUnavailable, -600),
            ("execution error: NOT_FOUND|playlist (9001)", .custom, 9001),
            ("execution error: Can't get thing. (-1728)", .scriptError, -1728),
            ("syntax error: Expected end of line (-2741)", .scriptError, -2741),
        ]
        for (stderr, kind, code) in cases {
            let process = RecordingProcessRunner()
            process.output = ProcessOutput(status: 1, standardOutput: "", standardError: "script.scpt:1:2: " + stderr + "\n")
            do {
                _ = try await OSAScriptRunner(processRunner: process).run(script, arguments: [], timeout: 5)
                XCTFail("expected failure for \(stderr)")
            } catch let failure as AppleScriptFailure {
                XCTAssertEqual(failure.kind, kind, stderr)
                XCTAssertEqual(failure.code, code, stderr)
            } catch {
                XCTFail("wrong error \(error)")
            }
        }
    }

    func testCustomErrorMessagesExposeTagAndDetail() {
        let failure = AppleScriptFailure(kind: .custom, code: 9001, message: "NOT_FOUND|playlist")
        XCTAssertEqual(failure.tag, "NOT_FOUND")
        XCTAssertEqual(failure.detail, "playlist")
    }

    func testProcessTimeoutBecomesATimeoutFailure() async {
        let process = RecordingProcessRunner()
        process.error = ProcessRunnerError.timedOut
        do {
            _ = try await OSAScriptRunner(processRunner: process).run(script, arguments: [], timeout: 1)
            XCTFail("expected failure")
        } catch let failure as AppleScriptFailure {
            XCTAssertEqual(failure.kind, .timeout)
        } catch {
            XCTFail("wrong error \(error)")
        }
    }

    func testRecordParsing() {
        let text = "a\u{1F}b\u{1F}\u{1E}c\u{1F}d\u{1F}e"
        XCTAssertEqual(ScriptRecords.parse(text), [["a", "b", ""], ["c", "d", "e"]])
        XCTAssertEqual(ScriptRecords.parse(""), [])
    }

    // MARK: Real osascript, harmless script (talks to no app, needs no permission)

    func testRealOsascriptTreatsHostileArgumentsAsData() async throws {
        let echo = AppleScriptSource(name: "echo", text: "on run argv\nreturn (item 1 of argv) & \"|\" & (count of argv)\nend run")
        let hostile = "-e do shell script \"touch /tmp/jarvis-pwned\" ; `id` $(whoami) 'quote' \"dq\" \\ héllo 🎵\nsecond line"
        let result = try await OSAScriptRunner().run(echo, arguments: [hostile, "-l", "JavaScript"], timeout: 15)
        XCTAssertEqual(result, hostile + "|3")
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/jarvis-pwned"))
    }

    func testRealOsascriptReportsScriptErrorsWithCodes() async throws {
        let failing = AppleScriptSource(name: "fail", text: "on run argv\nerror \"NOT_FOUND|thing\" number 9001\nend run")
        do {
            _ = try await OSAScriptRunner().run(failing, arguments: [], timeout: 15)
            XCTFail("expected failure")
        } catch let failure as AppleScriptFailure {
            XCTAssertEqual(failure.kind, .custom)
            XCTAssertEqual(failure.code, 9001)
            XCTAssertEqual(failure.detail, "thing")
        }
    }

    func testRealProcessRunnerKillsSlowChildrenAtTheDeadline() async throws {
        let began = ContinuousClock.now
        do {
            _ = try await SystemProcessRunner().run(executable: "/bin/sleep", arguments: ["30"], timeout: 0.5, maxOutputBytes: 1000)
            XCTFail("expected a timeout")
        } catch ProcessRunnerError.timedOut {
            XCTAssertLessThan(began.duration(to: .now), .seconds(5))
        }
    }

    func testRealProcessRunnerStopsWhenTheTaskIsCancelled() async throws {
        let task = Task { try await SystemProcessRunner().run(executable: "/bin/sleep", arguments: ["30"], timeout: 60, maxOutputBytes: 1000) }
        try await Task.sleep(for: .milliseconds(300))
        let began = ContinuousClock.now
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            XCTAssertLessThan(began.duration(to: .now), .seconds(5))
        }
    }

    func testRealProcessRunnerCapsRunawayOutput() async throws {
        do {
            _ = try await SystemProcessRunner().run(executable: "/usr/bin/yes", arguments: [], timeout: 20, maxOutputBytes: 100_000)
            XCTFail("expected an overflow")
        } catch ProcessRunnerError.outputTooLarge {
            // expected
        }
    }

    func testRealProcessRunnerCapturesBothStreams() async throws {
        let output = try await SystemProcessRunner().run(executable: "/bin/sh", arguments: ["-c", "echo out; echo err >&2; exit 3"], timeout: 10, maxOutputBytes: 1000)
        XCTAssertEqual(output.status, 3)
        XCTAssertEqual(output.standardOutput, "out\n")
        XCTAssertEqual(output.standardError, "err\n")
    }
}
