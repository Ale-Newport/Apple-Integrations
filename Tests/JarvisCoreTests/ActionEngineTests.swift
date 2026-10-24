import XCTest

@testable import JarvisCore

final class ActionEngineTests: XCTestCase {
    private let create: ToolName = "mock.create"
    private let remove: ToolName = "mock.remove"
    private let read: ToolName = "mock.read"

    private func standardTools(integration: IntegrationID = "mock") -> [ToolDescriptor] {
        [
            Fixtures.tool(
                create, integration: integration, parameters: [.string("title", "Title", required: true)],
                deduplicate: true),
            Fixtures.tool(
                remove, integration: integration, safety: .destructive,
                parameters: [.string("id", "Id", required: true)]),
            Fixtures.tool(read, integration: integration, safety: .readOnly),
        ]
    }

    private func request(
        _ text: String = "go", session: String = "s1", language: Language? = nil, allowDuplicate: Bool = false
    ) -> CommandRequest {
        CommandRequest(text: text, language: language, source: .test, session: session, allowDuplicate: allowDuplicate)
    }

    // MARK: Happy path and verification

    func testSuccessfulCallReturnsVerifiedStructuredResult() async {
        let integration = MockIntegration(id: "mock", tools: standardTools()) { _, _ in
            .done(
                ToolOutput(
                    message: "Reminder created", data: ["title": "Buy milk"],
                    verification: .verified("re-read from store")))
        }
        let engine = Fixtures.engine(
            integrations: [integration],
            interpreter: StubInterpreter(plan: [ToolCall(tool: create, arguments: ["title": "Buy milk"])]))
        let response = await engine.process(request())

        XCTAssertEqual(response.status, .completed)
        XCTAssertTrue(response.success)
        XCTAssertEqual(response.results.count, 1)
        let result = response.results[0]
        XCTAssertEqual(result.tool, create)
        XCTAssertEqual(result.data?["title"], "Buy milk")
        XCTAssertEqual(result.verification, .verified("re-read from store"))
        XCTAssertEqual(integration.calls.count, 1)
        XCTAssertEqual(response.interpreter, "stub")
    }

    func testUnverifiedResultsStayMarkedUnverified() async {
        let integration = MockIntegration(id: "mock", tools: standardTools()) { _, _ in
            .done(ToolOutput(message: "Done", verification: .unverified("could not read back")))
        }
        let engine = Fixtures.engine(
            integrations: [integration],
            interpreter: StubInterpreter(plan: [ToolCall(tool: create, arguments: ["title": "x"])]))
        let response = await engine.process(request())
        XCTAssertEqual(response.results[0].verification, .unverified("could not read back"))
        XCTAssertFalse(response.results[0].verification.isVerified)
    }

    func testInvalidArgumentsNeverReachTheIntegration() async {
        let integration = MockIntegration(id: "mock", tools: standardTools())
        let engine = Fixtures.engine(
            integrations: [integration],
            interpreter: StubInterpreter(plan: [ToolCall(tool: create, arguments: ["oops": "x"])]))
        let response = await engine.process(request())
        XCTAssertEqual(response.status, .failed)
        XCTAssertTrue(integration.calls.isEmpty)
        XCTAssertNotNil(response.results[0].errorCode)
    }

    func testUnknownToolIsRejected() async {
        let integration = MockIntegration(id: "mock", tools: standardTools())
        let engine = Fixtures.engine(
            integrations: [integration],
            interpreter: StubInterpreter(plan: [ToolCall(tool: "shell.exec", arguments: ["command": "rm -rf /"])]))
        let response = await engine.process(request())
        XCTAssertEqual(response.status, .failed)
        XCTAssertEqual(response.results[0].errorCode, "unknown_tool")
        XCTAssertTrue(integration.calls.isEmpty)
    }

    func testIntegrationErrorsBecomeFailedResultsInTheUsersLanguage() async {
        let integration = MockIntegration(id: "mock", tools: standardTools()) { _, _ in
            throw JarvisError.notFound(
                "list_not_found", en: "No list called Shopping.", es: "No existe una lista llamada Shopping.")
        }
        let engine = Fixtures.engine(
            integrations: [integration],
            interpreter: StubInterpreter(plan: [ToolCall(tool: create, arguments: ["title": "x"])]))

        let english = await engine.process(request(language: .en))
        XCTAssertEqual(english.status, .failed)
        XCTAssertEqual(english.message, "No list called Shopping.")
        XCTAssertEqual(english.results[0].errorCode, "list_not_found")

        let spanish = await engine.process(request(language: .es, allowDuplicate: true))
        XCTAssertEqual(spanish.message, "No existe una lista llamada Shopping.")
    }

