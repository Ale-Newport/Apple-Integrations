import XCTest
@testable import JarvisCore
@testable import JarvisInterpreter

/// A scripted language model. It never executes anything — it just returns text, like a real provider would.
private struct ScriptedProvider: LLMTextProvider {
    let identifier = "scripted"
    var answer: @Sendable (String, String) throws -> String

    func complete(system: String, user: String) async throws -> String { try answer(system, user) }
}

private func tools() -> [ToolDescriptor] {
    [
        ToolDescriptor(name: .remindersCreate, integration: .reminders, title: "Create", summary: "Create a reminder", parameters: [
            .string("title", "Title", required: true), .string("list", "List"), .dateOrDateTime("due", "Due"),
        ], safety: .modifying, examples: [ToolExample("Add buy milk to my Shopping reminders list", arguments: ["title": "Buy milk", "list": "Shopping"])]),
        ToolDescriptor(name: .musicPause, integration: .music, title: "Pause", summary: "Pause playback", safety: .modifying),
        ToolDescriptor(name: .alarmsDelete, integration: .clock, title: "Delete alarm", summary: "Delete", safety: .destructive,
                       availability: .unsupported(reason: LocalizedText("no"), alternative: nil)),
    ]
}

private func request(_ text: String = "get me ready for bed") -> InterpretationRequest {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/London")!
    calendar.firstWeekday = 2
    return InterpretationRequest(text: text, language: .en, now: ISODates.date(from: "2026-10-17T13:08:00+01:00", timeZone: calendar.timeZone)!, calendar: calendar, settings: JarvisSettings(), tools: tools())
}

