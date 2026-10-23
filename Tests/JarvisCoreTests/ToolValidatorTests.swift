import XCTest
@testable import JarvisCore

final class ToolValidatorTests: XCTestCase {
    private let descriptor = ToolDescriptor(
        name: "mock.create", integration: "mock", title: "Create", summary: "Create something",
        parameters: [
            .string("title", "Title", required: true, maxLength: 20),
            .integer("count", "Count", min: 1, max: 10, default: 1),
            .boolean("flag", "Flag"),
            .choice("priority", ["none", "low", "medium", "high"], "Priority", default: "none"),
            .dateOrDateTime("due", "Due"),
            .dateTime("start", "Start"),
            .time("at", "Time of day"),
            .strings("tags", "Tags", maxItems: 3, maxLength: 10),
            .number("ratio", "Ratio", min: 0, max: 1),
            .string("id", "Identifier"),
        ],
        constraints: [.atMostOne(["flag", "ratio"])],
        safety: .modifying
    )

    private func validate(_ arguments: JSONObject) throws -> ValidatedToolCall {
        try ToolValidator().validate(ToolCall(tool: "mock.create", arguments: arguments), against: descriptor)
    }

    private func issues(_ arguments: JSONObject, file: StaticString = #filePath, line: UInt = #line) -> [ValidationIssue] {
        do {
            _ = try validate(arguments)
            XCTFail("Expected validation to fail for \(arguments)", file: file, line: line)
            return []
        } catch JarvisError.validation(let issues) {
            return issues
        } catch {
            XCTFail("Unexpected error \(error)", file: file, line: line)
            return []
        }
    }

    func testAcceptsAMinimalCallAndAppliesDefaults() throws {
        let call = try validate(["title": "Buy milk"])
        XCTAssertEqual(call.string("title"), "Buy milk")
        XCTAssertEqual(call.int("count"), 1)
        XCTAssertEqual(call.string("priority"), "none")
        XCTAssertNil(call.string("due"))
    }

    func testMissingRequiredParameter() {
        let found = issues([:])
        XCTAssertEqual(found.map(\.code), [.missingRequired])
        XCTAssertEqual(found.first?.parameter, "title")
    }

    func testBlankRequiredStringCountsAsMissing() {
        XCTAssertEqual(issues(["title": "   \n "]).map(\.code), [.missingRequired])
    }

    func testRejectsUnknownParameters() {
        let found = issues(["title": "x", "shell": "rm -rf /"])
        XCTAssertEqual(found.map(\.code), [.unknownParameter])
        XCTAssertEqual(found.first?.parameter, "shell")
    }

    func testCoercesReasonableTypes() throws {
        let arguments: JSONObject = ["title": 42, "count": "3", "flag": "yes"]
        let call = try validate(arguments)
        XCTAssertEqual(call.string("title"), "42")
        XCTAssertEqual(call.int("count"), 3)
        XCTAssertEqual(call.bool("flag"), true)
        XCTAssertEqual(try validate(["title": "x", "ratio": "0.5"]).double("ratio"), 0.5)
    }

    func testRejectsWrongTypes() {
        XCTAssertEqual(issues(["title": "x", "count": "many"]).map(\.code), [.wrongType])
        XCTAssertEqual(issues(["title": "x", "flag": "maybe"]).map(\.code), [.wrongType])
        XCTAssertEqual(issues(["title": ["a"]]).map(\.code), [.wrongType])
    }

    func testRangeChecks() {
        XCTAssertEqual(issues(["title": "x", "count": 0]).map(\.code), [.outOfRange])
        XCTAssertEqual(issues(["title": "x", "count": 11]).map(\.code), [.outOfRange])
        XCTAssertEqual(issues(["title": "x", "ratio": 1.5]).map(\.code), [.outOfRange])
    }

    func testStringLengthLimit() {
        XCTAssertEqual(issues(["title": .string(String(repeating: "a", count: 21))]).map(\.code), [.tooLong])
    }