    func testUnexpectedErrorsAreReportedWithoutCrashing() async {
        struct Boom: Error {}
        let integration = MockIntegration(id: "mock", tools: standardTools()) { _, _ in throw Boom() }
        let engine = Fixtures.engine(
            integrations: [integration], interpreter: StubInterpreter(plan: [ToolCall(tool: read)]))
        let response = await engine.process(request())
        XCTAssertEqual(response.status, .failed)
        XCTAssertEqual(response.results[0].errorCode, "internal_error")
    }

    func testUnsupportedToolsAreNotExecutedAndExplainThemselves() async {
        let tool = Fixtures.tool(
            "mock.delete_alarm",
            availability: .unsupported(
                reason: LocalizedText(en: "Clock cannot delete alarms.", es: "Reloj no puede eliminar alarmas."),
                alternative: LocalizedText(en: "Turn it off instead.", es: "Apágala en su lugar.")
            ))
        let integration = MockIntegration(id: "mock", tools: [tool])
        let engine = Fixtures.engine(
            integrations: [integration], interpreter: StubInterpreter(plan: [ToolCall(tool: "mock.delete_alarm")]))
        let response = await engine.process(request(language: .en))
        XCTAssertEqual(response.status, .unsupported)
        XCTAssertEqual(response.message, "Clock cannot delete alarms. Turn it off instead.")
        XCTAssertTrue(integration.calls.isEmpty)
    }

    // MARK: Permissions

    func testDeniedPermissionStopsExecutionAndReportsHowToFixIt() async {
        let integration = MockIntegration(
            id: "mock", tools: standardTools(), authorization: .denied(Fixtures.requirement))
        let engine = Fixtures.engine(
            integrations: [integration],
            interpreter: StubInterpreter(plan: [ToolCall(tool: create, arguments: ["title": "x"])]))
        let response = await engine.process(request())
        XCTAssertEqual(response.status, .permissionRequired)
        XCTAssertEqual(response.results[0].permission?.id, "mock.permission")
        XCTAssertNotNil(response.results[0].permission?.settingsURL)
        XCTAssertTrue(integration.calls.isEmpty)
        XCTAssertEqual(integration.requestCount, 0, "a denied permission must not be re-requested")
    }

    func testUndeterminedPermissionIsRequestedThenExecutionContinues() async {
        let integration = MockIntegration(
            id: "mock", tools: standardTools(), authorization: .notDetermined(Fixtures.requirement))
        integration.stateAfterRequest = .authorized
        let engine = Fixtures.engine(
            integrations: [integration],
            interpreter: StubInterpreter(plan: [ToolCall(tool: create, arguments: ["title": "x"])]))
        let response = await engine.process(request())
        XCTAssertEqual(response.status, .completed)
        XCTAssertEqual(integration.requestCount, 1)
        XCTAssertEqual(integration.calls.count, 1)
    }

    func testUserDecliningThePromptReportsPermissionRequired() async {
        let integration = MockIntegration(
            id: "mock", tools: standardTools(), authorization: .notDetermined(Fixtures.requirement))
        integration.stateAfterRequest = .denied(Fixtures.requirement)
        let engine = Fixtures.engine(
            integrations: [integration],
            interpreter: StubInterpreter(plan: [ToolCall(tool: create, arguments: ["title": "x"])]))
        let response = await engine.process(request())
        XCTAssertEqual(response.status, .permissionRequired)
        XCTAssertTrue(integration.calls.isEmpty)
    }

    func testUnavailableAppIsReportedClearly() async {
        let integration = MockIntegration(
            id: "mock", tools: standardTools(),
            authorization: .unavailable(LocalizedText(en: "Music is not installed.", es: "Música no está instalada.")))
        let engine = Fixtures.engine(
            integrations: [integration], interpreter: StubInterpreter(plan: [ToolCall(tool: read)]))
        let response = await engine.process(request(language: .es))
        XCTAssertEqual(response.status, .unavailable)
        XCTAssertEqual(response.message, "Música no está instalada.")
    }

    // MARK: Destructive actions and confirmation

