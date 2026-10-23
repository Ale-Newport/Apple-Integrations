import Darwin
import XCTest
import JarvisCore
import JarvisInterpreter
@testable import JarvisIPC

// MARK: - Test doubles

/// A fake "Reminders" integration whose behaviour the tests can script.
private final class FakeRemindersIntegration: AppIntegration, @unchecked Sendable {
    let id = IntegrationID.reminders
    let displayName = LocalizedText("Reminders")
    let summary = LocalizedText("fake")
    let symbolName = "checklist"
    let permissionRequirements: [PermissionRequirement] = []

    private let lock = NSLock()
    private var _created: [(title: String, list: String?)] = []
    private var _cancelled = false
    var delay: Duration = .zero

    var created: [(title: String, list: String?)] { lock.withLock { _created } }
    var wasCancelled: Bool { lock.withLock { _cancelled } }

    var tools: [ToolDescriptor] {
        [
            ToolDescriptor(name: .remindersCreate, integration: id, title: "Create", summary: "Create a reminder", parameters: [
                .string("title", "Title", required: true), .string("list", "List"), .dateOrDateTime("due", "Due"),
            ], safety: .modifying, timeout: 20),
            ToolDescriptor(name: .remindersDelete, integration: id, title: "Delete", summary: "Delete", parameters: [.string("id", "Id", required: true)], safety: .destructive, timeout: 20),
        ]
    }

    func status() async -> IntegrationStatus { IntegrationStatus(state: .ready) }
    func authorization(for tool: ToolDescriptor) async -> AuthorizationState { .authorized }
    func requestAuthorization(for tool: ToolDescriptor) async -> AuthorizationState { .authorized }

    func execute(_ call: ValidatedToolCall, context: ExecutionContext) async throws -> ToolOutcome {
        do {
            if delay > .zero { try await Task.sleep(for: delay) }
        } catch {
            lock.withLock { _cancelled = true }
            throw error
        }
        if call.descriptor.name == .remindersDelete {
            if !context.isConfirmed {
                return .confirm(ConfirmationRequest(prompt: "Delete it?", call: call.call, destructive: true))
            }
            return .done(ToolOutput(message: "Deleted", data: ["deleted": true], verification: .verified("gone")))
        }
        let title = call.string("title") ?? ""
        let list = call.string("list")
        lock.withLock { _created.append((title, list)) }
        var data: JSONObject = ["title": .string(title), "id": "R-1"]
        if let list { data["list"] = .string(list) }
        return .done(ToolOutput(message: "Reminder created successfully", data: .object(data), verification: .verified("read back")))
    }
}

private func shortSocketURL() -> URL {
    // Unix socket paths are limited to ~100 bytes, so avoid the long per-user temp directory.
    URL(fileURLWithPath: "/tmp/jarvis-ipc-\(UUID().uuidString.prefix(8))/jarvis.sock")
}

private func makeServer(_ integration: FakeRemindersIntegration = FakeRemindersIntegration(), url: URL = shortSocketURL(), limits: IPCServer.Limits = IPCServer.Limits()) -> (server: IPCServer, integration: FakeRemindersIntegration, engine: ActionEngine) {
    let engine = ActionEngine(
        registry: ToolRegistry(integrations: [integration]), interpreter: DeterministicInterpreter(),
        settings: InMemorySettings(), history: nil
    )
    let handler = EngineIPCHandler(engine: engine, appVersion: "test") { ["reminders": "ready"] }
    return (IPCServer(socketURL: url, handler: handler, limits: limits), integration, engine)
}

/// A tiny blocking client for tests that need to send raw bytes.
private final class RawClient {
    let descriptor: Int32
    init(path: String) throws { descriptor = try UnixSocket.connect(to: path) }
    deinit { close(descriptor) }

    func send(_ text: String) { UnixSocket.writeAll(Data(text.utf8), to: descriptor) }

    func readLine(timeout: TimeInterval = 5) -> String? {
        var buffer = Data()
        var byte: UInt8 = 0
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            var p = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            if poll(&p, 1, 200) <= 0 { continue }
            let n = read(descriptor, &byte, 1)
            if n <= 0 { return buffer.isEmpty ? nil : String(decoding: buffer, as: UTF8.self) }
            if byte == 0x0A { return String(decoding: buffer, as: UTF8.self) }
            buffer.append(byte)
        }
        return nil
    }

    func isClosedByPeer(timeout: TimeInterval = 3) -> Bool {
        var byte: UInt8 = 0
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            var p = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            if poll(&p, 1, 100) > 0 { return read(descriptor, &byte, 1) <= 0 }
        }
        return false
    }
}

// MARK: - Tests

final class IPCTests: XCTestCase {
    private var cleanup: [() -> Void] = []

