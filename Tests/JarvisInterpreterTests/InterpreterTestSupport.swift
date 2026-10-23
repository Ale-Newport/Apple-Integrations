import XCTest
@testable import JarvisCore
@testable import JarvisInterpreter

/// Shared helpers: "now" is Saturday 17 Oct 2026, 13:08 in Europe/London (BST).
class InterpreterTestCase: XCTestCase {
    static let london = TimeZone(identifier: "Europe/London")!

    func request(_ text: String, language: Language = .en, now: String = "2026-10-17T13:08:00+01:00", zone: TimeZone = london, settings: JarvisSettings = JarvisSettings()) -> InterpretationRequest {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        calendar.firstWeekday = 2
        calendar.locale = Locale(identifier: "en_GB")
        return InterpretationRequest(text: text, language: language, now: ISODates.date(from: now, timeZone: zone)!, calendar: calendar, settings: settings)
    }

    func interpret(_ text: String, language: Language? = nil, settings: JarvisSettings = JarvisSettings()) async throws -> Interpretation {
        let detected = language ?? LanguageDetector.detect(text)
        return try await DeterministicInterpreter().interpret(request(text, language: detected, settings: settings))
    }

    /// The planned calls, or a test failure describing what was returned instead.
    func plan(_ text: String, language: Language? = nil, file: StaticString = #filePath, line: UInt = #line) async throws -> [ToolCall] {
        let result = try await interpret(text, language: language)
        guard case .plan(let plan) = result else {
            XCTFail("Expected a plan for “\(text)” but got \(result)", file: file, line: line)
            return []
        }
        return plan.steps
    }

    func single(_ text: String, language: Language? = nil, file: StaticString = #filePath, line: UInt = #line) async throws -> ToolCall {
        let steps = try await plan(text, language: language, file: file, line: line)
        XCTAssertEqual(steps.count, 1, "Expected exactly one step for “\(text)”, got \(steps.map(\.tool.rawValue))", file: file, line: line)
        return steps.first ?? ToolCall(tool: "none")
    }

    func assertCall(_ call: ToolCall, _ tool: ToolName, _ expected: JSONObject = [:], exact: Bool = false, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(call.tool, tool, file: file, line: line)
        for (key, value) in expected {
            XCTAssertEqual(call.arguments[key], value, "argument '\(key)' of \(call.tool) in \(call.arguments)", file: file, line: line)
        }
        if exact {
            XCTAssertEqual(Set(call.arguments.keys), Set(expected.keys), "unexpected arguments in \(call.arguments)", file: file, line: line)
        }
    }
}