    private func deletingIntegration() -> MockIntegration {
        MockIntegration(id: "mock", tools: standardTools()) { call, context in
            guard call.descriptor.name == "mock.remove" else {
                return .done(ToolOutput(message: "ok", verification: .notApplicable))
            }
            if !context.isConfirmed {
                return .confirm(ConfirmationRequest(prompt: "Delete “Old note”?", call: call.call, destructive: true))
            }
            return .done(ToolOutput(message: "Deleted", data: ["deleted": true], verification: .verified("gone")))
        }
    }

    func testDestructiveCallsAskBeforeDoingAnything() async {
        let integration = deletingIntegration()
        let engine = Fixtures.engine(
            integrations: [integration],
            interpreter: StubInterpreter(plan: [ToolCall(tool: remove, arguments: ["id": "n1"])]))
        let response = await engine.process(request())
        XCTAssertEqual(response.status, .needsConfirmation)
        let confirmation = try? XCTUnwrap(response.results[0].confirmation)
        XCTAssertNotNil(confirmation?.token)
        XCTAssertEqual(confirmation?.destructive, true)
        XCTAssertEqual(integration.calls.map(\.confirmed), [false])
        let pending = await engine.pendingCount
        XCTAssertEqual(pending, 1)
    }

    func testConfirmingRunsTheCallOnce() async throws {
        let integration = deletingIntegration()
        let engine = Fixtures.engine(
            integrations: [integration],
            interpreter: StubInterpreter(plan: [ToolCall(tool: remove, arguments: ["id": "n1"])]))
        let first = await engine.process(request())
        let token = try XCTUnwrap(first.results[0].confirmation?.token)

        let confirmed = await engine.resolve(token: token, decision: .confirm)
        XCTAssertEqual(confirmed.status, .completed)
        XCTAssertEqual(confirmed.results[0].verification, .verified("gone"))
        XCTAssertEqual(integration.calls.map(\.confirmed), [false, true])

        let again = await engine.resolve(token: token, decision: .confirm)
        XCTAssertEqual(again.status, .failed, "tokens are single-use")
        XCTAssertEqual(integration.calls.count, 2)
    }

    func testCancellingChangesNothing() async throws {
        let integration = deletingIntegration()
        let engine = Fixtures.engine(
            integrations: [integration],
            interpreter: StubInterpreter(plan: [ToolCall(tool: remove, arguments: ["id": "n1"])]))
        let first = await engine.process(request())
        let token = try XCTUnwrap(first.results[0].confirmation?.token)
        let cancelled = await engine.resolve(token: token, decision: .cancel)
        XCTAssertEqual(cancelled.status, .cancelled)
        XCTAssertEqual(integration.calls.map(\.confirmed), [false])
        let pending = await engine.pendingCount
        XCTAssertEqual(pending, 0)
    }

    func testTypingYesConfirmsTheMostRecentPendingQuestionOfTheSession() async {
        let integration = deletingIntegration()
        let interpreter = StubInterpreter { request in
            switch request.text {
            case "delete it":
                return .plan(
                    ToolPlan(
                        steps: [ToolCall(tool: "mock.remove", arguments: ["id": "n1"])], language: request.language,
                        interpreter: "stub"))
            default: return .unrecognized(hint: nil)
            }
        }
        let engine = Fixtures.engine(integrations: [integration], interpreter: interpreter)
        _ = await engine.process(request("delete it", session: "a"))

        // Another session saying "yes" must not confirm it.
        let other = await engine.process(request("yes", session: "b"))
        XCTAssertEqual(other.status, .unrecognized)
        XCTAssertEqual(integration.calls.count, 1)

        let yes = await engine.process(request("yes", session: "a"))
        XCTAssertEqual(yes.status, .completed)
        XCTAssertEqual(integration.calls.map(\.confirmed), [false, true])
    }

    func testSayingNoOrCancelCancels() async {
        for word in ["no", "cancel", "cancelar"] {
            let integration = deletingIntegration()
            let interpreter = StubInterpreter { request in
                request.text == "delete it"
                    ? .plan(
                        ToolPlan(
                            steps: [ToolCall(tool: "mock.remove", arguments: ["id": "n1"])], language: request.language,
                            interpreter: "stub"))
                    : .unrecognized(hint: nil)
            }
            let engine = Fixtures.engine(integrations: [integration], interpreter: interpreter)
            _ = await engine.process(request("delete it"))
            let answer = await engine.process(request(word))
            XCTAssertEqual(answer.status, .cancelled, word)
            XCTAssertEqual(integration.calls.map(\.confirmed), [false], word)
        }
    }