    override func tearDown() {
        cleanup.forEach { $0() }
        cleanup = []
    }

    private func started(_ integration: FakeRemindersIntegration = FakeRemindersIntegration(), limits: IPCServer.Limits = IPCServer.Limits()) throws -> (url: URL, integration: FakeRemindersIntegration, server: IPCServer) {
        let url = shortSocketURL()
        let made = makeServer(integration, url: url, limits: limits)
        try made.server.start()
        cleanup.append {
            made.server.stop()
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        return (url, made.integration, made.server)
    }

    // MARK: The documented contract

    func testTheExampleFromTheBriefProducesTheExampleResponse() async throws {
        let ready = try started()
        let client = IPCClient(socketPath: ready.url.path, timeout: 10)
        let response = try await client.send(IPCRequest(command: "Add buy milk to my Shopping reminders list", language: "en"))

        XCTAssertTrue(response.success)
        XCTAssertEqual(response.status, "completed")
        XCTAssertEqual(response.tool, "reminders.create")
        XCTAssertEqual(response.message, "Reminder created successfully")
        XCTAssertEqual(response.data?["title"], "Buy milk")
        XCTAssertEqual(response.data?["list"], "Shopping")
        XCTAssertEqual(response.data?["id"], "R-1", "identifiers come from the integration, never invented")
        XCTAssertEqual(response.results.count, 1)
        XCTAssertTrue(response.results[0].verification.isVerified)
        XCTAssertEqual(response.interpreter, "deterministic")
        XCTAssertEqual(ready.integration.created.map(\.title), ["Buy milk"])
    }

    func testTheRawJSONLineFormatMatchesTheDocumentation() throws {
        let ready = try started()
        let client = try RawClient(path: ready.url.path)
        client.send(#"{"command": "Add buy milk to my Shopping reminders list", "language": "en"}"# + "\n")
        let line = try XCTUnwrap(client.readLine())
        let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        XCTAssertEqual(object?["success"] as? Bool, true)
        XCTAssertEqual(object?["tool"] as? String, "reminders.create")
        XCTAssertEqual((object?["data"] as? [String: Any])?["title"] as? String, "Buy milk")
        XCTAssertNotNil(object?["results"] as? [[String: Any]])
    }

    func testMultiStepCommandsReturnOneResultPerStep() async throws {
        let ready = try started()
        let client = IPCClient(socketPath: ready.url.path, timeout: 10)
        let response = try await client.send(IPCRequest(command: "Remind me to call Mom and remind me to buy milk"))
        XCTAssertEqual(response.results.count, 2)
        XCTAssertNil(response.tool, "no single tool for a multi-step command")
        XCTAssertNil(response.data)
        XCTAssertEqual(ready.integration.created.count, 2)
    }

    func testStructuredToolRequestsSkipInterpretation() async throws {
        let ready = try started()
        let client = IPCClient(socketPath: ready.url.path, timeout: 10)
        let response = try await client.send(IPCRequest(type: .tool, tool: "reminders.create", arguments: ["title": "Direct", "list": "Work"]))
        XCTAssertTrue(response.success)
        XCTAssertEqual(response.interpreter, "direct")
        XCTAssertEqual(ready.integration.created.first?.list, "Work")

        let invalid = try await client.send(IPCRequest(type: .tool, tool: "reminders.create", arguments: ["nope": 1]))
        XCTAssertFalse(invalid.success)
        XCTAssertEqual(invalid.status, "failed")
    }

    func testUnknownToolsAreRejected() async throws {
        let ready = try started()
        let response = try await IPCClient(socketPath: ready.url.path, timeout: 10).send(IPCRequest(type: .tool, tool: "shell.run", arguments: ["command": "rm -rf /"]))
        XCTAssertFalse(response.success)
        XCTAssertEqual(response.results.first?.errorCode, "unknown_tool")
    }

    func testDestructiveToolsNeedTheTwoStepConfirmation() async throws {
        let ready = try started()
        let client = IPCClient(socketPath: ready.url.path, timeout: 10)
        let first = try await client.send(IPCRequest(type: .tool, tool: "reminders.delete", arguments: ["id": "R-9"]))
        XCTAssertEqual(first.status, "needs_confirmation")
        let token = try XCTUnwrap(first.results.first?.confirmation?.token)

        let cancelled = try await client.send(IPCRequest(type: .resolve, token: token, decision: "cancel"))
        XCTAssertEqual(cancelled.status, "cancelled")

        let second = try await client.send(IPCRequest(type: .tool, tool: "reminders.delete", arguments: ["id": "R-9"]))
        let token2 = try XCTUnwrap(second.results.first?.confirmation?.token)
        let done = try await client.send(IPCRequest(type: .resolve, token: token2, decision: "confirm"))
        XCTAssertTrue(done.success)
        XCTAssertEqual(done.data?["deleted"], true)
    }

    func testPingToolsAndStatus() async throws {
        let ready = try started()
        let client = IPCClient(socketPath: ready.url.path, timeout: 10)
        let ping = try await client.send(IPCRequest(type: .ping))
        XCTAssertEqual(ping.message, "pong")
        XCTAssertEqual(ping.data?["protocol"], 1)
        let tools = try await client.send(IPCRequest(type: .tools))
        XCTAssertEqual(tools.data?.arrayValue?.compactMap { $0["name"]?.stringValue }, ["reminders.create", "reminders.delete"])
        let status = try await client.send(IPCRequest(type: .status))
        XCTAssertEqual(status.data?["reminders"], "ready")
    }

    func testInvalidRequestsGetAnErrorButTheConnectionSurvives() throws {
        let ready = try started()
        let client = try RawClient(path: ready.url.path)
        client.send("this is not json\n")
        let bad = try XCTUnwrap(client.readLine())
        XCTAssertTrue(bad.contains("\"invalid_request\""))
        XCTAssertTrue(bad.contains("one JSON object per line"), "protocol errors use fixed wording, not the system locale")
        client.send(#"{"type":"command"}"# + "\n")
        XCTAssertTrue(try XCTUnwrap(client.readLine()).contains("non-empty"))
        client.send(#"{"type":"ping","id":"abc"}"# + "\n")
        let ping = try XCTUnwrap(client.readLine())
        XCTAssertTrue(ping.contains("pong"))
        XCTAssertTrue(ping.contains("\"id\":\"abc\""), "the request id is echoed back")
    }

    func testSeveralRequestsOnOneConnectionAnswerInOrder() throws {
        let ready = try started()
        let client = try RawClient(path: ready.url.path)
        client.send(#"{"type":"ping","id":"1"}"# + "\n" + #"{"type":"ping","id":"2"}"# + "\n" + #"{"type":"ping","id":"3"}"# + "\n")
        let ids = (0..<3).compactMap { _ in client.readLine() }.map { line -> String in
            let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            return object?["id"] as? String ?? "?"
        }
        XCTAssertEqual(ids, ["1", "2", "3"])
    }

    func testOversizedRequestsAreRefusedAndTheConnectionClosed() throws {
        let ready = try started()
        let client = try RawClient(path: ready.url.path)
        client.send(String(repeating: "x", count: IPCCodec.maxLineBytes + 10_000))
        let line = client.readLine()
        XCTAssertTrue(line?.contains("request_too_large") == true)
        XCTAssertTrue(client.isClosedByPeer())
    }

    // MARK: Security

    func testTheSocketIsPrivateToTheCurrentUser() throws {
        let ready = try started()
        var fileInfo = stat()
        XCTAssertEqual(lstat(ready.url.path, &fileInfo), 0)
        XCTAssertEqual(fileInfo.st_mode & 0o777, 0o600)
        XCTAssertEqual(fileInfo.st_mode & S_IFMT, S_IFSOCK)
        var directoryInfo = stat()
        XCTAssertEqual(stat(ready.url.deletingLastPathComponent().path, &directoryInfo), 0)
        XCTAssertEqual(directoryInfo.st_mode & 0o777, 0o700)
        XCTAssertEqual(fileInfo.st_uid, getuid())
    }

    func testStoppingRemovesTheSocketFile() throws {
        let ready = try started()
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.url.path))
        ready.server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: ready.url.path))
        XCTAssertThrowsError(try UnixSocket.connect(to: ready.url.path))
    }

    func testAStaleSocketFromACrashIsReplaced() throws {
        let url = shortSocketURL()
        cleanup.append { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Leave a socket file behind with nobody listening.
        var address = try UnixSocket.address(for: url.path)
        let descriptor = try UnixSocket.makeSocket()
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        close(descriptor)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let made = makeServer(url: url)
        XCTAssertNoThrow(try made.server.start())
        cleanup.append { made.server.stop() }
        XCTAssertNoThrow(try UnixSocket.connect(to: url.path))
    }

    func testASecondServerOnTheSameSocketIsRefused() throws {
        let ready = try started()
        let second = makeServer(url: ready.url)
        XCTAssertThrowsError(try second.server.start()) { XCTAssertEqual($0 as? IPCError, .alreadyRunning) }
        // The first one is unharmed.
        XCTAssertNoThrow(try UnixSocket.connect(to: ready.url.path))
    }

    func testARegularFileIsNeverDeletedAsIfItWereASocket() throws {
        let url = shortSocketURL()
        cleanup.append { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "precious".write(to: url, atomically: true, encoding: .utf8)
        let made = makeServer(url: url)
        XCTAssertThrowsError(try made.server.start())
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "precious")
    }

    func testOverlyLongSocketPathsFailClearly() {
        let long = URL(fileURLWithPath: "/tmp/" + String(repeating: "a", count: 200) + "/s.sock")
        let made = makeServer(url: long)
        XCTAssertThrowsError(try made.server.start()) { error in
            guard case IPCError.pathTooLong = error else { return XCTFail("wrong error \(error)") }
        }
        XCTAssertFalse(JarvisPaths.socketFile().path.utf8.count > 103, "the default location always fits")
    }

    func testTooManyConnectionsAreTurnedAway() throws {
        var limits = IPCServer.Limits()
        limits.maxConnections = 2
        let ready = try started(limits: limits)
        let first = try RawClient(path: ready.url.path)
        let second = try RawClient(path: ready.url.path)
        first.send(#"{"type":"ping"}"# + "\n"); second.send(#"{"type":"ping"}"# + "\n")
        XCTAssertNotNil(first.readLine()); XCTAssertNotNil(second.readLine())
        let third = try RawClient(path: ready.url.path)
        XCTAssertTrue(third.readLine()?.contains("\"busy\"") == true)
    }

    // MARK: Robustness

    func testADisconnectingClientCancelsItsRunningRequest() async throws {
        let integration = FakeRemindersIntegration()
        integration.delay = .seconds(30)
        let ready = try started(integration)
        let client = try RawClient(path: ready.url.path)
        client.send(#"{"type":"tool","tool":"reminders.create","arguments":{"title":"slow"}}"# + "\n")
        try await Task.sleep(for: .milliseconds(400))
        close(client.descriptor)   // hang up without waiting for the answer
        for _ in 0..<40 where !integration.wasCancelled { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(integration.wasCancelled, "the abandoned request must be cancelled, not left running")
        XCTAssertTrue(integration.created.isEmpty)
    }

    func testTheClientTimesOutInsteadOfHanging() async throws {
        let integration = FakeRemindersIntegration()
        integration.delay = .seconds(30)
        let ready = try started(integration)
        let client = IPCClient(socketPath: ready.url.path, timeout: 0.7)
        do {
            _ = try await client.send(IPCRequest(type: .tool, tool: "reminders.create", arguments: ["title": "slow"]))
            XCTFail("expected a timeout")
        } catch IPCError.timedOut {
            // expected
        }
    }

    func testConnectingToNothingIsAClearError() async {
        let client = IPCClient(socketPath: "/tmp/jarvis-definitely-not-here.sock", timeout: 2)
        do {
            _ = try await client.send(IPCRequest(type: .ping))
            XCTFail("expected an error")
        } catch IPCError.notConnected {
            // expected
        } catch {
            XCTFail("wrong error \(error)")
        }
    }

    func testConcurrentClientsAreServedIndependently() async throws {
        let ready = try started()
        let path = ready.url.path
        try await withThrowingTaskGroup(of: String.self) { group in
            for index in 0..<6 {
                group.addTask {
                    let response = try await IPCClient(socketPath: path, timeout: 10).send(IPCRequest(command: "Remind me to task number \(index)"))
                    return response.data?["title"]?.stringValue ?? "?"
                }
            }
            var titles: [String] = []
            for try await title in group { titles.append(title) }
            XCTAssertEqual(Set(titles), Set((0..<6).map { "Task number \($0)" }))
        }
    }

    func testEngineLevelPendingQuestionsAreScopedPerConnection() async throws {
        let ready = try started()
        // "yes" on a different connection (different implicit session) must not confirm another connection's request.
        let first = IPCClient(socketPath: ready.url.path, timeout: 10)
        let second = IPCClient(socketPath: ready.url.path, timeout: 10)
        let pending = try await first.send(IPCRequest(type: .tool, tool: "reminders.delete", arguments: ["id": "R-1"]))
        XCTAssertEqual(pending.status, "needs_confirmation")
        let stray = try await second.send(IPCRequest(command: "yes"))
        XCTAssertNotEqual(stray.status, "completed")
        XCTAssertFalse(stray.success && stray.results.contains { $0.tool == .remindersDelete })
    }

    func testSessionNamesLetAClientAnswerWithPlainWords() async throws {
        let ready = try started()
        let client = IPCClient(socketPath: ready.url.path, timeout: 10)
        let pending = try await client.send(IPCRequest(session: "voice-1", type: .tool, tool: "reminders.delete", arguments: ["id": "R-1"]))
        XCTAssertEqual(pending.status, "needs_confirmation")
        let yes = try await client.send(IPCRequest(command: "yes", session: "voice-1"))
        XCTAssertEqual(yes.status, "completed")
    }
}

private extension IPCRequest {
    init(session: String, type: Kind, tool: String, arguments: JSONObject) {
        self.init(type: type, session: session, tool: tool, arguments: arguments)
    }
}
