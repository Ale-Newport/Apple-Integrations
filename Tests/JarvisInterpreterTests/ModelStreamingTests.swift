import JarvisCore
import XCTest

@testable import JarvisInterpreter

final class ModelStreamingTests: XCTestCase {
    func testSSEAccumulatesContentAndRequiresDone() throws {
        var decoder = ChatSSEDecoder()
        XCTAssertNil(try decoder.consume(": heartbeat"))
        XCTAssertEqual(try decoder.consume(#"data: {"choices":[{"delta":{"content":"Hola "}}]}"#), "Hola ")
        XCTAssertEqual(try decoder.consume(#"data: {"choices":[{"delta":{"content":"🌍"}}]}"#), "🌍")
        XCTAssertEqual(decoder.text, "Hola 🌍")
        XCTAssertFalse(decoder.done)
        XCTAssertNil(try decoder.consume("data: [DONE]"))
        XCTAssertTrue(decoder.done)
    }
    func testStreamingRefusesTruncationProviderErrorsAndToolCalls() throws {
        for payload in [
            #"data: {"choices":[{"finish_reason":"length"}]}"#, #"data: {"error":{"message":"quota"}}"#,
            #"data: {"choices":[{"finish_reason":"tool_calls"}]}"#,
        ] {
            var decoder = ChatSSEDecoder()
            XCTAssertThrowsError(try decoder.consume(payload))
        }
    }
    func testReplyPreviewNeverShowsPlanningJSONOrArguments() {
        for raw in [
            #"{"calls":[{"tool":"mail.send","arguments":{"body":"private"}}],"reply":"Sent"}"#,
            #"{"question":"Which one?","reply":"Do it"}"#, #"{"reply":"Not yet known"}"#,
        ] { XCTAssertNil(ReplyStreamDecoder.replyPrefix(raw)) }
        XCTAssertEqual(ReplyStreamDecoder.replyPrefix(#"{"calls":[],"reply":"Hola\nMundo"}"#), "Hola\nMundo")
        XCTAssertEqual(ReplyStreamDecoder.replyPrefix(#"{"calls":[],"reply":"Hi \uD83C\uDF0D"}"#), "Hi 🌍")
        XCTAssertEqual(ReplyStreamDecoder.replyPrefix(#"{"calls":[],"reply":"Hi \uD83C"#), "Hi ")
        XCTAssertEqual(ReplyStreamDecoder.replyPrefix(#"{"calls":[],"reply":"Quote: \"hello\""}"#), "Quote: \"hello\"")
    }
}