final class AIProposalParserTests: XCTestCase {
    func testPlainJSONObject() throws {
        let proposal = try AIProposalParser.parse(#"{"calls":[{"tool":"reminders.create","arguments":{"title":"Buy milk"}}]}"#)
        XCTAssertEqual(proposal.calls, [ProposedToolCall(tool: "reminders.create", arguments: ["title": "Buy milk"])])
    }

    func testMarkdownFencesAndChatterAreIgnored() throws {
        let raw = """
        Sure! Here is the plan:
        ```json
        {"calls":[{"tool":"music.pause","arguments":{}}], "reply": ""}
        ```
        Let me know if you need anything else.
        """
        XCTAssertEqual(try AIProposalParser.parse(raw).calls.map(\.tool), ["music.pause"])
    }

    func testAlternativeKeyNamesAndBareArrays() throws {
        XCTAssertEqual(try AIProposalParser.parse(#"[{"name":"music.pause","args":{}}]"#).calls.map(\.tool), ["music.pause"])
        XCTAssertEqual(try AIProposalParser.parse(#"{"tool":"music.pause","parameters":{"x":1}}"#).calls.first?.arguments, ["x": 1])
        XCTAssertEqual(try AIProposalParser.parse(#"{"tool_calls":[{"tool":"music.pause"}]}"#).calls.count, 1)
    }

    func testQuestionsAndReplies() throws {
        let question = try AIProposalParser.parse(#"{"calls":[],"question":"What time?"}"#)
        XCTAssertEqual(question.clarifyingQuestion, "What time?")
        XCTAssertTrue(question.calls.isEmpty)
        XCTAssertEqual(try AIProposalParser.parse(#"{"reply":"Hello!"}"#).reply, "Hello!")
        XCTAssertNil(try AIProposalParser.parse(#"{"calls":[],"question":"  "}"#).clarifyingQuestion)
    }

    func testBracesInsideStringsDoNotConfuseExtraction() throws {
        let raw = #"Answer: {"calls":[{"tool":"notes.create","arguments":{"content":"a } b { c ```"}}]} done"#
        XCTAssertEqual(try AIProposalParser.parse(raw).calls.first?.arguments["content"], "a } b { c ```")
    }

    func testGarbageIsRejected() {
        XCTAssertThrowsError(try AIProposalParser.parse("I cannot help with that.")) { XCTAssertEqual($0 as? AIProposalParser.ParseError, .noJSON) }
        XCTAssertThrowsError(try AIProposalParser.parse("{ not json }")) { XCTAssertEqual($0 as? AIProposalParser.ParseError, .malformed) }
        XCTAssertThrowsError(try AIProposalParser.parse("42")) { XCTAssertEqual($0 as? AIProposalParser.ParseError, .noJSON) }
    }

    func testRunawayModelsCannotRequestHundredsOfCalls() {
        let many = (0..<40).map { _ in #"{"tool":"music.pause"}"# }.joined(separator: ",")
        XCTAssertThrowsError(try AIProposalParser.parse("[\(many)]")) { XCTAssertEqual($0 as? AIProposalParser.ParseError, .tooManyCalls) }
    }

    func testEntriesWithoutAToolNameAreDropped() throws {
        let proposal = try AIProposalParser.parse(#"{"calls":[{"arguments":{}},{"tool":"music.pause"},"text",5]}"#)
        XCTAssertEqual(proposal.calls.map(\.tool), ["music.pause"])
    }
}

final class LLMInterpreterTests: XCTestCase {
    func testThePromptDescribesSupportedToolsDatesAndRules() {
        let prompt = LLMPromptBuilder.systemPrompt(for: request())
        XCTAssertTrue(prompt.contains("reminders.create"))
        XCTAssertTrue(prompt.contains("music.pause"))
        XCTAssertFalse(prompt.contains("alarms.delete"), "unsupported tools are not offered to the model")
        XCTAssertTrue(prompt.contains("2026-10-17T13:08:00+01:00"))
        XCTAssertTrue(prompt.contains("Europe/London"))
        XCTAssertTrue(prompt.contains("Never output code"))
        XCTAssertTrue(prompt.contains("Add buy milk to my Shopping reminders list"), "few-shot examples come from the descriptors")
    }

    func testProposalsBecomePlansWithProvenance() async throws {
        let provider = ScriptedProvider { _, user in
            XCTAssertEqual(user, "get me ready for bed")
            return #"{"calls":[{"tool":"music.pause","arguments":{}},{"tool":"reminders.create","arguments":{"title":"Brush teeth"}}]}"#
        }
        let interpretation = try await AIInterpreterAdapter(LLMToolCallInterpreter(provider: provider)).interpret(request())
        guard case .plan(let plan) = interpretation else { return XCTFail("expected a plan, got \(interpretation)") }
        XCTAssertEqual(plan.steps.map(\.tool), [.musicPause, .remindersCreate])
        XCTAssertEqual(plan.interpreter, "llm.scripted")
        XCTAssertEqual(plan.steps.first?.sourceText, "get me ready for bed")
    }

    func testInventedToolsAreDroppedBeforeTheyReachTheEngine() async throws {
        let provider = ScriptedProvider { _, _ in
            #"{"calls":[{"tool":"shell.exec","arguments":{"command":"rm -rf ~"}},{"tool":"applescript.run","arguments":{"source":"do shell script \"x\""}},{"tool":"music.pause"}]}"#
        }
        let interpretation = try await AIInterpreterAdapter(LLMToolCallInterpreter(provider: provider)).interpret(request())
        guard case .plan(let plan) = interpretation else { return XCTFail("expected a plan") }
        XCTAssertEqual(plan.steps.map(\.tool.rawValue), ["music.pause"])
    }

    func testOnlyInventedToolsMeansNotUnderstood() async throws {
        let provider = ScriptedProvider { _, _ in #"{"calls":[{"tool":"shell.exec","arguments":{"command":"id"}}]}"# }
        let interpretation = try await AIInterpreterAdapter(LLMToolCallInterpreter(provider: provider)).interpret(request())
        guard case .unrecognized = interpretation else { return XCTFail("expected unrecognized, got \(interpretation)") }
    }

    func testQuestionsRepliesAndFailures() async throws {
        let asks = ScriptedProvider { _, _ in #"{"calls":[],"question":"Which list?"}"# }
        guard case .clarification(let clarification) = try await AIInterpreterAdapter(LLMToolCallInterpreter(provider: asks)).interpret(request()) else { return XCTFail() }
        XCTAssertEqual(clarification.question, "Which list?")

        let chats = ScriptedProvider { _, _ in #"{"reply":"Good night!"}"# }
        guard case .reply(let text) = try await AIInterpreterAdapter(LLMToolCallInterpreter(provider: chats)).interpret(request()) else { return XCTFail() }
        XCTAssertEqual(text, "Good night!")

        struct Offline: Error {}
        let broken = ScriptedProvider { _, _ in throw Offline() }
        guard case .unrecognized = try await AIInterpreterAdapter(LLMToolCallInterpreter(provider: broken)).interpret(request()) else { return XCTFail("a failing provider must not crash the command") }

        let nonsense = ScriptedProvider { _, _ in "I'm sorry, I can't do that." }
        guard case .unrecognized = try await AIInterpreterAdapter(LLMToolCallInterpreter(provider: nonsense)).interpret(request()) else { return XCTFail() }
    }

    func testCancellationPropagatesFromTheProvider() async {
        let slow = ScriptedProvider { _, _ in throw CancellationError() }
        do {
            _ = try await AIInterpreterAdapter(LLMToolCallInterpreter(provider: slow)).interpret(request())
            XCTFail("expected cancellation")
        } catch is CancellationError {}
        catch { XCTFail("wrong error \(error)") }
    }

    func testHybridUsesTheRulesFirstAndTheModelOnlyForTheRest() async throws {
        let calls = LockedCounter()
        let provider = ScriptedProvider { _, _ in calls.increment(); return #"{"calls":[{"tool":"music.pause"}]}"# }
        let hybrid = HybridCommandInterpreter(ai: LLMToolCallInterpreter(provider: provider))

        let understood = try await hybrid.interpret(request("pause the music"))
        guard case .plan(let first) = understood else { return XCTFail() }
        XCTAssertEqual(first.interpreter, "deterministic")
        XCTAssertEqual(calls.value, 0, "the model is not consulted for commands the rules understand")

        let unknown = try await hybrid.interpret(request("make it cozy in here"))
        guard case .plan(let second) = unknown else { return XCTFail("expected the model's plan, got \(unknown)") }
        XCTAssertEqual(second.interpreter, "llm.scripted")
        XCTAssertEqual(calls.value, 1)
    }

    func testHybridAIFirstFallsBackToTheRules() async throws {
        let silent = ScriptedProvider { _, _ in "no idea" }
        let hybrid = HybridCommandInterpreter(ai: LLMToolCallInterpreter(provider: silent), policy: .aiFirst)
        guard case .plan(let plan) = try await hybrid.interpret(request("pause the music")) else { return XCTFail() }
        XCTAssertEqual(plan.interpreter, "deterministic")
    }

    func testHybridWithoutAnAIBehavesLikeTheRules() async throws {
        let hybrid = HybridCommandInterpreter()
        guard case .unrecognized = try await hybrid.interpret(request("make it cozy in here")) else { return XCTFail() }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
