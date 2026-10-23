import XCTest
@testable import JarvisCore

final class ISODatesTests: XCTestCase {
    private let london = TimeZone(identifier: "Europe/London")!

    func testParsesDatesDateTimesAndOffsets() throws {
        XCTAssertEqual(ISODates.parseDateParts("2026-10-18"), ISODates.DateParts(year: 2026, month: 10, day: 18))
        let withOffset = try XCTUnwrap(ISODates.date(from: "2026-10-18T18:00:00-04:00", timeZone: london))
        XCTAssertEqual(withOffset.timeIntervalSince1970, 1_792_360_800, accuracy: 0.5)   // 22:00 UTC
        let zulu = try XCTUnwrap(ISODates.date(from: "2026-10-18T22:00:00Z", timeZone: london))
        XCTAssertEqual(zulu, withOffset)
        let compact = try XCTUnwrap(ISODates.date(from: "2026-10-18T18:00:00-0400", timeZone: london))
        XCTAssertEqual(compact, withOffset)
        let fractional = try XCTUnwrap(ISODates.date(from: "2026-10-18T18:00:00.250-04:00", timeZone: london))
        XCTAssertEqual(fractional, withOffset)
    }

    func testOffsetlessDateTimesUseTheGivenZone() throws {
        let local = try XCTUnwrap(ISODates.date(from: "2026-10-18T18:00:00", timeZone: london))
        XCTAssertEqual(ISODates.string(from: local, timeZone: london), "2026-10-18T18:00:00+01:00")
        let tokyo = try XCTUnwrap(ISODates.date(from: "2026-10-18T18:00:00", timeZone: TimeZone(identifier: "Asia/Tokyo")!))
        XCTAssertEqual(ISODates.string(from: tokyo, timeZone: TimeZone(identifier: "UTC")!), "2026-10-18T09:00:00+00:00")
        let spaced = try XCTUnwrap(ISODates.date(from: "2026-10-18 18:00", timeZone: london))
        XCTAssertEqual(spaced, local)
    }

    func testRejectsImpossibleOrMalformedInput() {
        for bad in ["2026-02-30", "2026-13-01", "2026-00-10", "2026-10-18T25:00:00", "2026-10-18T10:61:00", "18/10/2026", "tomorrow", "", "2026-10-18T10:00:00+25:00", "1800-01-01"] {
            XCTAssertNil(ISODates.parse(bad, timeZone: london), bad)
        }
        XCTAssertNil(ISODates.parseTime("24:00"))
        XCTAssertNil(ISODates.parseTime("7:5"))
        XCTAssertEqual(ISODates.parseTime("7:05"), ISODates.TimeParts(hour: 7, minute: 5, second: 0))
    }

    func testFormattingRoundTripsAcrossTheFallBackTransition() throws {
        // 25 Oct 2026, 01:30 happens twice in London; both instants format with their own offsets.
        let first = Date(timeIntervalSince1970: 1_792_888_200)   // 00:30 UTC → 01:30 BST
        let second = first.addingTimeInterval(3600)               // 01:30 UTC → 01:30 GMT
        XCTAssertEqual(ISODates.string(from: first, timeZone: london), "2026-10-25T01:30:00+01:00")
        XCTAssertEqual(ISODates.string(from: second, timeZone: london), "2026-10-25T01:30:00+00:00")
        XCTAssertEqual(ISODates.date(from: ISODates.string(from: first, timeZone: london), timeZone: london), first)
        XCTAssertEqual(ISODates.date(from: ISODates.string(from: second, timeZone: london), timeZone: london), second)
    }

    func testDayStringAndTimeString() {
        let date = ISODates.date(from: "2026-03-05T23:59:00+00:00", timeZone: london)!
        XCTAssertEqual(ISODates.dayString(from: date, timeZone: london), "2026-03-05")
        XCTAssertEqual(ISODates.dayString(from: date, timeZone: TimeZone(identifier: "Asia/Tokyo")!), "2026-03-06")
        XCTAssertEqual(ISODates.timeString(hour: 7, minute: 5), "07:05")
    }
}