    func testExpiredConfirmationsCannotBeUsed() async throws {
        let integration = deletingIntegration()
        var limits = ActionEngine.Limits()
        limits.pendingLifetime = -1
        let engine = Fixtures.engine(
            integrations: [integration],
            interpreter: StubInterpreter(plan: [ToolCall(tool: remove, arguments: ["id": "n1"])]), limits: limits)
        let first = await engine.process(request())
        let token = try XCTUnwrap(first.results[0].confirmation?.token)
        let late = await engine.resolve(token: token, decision: .confirm)
        XCTAssertEqual(late.status, .failed)
        XCTAssertEqual(integration.calls.count, 1)
    }

    // MARK: Ambiguity

    private func ambiguousIntegration() -> MockIntegration {
        MockIntegration(id: "mock", tools: standardTools()) { call, _ in
            if call.string("title") == "meeting" {
                let options = [
                    ClarificationOption(
                        label: "Meeting with Daniel", detail: "Fri 3 PM",
                        call: ToolCall(tool: "mock.create", arguments: ["title": "daniel-meeting"])),
                    ClarificationOption(
                        label: "Meeting with Maria", detail: "Fri 4 PM",
                        call: ToolCall(tool: "mock.create", arguments: ["title": "maria-meeting"])),
                ]
                return .clarify(Clarification(question: "Which meeting?", options: options))
            }
            return .done(ToolOutput(message: "Created \(call.string("title") ?? "")", verification: .verified("x")))
        }
    }

    func testAmbiguousRequestsAskWhichOne() async throws {
        let integration = ambiguousIntegration()
        let engine = Fixtures.engine(
            integrations: [integration],
            interpreter: StubInterpreter(plan: [ToolCall(tool: create, arguments: ["title": "meeting"])]))
        let response = await engine.process(request())
        XCTAssertEqual(response.status, .needsClarification)
        let clarification = try XCTUnwrap(response.results[0].clarification)
        XCTAssertEqual(clarification.options.count, 2)
        XCTAssertNotNil(clarification.token)
    }

    func testChoosingAnOptionByButtonByNumberAndByName() async throws {
        for (answer, expected) in [
            ("2", "Created maria-meeting"), ("the first one", "Created daniel-meeting"),
            ("daniel", "Created daniel-meeting"), ("la segunda", "Created maria-meeting"),
        ] {
            let integration = ambiguousIntegration()
            let interpreter = StubInterpreter { request in
                request.text == "book meeting"
                    ? .plan(
                        ToolPlan(
                            steps: [ToolCall(tool: "mock.create", arguments: ["title": "meeting"])],
                            language: request.language, interpreter: "stub"))
                    : .unrecognized(hint: nil)
            }
            let engine = Fixtures.engine(integrations: [integration], interpreter: interpreter)
            _ = await engine.process(request("book meeting"))
            let response = await engine.process(request(answer))
            XCTAssertEqual(response.status, .completed, answer)
            XCTAssertEqual(response.message, expected, answer)
        }

        // Button path (token + index)
        let integration = ambiguousIntegration()
        let engine = Fixtures.engine(
            integrations: [integration],
            interpreter: StubInterpreter(plan: [ToolCall(tool: create, arguments: ["title": "meeting"])]))
        let first = await engine.process(request())
        let token = try XCTUnwrap(first.results[0].clarification?.token)
        let chosen = await engine.resolve(token: token, decision: .choose(1))
        XCTAssertEqual(chosen.message, "Created maria-meeting")
        let outOfRange = await engine.resolve(token: token, decision: .choose(0))
        XCTAssertEqual(outOfRange.status, .failed, "the token was consumed")
    }

    func testAnOutOfRangeChoiceKeepsWaiting() async throws {
        let integration = ambiguousIntegration()
        let engine = Fixtures.engine(
            integrations: [integration],
            interpreter: StubInterpreter(plan: [ToolCall(tool: create, arguments: ["title": "meeting"])]))
        let first = await engine.process(request())
        let token = try XCTUnwrap(first.results[0].clarification?.token)
        let wrong = await engine.resolve(token: token, decision: .choose(7))
        XCTAssertEqual(wrong.status, .failed)
        let pending = await engine.pendingCount
        XCTAssertEqual(pending, 1)
        let right = await engine.resolve(token: token, decision: .choose(0))
        XCTAssertEqual(right.status, .completed)
    }