    func testEnumerationIsCanonicalisedAndChecked() throws {
        XCTAssertEqual(try validate(["title": "x", "priority": "HIGH"]).string("priority"), "high")
        XCTAssertEqual(issues(["title": "x", "priority": "urgent"]).map(\.code), [.invalidValue])
    }

    func testDatesTimesAreChecked() throws {
        XCTAssertNoThrow(try validate(["title": "x", "due": "2026-10-18"]))
        XCTAssertNoThrow(try validate(["title": "x", "due": "2026-10-18T18:00:00-04:00"]))
        XCTAssertNoThrow(try validate(["title": "x", "start": "2026-10-18T18:00:00Z"]))
        XCTAssertEqual(try validate(["title": "x", "at": "7:05"]).string("at"), "07:05")
        XCTAssertEqual(issues(["title": "x", "due": "tomorrow"]).map(\.code), [.invalidValue])
        XCTAssertEqual(issues(["title": "x", "due": "2026-02-30"]).map(\.code), [.invalidValue])
        XCTAssertEqual(issues(["title": "x", "start": "2026-10-18"]).map(\.code), [.invalidValue], "start requires a time")
        XCTAssertEqual(issues(["title": "x", "at": "25:00"]).map(\.code), [.invalidValue])
    }

    func testStringListsAreTrimmedAndLimited() throws {
        let call = try validate(["title": "x", "tags": [" a ", "", "b"]])
        XCTAssertEqual(call.strings("tags"), ["a", "b"])
        XCTAssertEqual(try validate(["title": "x", "tags": "solo"]).strings("tags"), ["solo"])
        XCTAssertEqual(issues(["title": "x", "tags": ["a", "b", "c", "d"]]).map(\.code), [.outOfRange])
        XCTAssertEqual(issues(["title": "x", "tags": [.string(String(repeating: "z", count: 11))]]).map(\.code), [.tooLong])
    }

    func testConstraints() {
        XCTAssertEqual(issues(["title": "x", "flag": true, "ratio": 0.1]).map(\.code), [.constraintViolated])
    }

    func testNullAndEmptyOptionalsAreTreatedAsAbsent() throws {
        let call = try validate(["title": "x", "id": "  ", "due": .null])
        XCTAssertFalse(call.has("id"))
        XCTAssertFalse(call.has("due"))
    }

    func testControlCharactersAreStrippedButNewlinesSurvive() throws {
        let call = try validate(["title": "a\u{0000}b\u{0007}c", "id": "line1\nline2\r\n"])
        XCTAssertEqual(call.string("title"), "abc")
        XCTAssertEqual(call.string("id"), "line1\nline2")
    }

    func testDecodingIntoTypedArguments() throws {
        struct Args: Decodable { var title: String; var count: Int; var priority: String; var tags: [String]? }
        let call = try validate(["title": "Report", "count": 2, "tags": ["a"]])
        let args: Args = try call.decode()
        XCTAssertEqual(args.title, "Report")
        XCTAssertEqual(args.count, 2)
        XCTAssertEqual(args.priority, "none")
        XCTAssertEqual(args.tags, ["a"])
    }

    func testRegistryReportsUnknownTools() {
        let registry = ToolRegistry(integrations: [MockIntegration(id: "mock", tools: [descriptor])])
        XCTAssertThrowsError(try registry.validate(ToolCall(tool: "nope.nothing"))) { error in
            guard case JarvisError.validation(let found) = error else { return XCTFail("wrong error \(error)") }
            XCTAssertEqual(found.first?.code, .unknownTool)
        }
        XCTAssertNotNil(registry.integration(for: "mock.create"))
        XCTAssertEqual(registry.descriptors.map(\.name), ["mock.create"])
    }

    func testSchemaDescriptionListsParametersForLLMs() throws {
        let registry = ToolRegistry(integrations: [MockIntegration(id: "mock", tools: [descriptor])])
        let schema = registry.schemaDescription()
        let tool = try XCTUnwrap(schema[0])
        XCTAssertEqual(tool["name"], "mock.create")
        XCTAssertEqual(tool["parameters"]?["title"]?["required"], true)
        XCTAssertEqual(tool["parameters"]?["priority"]?["type"], "enum(none|low|medium|high)")
    }
}