final class DateMathTests: XCTestCase {
    private let london: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }()

    private func at(_ text: String) -> Date { ISODates.date(from: text, timeZone: london.timeZone)! }

    func testCombineProducesWallClockTimes() {
        let day = at("2026-10-23T08:00:00+01:00")
        XCTAssertEqual(ISODates.string(from: DateMath.combine(day: day, hour: 15, minute: 30, calendar: london), timeZone: london.timeZone), "2026-10-23T15:30:00+01:00")
    }

    func testNonExistentLocalTimeMovesForward() {
        // 29 Mar 2026: the clock jumps from 01:00 to 02:00.
        let day = at("2026-03-29T12:00:00+01:00")
        XCTAssertEqual(ISODates.string(from: DateMath.combine(day: day, hour: 1, minute: 30, calendar: london), timeZone: london.timeZone), "2026-03-29T02:00:00+01:00")
    }

    func testRepeatedLocalTimeTakesTheFirstOccurrence() {
        let day = at("2026-10-25T12:00:00+00:00")
        XCTAssertEqual(ISODates.string(from: DateMath.combine(day: day, hour: 1, minute: 30, calendar: london), timeZone: london.timeZone), "2026-10-25T01:30:00+01:00")
    }

    func testMovingKeepsTheUntouchedPart() {
        let start = at("2026-10-23T10:15:00+01:00")
        let newDay = at("2026-10-26T00:00:00+00:00")
        XCTAssertEqual(ISODates.string(from: DateMath.moving(start, toDay: newDay, time: nil, calendar: london), timeZone: london.timeZone), "2026-10-26T10:15:00+00:00")
        XCTAssertEqual(ISODates.string(from: DateMath.moving(start, toDay: nil, time: (16, 0), calendar: london), timeZone: london.timeZone), "2026-10-23T16:00:00+01:00")
        XCTAssertTrue(DateMath.sameDay(start, at("2026-10-23T23:59:00+01:00"), calendar: london))
        XCTAssertEqual(DateMath.clock(of: start, calendar: london).minute, 15)
    }
}

final class TextMatchingTests: XCTestCase {
    func testFoldingIgnoresCaseAccentsAndTypography() {
        XCTAssertEqual(TextFolding.fold("  ÁRBOL   Ñandú\u{00A0}“Fiesta” "), "arbol nandu \"fiesta\"")
        XCTAssertEqual(TextFolding.fold("İstanbul").first, "i")
        XCTAssertEqual(TextFolding.tokens("Meeting-with   Daniel!"), ["meeting", "with", "daniel"])
        XCTAssertEqual(TextFolding.fold(Character("É")), "e")
    }

    func testScoresRankExactBeforePrefixBeforeContains() {
        XCTAssertEqual(NameMatcher.score(query: "Shopping", candidate: "shopping"), 100)
        XCTAssertGreaterThan(NameMatcher.score(query: "Shopping", candidate: "Shopping list"), NameMatcher.score(query: "list", candidate: "Shopping list") - 20)
        XCTAssertGreaterThanOrEqual(NameMatcher.score(query: "shopping list", candidate: "Shopping"), 70, "filler words around a name are forgiven")
        XCTAssertGreaterThanOrEqual(NameMatcher.score(query: "lista de compras", candidate: "Compras"), 70)
        XCTAssertEqual(NameMatcher.score(query: "Work", candidate: "Personal"), 0)
        XCTAssertEqual(NameMatcher.score(query: "", candidate: "x"), 0)
        XCTAssertGreaterThan(NameMatcher.score(query: "meeting", candidate: "Meeting with Daniel"), NameMatcher.score(query: "meeting", candidate: "Team meeting notes"))
    }

    func testBestMatchesReportsTies() {
        let names = ["Chill", "Chill", "Study", "Chillhop"]
        XCTAssertEqual(NameMatcher.bestMatches(names, query: "chill", minimumScore: 60) { $0 }, ["Chill", "Chill"])
        XCTAssertEqual(NameMatcher.bestMatches(names, query: "study", minimumScore: 60) { $0 }, ["Study"])
        XCTAssertTrue(NameMatcher.bestMatches(names, query: "jazz", minimumScore: 60) { $0 }.isEmpty)
    }