    // MARK: Multi-step plans

    func testIndependentIntegrationsRunConcurrentlyButStepsOfOneIntegrationRunInOrder() async {
        let order = OrderRecorder()
        let slow: @Sendable (ValidatedToolCall, ExecutionContext) async throws -> ToolOutcome = { call, _ in
            await order.record("start \(call.string("title") ?? "")")
            try await Task.sleep(for: .milliseconds(300))
            await order.record("end \(call.string("title") ?? "")")
            return .done(ToolOutput(message: "ok", verification: .notApplicable))
        }
        let music = MockIntegration(
            id: "music", tools: [Fixtures.tool("music.go", integration: "music", parameters: [.string("title", "t")])],
            handler: slow)
        let reminders = MockIntegration(
            id: "reminders",
            tools: [Fixtures.tool("reminders.go", integration: "reminders", parameters: [.string("title", "t")])],
            handler: slow)
        let plan = [
            ToolCall(tool: "music.go", arguments: ["title": "m1"]),
            ToolCall(tool: "music.go", arguments: ["title": "m2"]),
            ToolCall(tool: "reminders.go", arguments: ["title": "r1"]),
        ]
        let engine = Fixtures.engine(integrations: [music, reminders], interpreter: StubInterpreter(plan: plan))

        let began = ContinuousClock.now
        let response = await engine.process(request())
        let elapsed = began.duration(to: .now)

        XCTAssertEqual(response.status, .completed)
        XCTAssertEqual(
            response.results.map(\.tool.rawValue), ["music.go", "music.go", "reminders.go"], "results keep plan order")
        // m1 and m2 are sequential (~600 ms); r1 overlaps with them, so the total is far below 900 ms.
        XCTAssertLessThan(elapsed, .milliseconds(850))
        let events = await order.events
        XCTAssertLessThan(events.firstIndex(of: "end m1")!, events.firstIndex(of: "start m2")!)
        XCTAssertLessThan(events.firstIndex(of: "start r1")!, events.firstIndex(of: "end m1")!)
    }

    func testAFailureSkipsLaterStepsOfTheSameIntegrationOnly() async {
        let music = MockIntegration(
            id: "music", tools: [Fixtures.tool("music.go", integration: "music", parameters: [.string("title", "t")])]
        ) { call, _ in
            if call.string("title") == "bad" { throw JarvisError.failed("boom", en: "boom", es: "boom") }
            return .done(ToolOutput(message: "ok", verification: .notApplicable))
        }
        let reminders = MockIntegration(
            id: "reminders", tools: [Fixtures.tool("reminders.go", integration: "reminders")])
        let plan = [
            ToolCall(tool: "music.go", arguments: ["title": "bad"]),
            ToolCall(tool: "music.go", arguments: ["title": "after"]),
            ToolCall(tool: "reminders.go"),
        ]
        let engine = Fixtures.engine(integrations: [music, reminders], interpreter: StubInterpreter(plan: plan))
        let response = await engine.process(request())
        XCTAssertEqual(response.results.map(\.status), [.failed, .skipped, .completed])
        XCTAssertEqual(response.status, .partial)
        XCTAssertEqual(music.calls.count, 1, "the skipped step never ran")
        XCTAssertEqual(reminders.calls.count, 1)
    }

    func testPlanNotesAreAppendedToTheMessage() async {
        let integration = MockIntegration(id: "mock", tools: standardTools())
        let interpreter = StubInterpreter { request in
            .plan(
                ToolPlan(
                    steps: [ToolCall(tool: "mock.read")], language: request.language, interpreter: "stub",
                    notes: ["I didn't understand: “blorf”."]))
        }
        let engine = Fixtures.engine(integrations: [integration], interpreter: interpreter)
        let response = await engine.process(request())
        XCTAssertTrue(response.message.contains("I didn't understand"))
        XCTAssertEqual(response.status, .partial)
    }

