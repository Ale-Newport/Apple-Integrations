import XCTest
@testable import JarvisCore

final class AgentWorkflowTests: XCTestCase {
    private func plan(_ tools: [ToolCall], _ request: InterpretationRequest) -> Interpretation {
        var plan = ToolPlan(steps: tools, language: request.language, interpreter: "agent.test")
        plan.continues = true
        return .plan(plan)
    }
    private func request(_ text: String = "summarize my tasks", session: String = "agent") -> CommandRequest { CommandRequest(text: text, source: .test, session: session) }

    func testDependentWriteUsesActualReadResult() async {
        let integration = MockIntegration(id: "mock", tools: [Fixtures.tool("mock.read", safety: .readOnly), Fixtures.tool("mock.write", parameters: [.string("content", "Content", required: true)])]) { call, _ in
            .done(ToolOutput(message: "OK", data: call.descriptor.name.rawValue == "mock.read" ? ["title": "Verified task"] : .object(call.arguments), verification: .verified("test")))
        }
        let interpreter = StubInterpreter { request in
            var plan = ToolPlan(steps: [], language: request.language, interpreter: "agent.test")
            plan.continues = true
            if request.observations.isEmpty { plan.steps = [ToolCall(tool: "mock.read")] }
            else if request.observations.count == 1 {
                plan.steps = [ToolCall(tool: "mock.write", arguments: ["content": request.observations[0].data?["title"] ?? "INVENTED"])]
            } else { return .reply("Done") }
            return .plan(plan)
        }
        let engine = Fixtures.engine(integrations: [integration], interpreter: interpreter)
        let result = await engine.process(request())
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.results.map(\.tool), ["mock.read", "mock.write"])
        XCTAssertEqual(integration.calls.last?.arguments["content"], "Verified task")
    }

    func testWriteFailureStopsReplanningAndPreservesRead() async {
        let integration = MockIntegration(id: "mock", tools: [Fixtures.tool("mock.read", safety: .readOnly), Fixtures.tool("mock.write")]) { call, _ in
            if call.descriptor.name.rawValue == "mock.write" { throw JarvisError.failed("disk", en: "Not saved", es: "No guardado") }
            return .done(ToolOutput(message: "Read", data: ["id": "actual"], verification: .notApplicable))
        }
        let interpreter = StubInterpreter { request in
            var plan = ToolPlan(steps: [ToolCall(tool: request.observations.isEmpty ? "mock.read" : "mock.write")], language: request.language, interpreter: "agent.test")
            plan.continues = true
            return .plan(plan)
        }
        let response = await Fixtures.engine(integrations: [integration], interpreter: interpreter).process(request())
        XCTAssertEqual(response.status, .partial)
        XCTAssertEqual(integration.calls.count, 2)
        XCTAssertEqual(response.results.last?.errorCode, "disk")
    }

    func testEntireBatchValidatesBeforeEffectsAndMixedWritesAreRejected() async {
        for steps in [[ToolCall(tool: "mock.write"), ToolCall(tool: "invented.shell")], [ToolCall(tool: "mock.read"), ToolCall(tool: "mock.write")]] {
            let integration = MockIntegration(id: "mock", tools: [Fixtures.tool("mock.read", safety: .readOnly), Fixtures.tool("mock.write")])
            let interpreter = StubInterpreter { request in
                var plan = ToolPlan(steps: steps, language: request.language, interpreter: "agent.test"); plan.continues = true; return .plan(plan)
            }
            let response = await Fixtures.engine(integrations: [integration], interpreter: interpreter).process(request())
            XCTAssertEqual(response.status, .failed)
            XCTAssertTrue(integration.calls.isEmpty)
        }
    }

    func testRepeatedMutationStopsEvenWithDuplicateWindowDisabled() async {
        var settings = JarvisSettings(); settings.duplicateWindowSeconds = 0
        let integration = MockIntegration(id: "mock", tools: [Fixtures.tool("mock.write")])
        let interpreter = StubInterpreter { request in
            var plan = ToolPlan(steps: [ToolCall(tool: "mock.write")], language: request.language, interpreter: "agent.test"); plan.continues = true; return .plan(plan)
        }
        let response = await Fixtures.engine(integrations: [integration], interpreter: interpreter, settings: settings).process(request())
        XCTAssertEqual(response.status, .partial)
        XCTAssertEqual(integration.calls.count, 1)
    }

    func testWorkflowRoundLimit() async {
        var settings = JarvisSettings(); settings.model.maxRounds = 3
        let integration = MockIntegration(id: "mock", tools: [Fixtures.tool("mock.read", safety: .readOnly)])
        let interpreter = StubInterpreter { request in
            var plan = ToolPlan(steps: [ToolCall(tool: "mock.read")], language: request.language, interpreter: "agent.test"); plan.continues = true; return .plan(plan)
        }
        let response = await Fixtures.engine(integrations: [integration], interpreter: interpreter, settings: settings).process(request())
        XCTAssertEqual(integration.calls.count, 3)
        XCTAssertEqual(response.status, .partial)
    }

    func testContextIsSessionScopedAndCanBeErased() async {
        let integration = MockIntegration(id: "mock", tools: [Fixtures.tool("mock.read", safety: .readOnly)])
        let interpreter = StubInterpreter { request in
            if request.text == "first" { return .plan(ToolPlan(steps: [ToolCall(tool: "mock.read")], language: request.language, interpreter: "test")) }
            return .reply("\(request.conversation.count)")
        }
        let engine = Fixtures.engine(integrations: [integration], interpreter: interpreter)
        _ = await engine.process(request("first"))
        let same = await engine.process(request("context"))
        let other = await engine.process(request("context", session: "other"))
        XCTAssertEqual(same.message, "1"); XCTAssertEqual(other.message, "0")
        await engine.clearSession("agent")
        let cleared = await engine.process(request("context"))
        XCTAssertEqual(cleared.message, "0")
    }

    func testDisabledContextNeverReachesInterpreter() async {
        var settings = JarvisSettings(); settings.rememberSession = false
        let interpreter = StubInterpreter { request in .reply("\(request.conversation.count)") }
        let engine = Fixtures.engine(integrations: [], interpreter: interpreter, settings: settings)
        _ = await engine.process(request())
        let response = await engine.process(request())
        XCTAssertEqual(response.message, "0")
    }

    func testConfirmationResumesDependentWorkflowOnlyAfterConsent() async throws {
        let integration = MockIntegration(id: "mock", tools: [Fixtures.tool("mock.remove", safety: .destructive), Fixtures.tool("mock.read", safety: .readOnly)]) { call, context in
            if call.descriptor.name.rawValue == "mock.remove", !context.isConfirmed {
                return .confirm(ConfirmationRequest(prompt: "Delete?", call: call.call, destructive: true))
            }
            return .done(ToolOutput(message: "Verified", data: ["id": "actual"], verification: .verified("test")))
        }
        let interpreter = StubInterpreter { request in
            if request.observations.count >= 2 { return .reply("Done") }
            var plan = ToolPlan(steps: [ToolCall(tool: request.observations.isEmpty ? "mock.remove" : "mock.read")], language: request.language, interpreter: "agent.test"); plan.continues = true; return .plan(plan)
        }
        let engine = Fixtures.engine(integrations: [integration], interpreter: interpreter)
        let pending = await engine.process(request())
        let token = try XCTUnwrap(pending.results.first?.confirmation?.token)
        XCTAssertEqual(integration.calls.count, 1)
        let response = await engine.resolve(token: token, decision: .confirm)
        XCTAssertEqual(response.status, .completed)
        XCTAssertEqual(integration.calls.map(\.tool), ["mock.remove", "mock.remove", "mock.read"])
    }

    func testPermissionFailureNeverReplans() async {
        let integration = MockIntegration(id: "mock", tools: [Fixtures.tool("mock.write")], authorization: .denied(Fixtures.requirement))
        let interpreter = StubInterpreter { request in
            var plan = ToolPlan(steps: [ToolCall(tool: "mock.write")], language: request.language, interpreter: "agent.test"); plan.continues = true; return .plan(plan)
        }
        let response = await Fixtures.engine(integrations: [integration], interpreter: interpreter).process(request())
        XCTAssertEqual(response.status, .permissionRequired)
        XCTAssertTrue(integration.calls.isEmpty)
    }
    func testCorrectionInvalidatesOldConfirmation() async throws {
        let integration = MockIntegration(id: "mock", tools: [Fixtures.tool("mock.remove", safety: .destructive)]) { call, context in
            if !context.isConfirmed { return .confirm(ConfirmationRequest(prompt: "Delete all?", call: call.call, destructive: true)) }
            return .done(ToolOutput(message: "Deleted", verification: .verified("test")))
        }
        let interpreter = StubInterpreter { request in
            if request.text == "delete all" { return .plan(ToolPlan(steps: [ToolCall(tool: "mock.remove")], language: request.language, interpreter: "test")) }
            return .clarification(Clarification(question: "Which projects?"))
        }
        let engine = Fixtures.engine(integrations: [integration], interpreter: interpreter)
        let first = await engine.process(request("delete all"))
        let token = try XCTUnwrap(first.results.first?.confirmation?.token)
        _ = await engine.process(request("Wait, only projects"))
        let old = await engine.resolve(token: token, decision: .confirm)
        XCTAssertEqual(old.status, .failed)
        XCTAssertEqual(integration.calls.count, 1)
    }

    func testUnknownCreationOutcomeIsNotBlindlyRetried() async {
        let integration = MockIntegration(id: "mock", tools: [Fixtures.tool("mock.create", deduplicate: true)]) { _, _ in
            throw JarvisError.verificationFailed(LocalizedText("May have saved"))
        }
        let engine = Fixtures.engine(integrations: [integration], interpreter: StubInterpreter(plan: [ToolCall(tool: "mock.create")]))
        _ = await engine.process(request())
        let second = await engine.process(request())
        XCTAssertEqual(second.results.first?.errorCode, "uncertain_write")
        XCTAssertEqual(integration.calls.count, 1)
    }

    func testNewInstructionStopsFurtherEffectsOfRunningWorkflow() async {
        let started = expectation(description: "read started")
        let integration = MockIntegration(id: "mock", tools: [Fixtures.tool("mock.read", safety: .readOnly), Fixtures.tool("mock.write")]) { call, _ in
            if call.descriptor.name.rawValue == "mock.read" {
                started.fulfill()
                try await Task.sleep(for: .milliseconds(150))
            }
            return .done(ToolOutput(message: "Read", verification: .notApplicable))
        }
        let interpreter = StubInterpreter { input in
            if input.text == "new instruction" { return .reply("Updated scope") }
            var plan = ToolPlan(steps: [ToolCall(tool: input.observations.isEmpty ? "mock.read" : "mock.write")], language: input.language, interpreter: "agent.test")
            plan.continues = true
            return .plan(plan)
        }
        let engine = Fixtures.engine(integrations: [integration], interpreter: interpreter)
        let original = Task { await engine.process(CommandRequest(text: "original", source: .test, session: "same")) }
        await fulfillment(of: [started], timeout: 2)
        _ = await engine.process(CommandRequest(text: "new instruction", source: .test, session: "same"))
        let cancelled = await original.value
        XCTAssertEqual(cancelled.status, .cancelled)
        XCTAssertEqual(integration.calls.map(\.tool), ["mock.read"])
    }

}