    func testAccentInsensitiveNameMatching() {
        XCTAssertEqual(NameMatcher.score(query: "musica", candidate: "Música"), 100)
        XCTAssertEqual(NameMatcher.score(query: "reunion con ana", candidate: "Reunión con Ana"), 100)
    }
}

final class LanguageDetectorTests: XCTestCase {
    func testDetectsEnglishAndSpanish() {
        XCTAssertEqual(LanguageDetector.detect("Add milk to my Shopping reminders list"), .en)
        XCTAssertEqual(LanguageDetector.detect("Play my Chill playlist and remind me to study at 8 PM"), .en)
        XCTAssertEqual(LanguageDetector.detect("Recuérdame mañana a las 6 llamar a mamá"), .es)
        XCTAssertEqual(LanguageDetector.detect("¿Qué tengo en mi calendario el viernes?"), .es)
        XCTAssertEqual(LanguageDetector.detect("pon una alarma a las 7"), .es)
        XCTAssertEqual(LanguageDetector.detect("agenda una reunión con Daniel"), .es)
    }

    func testFallbackWhenThereIsNoSignal() {
        XCTAssertEqual(LanguageDetector.detect("Bohemian Rhapsody"), .en)
        XCTAssertEqual(LanguageDetector.detect("Bohemian Rhapsody", fallback: .es), .es)
        XCTAssertEqual(LanguageDetector.detect(""), .en)
    }

    func testHintParsing() {
        XCTAssertEqual(Language(hint: "en"), .en)
        XCTAssertEqual(Language(hint: "en-US"), .en)
        XCTAssertEqual(Language(hint: "ES_mx"), .es)
        XCTAssertEqual(Language(hint: "español"), .es)
        XCTAssertNil(Language(hint: "fr"))
        XCTAssertNil(Language(hint: nil))
        XCTAssertNil(Language(hint: " "))
    }
}

final class JSONValueTests: XCTestCase {
    func testCodableRoundTripKeepsTypes() throws {
        let value: JSONValue = ["a": 1, "b": 2.5, "c": "text", "d": true, "e": nil, "f": [1, "x", false], "g": ["nested": ["k": "v"]]]
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(decoded, value)
        XCTAssertEqual(decoded["a"], .int(1))
        XCTAssertEqual(decoded["b"], .double(2.5))
        XCTAssertEqual(decoded["g"]?["nested"]?["k"], "v")
        XCTAssertEqual(decoded["f"]?[1], "x")
    }