    func testMixedOutcomesAggregateSensibly() {
        func result(_ status: ToolResult.Status) -> ToolResult {
            ToolResult(callID: UUID(), tool: "x", status: status, message: "")
        }
        XCTAssertEqual(ActionEngine.aggregateStatus([result(.completed), result(.completed)]), .completed)
        XCTAssertEqual(ActionEngine.aggregateStatus([result(.completed), result(.failed)]), .partial)
        XCTAssertEqual(ActionEngine.aggregateStatus([result(.failed), result(.failed)]), .failed)
        XCTAssertEqual(
            ActionEngine.aggregateStatus([result(.permissionRequired), result(.failed)]), .permissionRequired)
        XCTAssertEqual(ActionEngine.aggregateStatus([result(.needsConfirmation)]), .needsConfirmation)
        XCTAssertEqual(ActionEngine.aggregateStatus([]), .unrecognized)
    }

    // MARK: Duplicates

    func testIdenticalCreationCallsAreNotRunTwice() async {
        let integration = MockIntegration(id: "mock", tools: standardTools())
        let engine = Fixtures.engine(
            integrations: [integration],
            interpreter: StubInterpreter(plan: [ToolCall(tool: create, arguments: ["title": "Buy milk"])]))
        let first = await engine.process(request())
        let second = await engine.process(request())
        XCTAssertEqual(first.status, .completed)
        XCTAssertEqual(second.status, .duplicate)
        XCTAssertEqual(integration.calls.count, 1)
    }

    func testDifferentArgumentsAreNotDuplicates() async {
        let integration = MockIntegration(id: "mock", tools: standardTools())
        let interpreter = StubInterpreter { request in
            .plan(
                ToolPlan(
                    steps: [ToolCall(tool: "mock.create", arguments: ["title": .string(request.text)])],
                    language: request.language, interpreter: "stub"))
        }
        let engine = Fixtures.engine(integrations: [integration], interpreter: interpreter)
        _ = await engine.process(request("milk"))
        _ = await engine.process(request("eggs"))
        XCTAssertEqual(integration.calls.count, 2)
    }

    func testFailedAttemptsCanBeRetriedImmediately() async {
        let attempts = Counter()
        let integration = MockIntegration(id: "mock", tools: standardTools()) { _, _ in
            if await attempts.next() == 1 { throw JarvisError.failed("flaky", en: "try again", es: "reintenta") }
            return .done(ToolOutput(message: "ok", verification: .notApplicable))
        }
        let engine = Fixtures.engine(
            integrations: [integration],
            interpreter: StubInterpreter(plan: [ToolCall(tool: create, arguments: ["title": "x"])]))
        let first = await engine.process(request())
        let second = await engine.process(request())
        XCTAssertEqual(first.status, .failed)
        XCTAssertEqual(second.status, .completed)
    }

    func testExplicitRepeatBypassesTheGuard() async {
        let integration = MockIntegration(id: "mock", tools: standardTools())
        let engine = Fixtures.engine(
            integrations: [integration],
            interpreter: StubInterpreter(plan: [ToolCall(tool: create, arguments: ["title": "x"])]))
        _ = await engine.process(request())
        let again = await engine.process(request(allowDuplicate: true))
        XCTAssertEqual(again.status, .completed)
        XCTAssertEqual(integration.calls.count, 2)
    }

    func testConcurrentIdenticalRequestsRunOnce() async {
        let integration = MockIntegration(id: "mock", tools: standardTools()) { _, _ in
            try await Task.sleep(for: .milliseconds(200))
            return .done(ToolOutput(message: "ok", verification: .notApplicable))
        }
        let engine = Fixtures.engine(
            integrations: [integration],
            interpreter: StubInterpreter(plan: [ToolCall(tool: create, arguments: ["title": "x"])]))
        let first = request()
        let second = request()
        async let a = engine.process(first)
        async let b = engine.process(second)
        let results = await [a, b]
        XCTAssertEqual(Set(results.map(\.status)), [.completed, .duplicate])
        XCTAssertEqual(integration.calls.count, 1)
    }

    func testReadOnlyToolsAreNeverSuppressed() async {
        let integration = MockIntegration(id: "mock", tools: standardTools())
        let engine = Fixtures.engine(
            integrations: [integration], interpreter: StubInterpreter(plan: [ToolCall(tool: read)]))
        _ = await engine.process(request())
        let second = await engine.process(request())
        XCTAssertEqual(second.status, .completed)
        XCTAssertEqual(integration.calls.count, 2)
    }

    // MARK: Timeouts and cancellation