    func testNumbersAreNotConfusedWithBooleans() throws {
        let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"one":1,"yes":true,"zero":0}"#.utf8))
        XCTAssertEqual(decoded["one"], .int(1))
        XCTAssertEqual(decoded["yes"], .bool(true))
        XCTAssertEqual(decoded["zero"], .int(0))
        XCTAssertEqual(decoded["one"]?.intValue, 1)
        XCTAssertNil(decoded["yes"]?.intValue)
        XCTAssertEqual(JSONValue.double(3.0).intValue, 3)
        XCTAssertNil(JSONValue.double(3.5).intValue)
    }

    func testCanonicalStringIsDeterministic() {
        let a: JSONValue = ["b": 1, "a": ["z": 1, "y": 2]]
        let b: JSONValue = ["a": ["y": 2, "z": 1], "b": 1]
        XCTAssertEqual(a.canonicalString(), b.canonicalString())
        XCTAssertEqual(a.canonicalString(), #"{"a":{"y":2,"z":1},"b":1}"#)
    }

    func testBridgingWithCodableTypes() throws {
        struct Payload: Codable, Equatable { var listName: String; var dueDate: String?; var count: Int }
        let value = try JSONValue.encoding(Payload(listName: "Shopping", dueDate: nil, count: 2))
        XCTAssertEqual(value["list_name"], "Shopping", "snake_case on the wire")
        XCTAssertEqual(try value.decoded(as: Payload.self), Payload(listName: "Shopping", dueDate: nil, count: 2))
        XCTAssertEqual(JSONValue(nil as String?), .null)
        XCTAssertEqual(["a": .null, "b": 1].droppingNulls(), ["b": 1])
    }

    func testToolCallDecodesMinimalJSONAndKeepsAssumptions() throws {
        let minimal = try JSONDecoder().decode(ToolCall.self, from: Data(#"{"tool":"music.pause"}"#.utf8))
        XCTAssertEqual(minimal.tool, .musicPause)
        XCTAssertTrue(minimal.arguments.isEmpty)
        let full = ToolCall(tool: .remindersCreate, arguments: ["title": "x"], assumptions: ["Assumed 6:00 PM"], sourceText: "remind me")
        let roundTrip = try JSONDecoder().decode(ToolCall.self, from: JSONEncoder().encode(full))
        XCTAssertEqual(roundTrip, full)
    }

    func testToolResultAndEngineResponseRoundTrip() throws {
        let result = ToolResult(callID: UUID(), tool: .remindersCreate, status: .completed, message: "ok", data: ["id": "R1"], verification: .verified("re-read"), assumptions: ["a"], warnings: ["w"], durationMs: 12)
        let response = EngineResponse(input: "x", language: .es, status: .completed, message: "ok", results: [result], interpreter: "deterministic")
        let decoded = try JSONDecoder().decode(EngineResponse.self, from: JSONEncoder().encode(response))
        XCTAssertEqual(decoded.results, [result])
        XCTAssertEqual(decoded.language, .es)
        XCTAssertTrue(decoded.success)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any]
        XCTAssertEqual(object?["success"] as? Bool, true)
        XCTAssertEqual((object?["verification"] as? [String: Any])?["state"] as? String, "verified")
    }
}

final class ReplyClassifierTests: XCTestCase {
    func testConfirmations() {
        for word in ["yes", "Yes!", "ok", "sure", "go ahead", "do it", "confirm", "sí", "SI", "claro", "dale", "adelante", "hazlo", "de acuerdo", "yes please"] {
            XCTAssertEqual(ReplyClassifier.classify(word, optionCount: 0), .confirm, word)
        }
    }

    func testCancellations() {
        for word in ["no", "No.", "cancel", "never mind", "nope", "cancelar", "cancela", "olvídalo", "mejor no", "no gracias"] {
            XCTAssertEqual(ReplyClassifier.classify(word, optionCount: 0), .cancel, word)
        }
        XCTAssertEqual(ReplyClassifier.classify("cancel", optionCount: 3), .cancel)
    }

    func testOrdinalsAndNumbers() {
        XCTAssertEqual(ReplyClassifier.classify("2", optionCount: 3), .choose(1))
        XCTAssertEqual(ReplyClassifier.classify("the first one", optionCount: 3), .choose(0))
        XCTAssertEqual(ReplyClassifier.classify("option 3", optionCount: 3), .choose(2))
        XCTAssertEqual(ReplyClassifier.classify("la segunda", optionCount: 3), .choose(1))
        XCTAssertEqual(ReplyClassifier.classify("el último", optionCount: 3), .choose(2))
        XCTAssertEqual(ReplyClassifier.classify("last", optionCount: 4), .choose(3))
        XCTAssertNil(ReplyClassifier.classify("5", optionCount: 3), "out of range")
        XCTAssertNil(ReplyClassifier.classify("yes", optionCount: 3), "yes does not pick an option")
    }

    func testMatchingAnOptionByItsName() {
        let labels = ["Meeting with Daniel", "Meeting with Maria"]
        XCTAssertEqual(ReplyClassifier.classify("daniel", optionCount: 2, optionLabels: labels), .choose(0))
        XCTAssertEqual(ReplyClassifier.classify("maria", optionCount: 2, optionLabels: labels), .choose(1))
        XCTAssertNil(ReplyClassifier.classify("meeting", optionCount: 2, optionLabels: labels), "ambiguous")
        XCTAssertNil(ReplyClassifier.classify("play my study playlist please right now", optionCount: 2, optionLabels: labels))
    }

    func testOrdinaryCommandsAreNotMistakenForReplies() {
        for text in ["pause the music", "remind me to call mom", "what's on my calendar tomorrow", "yes I would like to add milk to my list"] {
            XCTAssertNil(ReplyClassifier.classify(text, optionCount: 0), text)
        }
    }
}