    func testSlowToolsAreStoppedAtTheirDeadline() async {
        let tool = Fixtures.tool("mock.slow", timeout: 0.2)
        let integration = MockIntegration(id: "mock", tools: [tool]) { _, _ in
            try await Task.sleep(for: .seconds(30))
            return .done(ToolOutput(message: "never", verification: .notApplicable))
        }
        let engine = Fixtures.engine(
            integrations: [integration], interpreter: StubInterpreter(plan: [ToolCall(tool: "mock.slow")]))
        let began = ContinuousClock.now
        let response = await engine.process(request())
        XCTAssertEqual(response.status, .failed)
        XCTAssertEqual(response.results[0].errorCode, "timeout")
        XCTAssertLessThan(began.duration(to: .now), .seconds(3))
    }

    func testCancellingTheCallerCancelsTheRunningTool() async {
        let flag = Flag()
        let integration = MockIntegration(id: "mock", tools: standardTools()) { _, _ in
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                await flag.set()
                throw error
            }
            return .done(ToolOutput(message: "never", verification: .notApplicable))
        }
        let engine = Fixtures.engine(
            integrations: [integration], interpreter: StubInterpreter(plan: [ToolCall(tool: read)]))
        let task = Task { await engine.process(CommandRequest(text: "go", source: .test, session: "s")) }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let response = await task.value
        XCTAssertEqual(response.status, .cancelled)
        let observed = await flag.value
        XCTAssertTrue(observed, "the integration must see the cancellation")
    }

    // MARK: Conversation, language and history

    func testRepliesAndUnrecognisedInputNeedNoTools() async {
        let engine = Fixtures.engine(
            integrations: [MockIntegration(id: "mock", tools: standardTools())],
            interpreter: StubInterpreter { request in
                request.text == "hi" ? .reply("Hello!") : .unrecognized(hint: "Try “help”.")
            })
        let hello = await engine.process(request("hi"))
        XCTAssertEqual(hello.status, .reply)
        XCTAssertTrue(hello.success)
        XCTAssertEqual(hello.message, "Hello!")
        let unknown = await engine.process(request("???"))
        XCTAssertEqual(unknown.status, .unrecognized)
        XCTAssertFalse(unknown.success)
        XCTAssertTrue(unknown.message.contains("Try “help”."))
    }

    func testEmptyAndOversizedInputAreRejected() async {
        let engine = Fixtures.engine(
            integrations: [MockIntegration(id: "mock", tools: standardTools())],
            interpreter: StubInterpreter(plan: [ToolCall(tool: read)]))
        let empty = await engine.process(request("   "))
        XCTAssertEqual(empty.status, .unrecognized)
        let huge = await engine.process(request(String(repeating: "a", count: 25_000)))
        XCTAssertEqual(huge.status, .failed)
    }

    func testLanguageIsDetectedUnlessTheUserFixesIt() async {
        let engine = Fixtures.engine(
            integrations: [MockIntegration(id: "mock", tools: standardTools())],
            interpreter: StubInterpreter { request in
                .reply(request.language.rawValue)
            })
        let spanish = await engine.process(request("Recuérdame mañana a las seis llamar a mamá"))
        XCTAssertEqual(spanish.language, .es)
        let english = await engine.process(request("Remind me tomorrow to call Mom"))
        XCTAssertEqual(english.language, .en)
        let forced = await engine.process(request("Remind me tomorrow to call Mom", language: .es))
        XCTAssertEqual(forced.language, .es)

        var settings = JarvisSettings()
        settings.languagePreference = .spanish
        let fixedEngine = Fixtures.engine(
            integrations: [MockIntegration(id: "mock", tools: standardTools())],
            interpreter: StubInterpreter { .reply($0.language.rawValue) }, settings: settings)
        let preference = await fixedEngine.process(request("Remind me tomorrow to call Mom"))
        XCTAssertEqual(preference.language, .es)
    }

    func testTextWithoutLanguageHintsUsesTheHostsLanguage() async {
        let tools = [MockIntegration(id: "mock", tools: standardTools())]
        let echo = StubInterpreter { .reply($0.language.rawValue) }

        let spanishHost = Fixtures.engine(integrations: tools, interpreter: echo, fallbackLanguage: .es)
        let unknown = await spanishHost.process(request("bla bla ble"))
        XCTAssertEqual(unknown.language, .es, "gibberish has no hint, so the host language applies")
        let english = await spanishHost.process(request("Remind me tomorrow to call Mom"))
        XCTAssertEqual(english.language, .en, "a clear language signal always wins over the host default")

        let englishHost = Fixtures.engine(integrations: tools, interpreter: echo)
        let fallback = await englishHost.process(request("bla bla ble"))
        XCTAssertEqual(fallback.language, .en)

        var settings = JarvisSettings()
        settings.languagePreference = .english
        let fixed = Fixtures.engine(integrations: tools, interpreter: echo, settings: settings, fallbackLanguage: .es)
        let preference = await fixed.process(request("bla bla ble"))
        XCTAssertEqual(preference.language, .en, "a fixed preference beats the host default")
    }

    func testHousekeepingReadsCanSkipTheHistory() async throws {
        let recorder = HistoryRecorder()
        let engine = Fixtures.engine(
            integrations: [MockIntegration(id: "mock", tools: standardTools())],
            interpreter: StubInterpreter(plan: [ToolCall(tool: read)]), history: recorder)
        _ = await engine.execute(ToolCall(tool: read), recordHistory: false)
        let silent = await recorder.entries
        XCTAssertTrue(silent.isEmpty)
        _ = await engine.execute(ToolCall(tool: read))
        let recorded = await recorder.entries
        XCTAssertEqual(recorded.count, 1)
    }

    func testHistoryRecordsCommandsButNotConversationalReplies() async throws {
        let recorder = HistoryRecorder()
        let integration = MockIntegration(id: "mock", tools: standardTools())
        let engine = Fixtures.engine(
            integrations: [integration], interpreter: StubInterpreter(plan: [ToolCall(tool: read)]), history: recorder)
        let response = await engine.process(request("show it"))
        let entries = await recorder.entries
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].id, response.id)
        XCTAssertEqual(entries[0].text, "show it")
        XCTAssertEqual(entries[0].tools, ["mock.read"])
        XCTAssertEqual(entries[0].status, .completed)
        XCTAssertEqual(entries[0].source, "test")
    }

    func testHistoryCanBeSwitchedOff() async {
        let recorder = HistoryRecorder()
        var settings = JarvisSettings()
        settings.saveHistory = false
        let engine = Fixtures.engine(
            integrations: [MockIntegration(id: "mock", tools: standardTools())],
            interpreter: StubInterpreter(plan: [ToolCall(tool: read)]), settings: settings, history: recorder)
        _ = await engine.process(request("show it"))
        let entries = await recorder.entries
        XCTAssertTrue(entries.isEmpty)
    }

    func testResolvedConfirmationsUpdateTheHistoryEntry() async throws {
        let recorder = HistoryRecorder()
        let integration = deletingIntegration()
        let engine = Fixtures.engine(
            integrations: [integration],
            interpreter: StubInterpreter(plan: [ToolCall(tool: remove, arguments: ["id": "n1"])]), history: recorder)
        let first = await engine.process(request("delete it"))
        let token = try XCTUnwrap(first.results[0].confirmation?.token)
        _ = await engine.resolve(token: token, decision: .confirm)
        let updates = await recorder.updates
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates[0].0, first.id)
        XCTAssertEqual(updates[0].1, .completed)
    }

    func testDirectToolExecutionSkipsInterpretation() async {
        let integration = MockIntegration(id: "mock", tools: standardTools())
        let engine = Fixtures.engine(
            integrations: [integration], interpreter: StubInterpreter { _ in .unrecognized(hint: nil) })
        let response = await engine.execute(ToolCall(tool: create, arguments: ["title": "Direct"]), source: .ipc)
        XCTAssertEqual(response.status, .completed)
        XCTAssertEqual(response.interpreter, "direct")
        XCTAssertEqual(integration.calls.first?.arguments["title"], "Direct")
    }

    func testProgressEventsArriveInOrder() async {
        let integration = MockIntegration(id: "mock", tools: standardTools())
        let engine = Fixtures.engine(
            integrations: [integration], interpreter: StubInterpreter(plan: [ToolCall(tool: read)]))
        let events = EventLog()
        _ = await engine.process(request()) { event in
            switch event {
            case .planned: events.add("planned")
            case .stepStarted: events.add("started")
            case .stepFinished: events.add("finished")
            case .responseText: break
            }
        }
        XCTAssertEqual(events.all, ["planned", "started", "finished"])
    }
}

actor OrderRecorder {
    private(set) var events: [String] = []
    func record(_ event: String) { events.append(event) }
}

actor Counter {
    private var value = 0
    func next() -> Int {
        value += 1
        return value
    }
}

actor Flag {
    private(set) var value = false
    func set() { value = true }
}

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    func add(_ event: String) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }
    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}
