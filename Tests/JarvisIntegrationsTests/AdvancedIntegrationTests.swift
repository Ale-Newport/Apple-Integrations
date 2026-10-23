import Foundation
import XCTest
import JarvisCore
@testable import JarvisIntegrations

final class CalculatorTests: XCTestCase {
    func testNumericAccuracyAndPrecedence() throws {
        let corpus: [(String, Double)] = [
            ("17.5%*2450", 428.75), ("20000/(4*12)", 416.6666666666667),
            ("(2+3)^4", 625), ("2^3^2", 512), ("-2^2", -4), ("2^-3", 0.125),
            ("sqrt(81)+ln(e)", 10), ("sin(pi/2)", 1), ("cos(0)", 1),
            ("mean(1,2,3,4)", 2.5), ("max(1,5,-2)", 5), ("1e3+0.5", 1000.5), ("log10(1000)", 3)
        ]
        for (text, expected) in corpus { XCTAssertEqual(try Calculator.evaluate(text), expected, accuracy: 1e-9, text) }
    }
    func testUnsafeInvalidOrNonFiniteExpressionsFail() {
        for text in ["1/0", "sqrt(-1)", "2+", "shell('rm')", "NSExpression", "1;2", "1foo", "2**3", String(repeating: "(", count: 100) + "1" + String(repeating: ")", count: 100)] {
            XCTAssertThrowsError(try Calculator.evaluate(text), text)
        }
    }
    func testUnitDimensionsAndTemperatureOffsets() throws {
        XCTAssertEqual(try UnitConversion.convert(10, from: "km", to: "mi"), 6.2137119224, accuracy: 1e-9)
        XCTAssertEqual(try UnitConversion.convert(32, from: "F", to: "C"), 0, accuracy: 1e-10)
        XCTAssertEqual(try UnitConversion.convert(100, from: "C", to: "F"), 212, accuracy: 1e-10)
        XCTAssertEqual(try UnitConversion.convert(36, from: "km/h", to: "m/s"), 10, accuracy: 1e-10)
        XCTAssertThrowsError(try UnitConversion.convert(1, from: "kg", to: "m"))
        XCTAssertThrowsError(try UnitConversion.convert(1, from: "EUR", to: "USD"))
    }
    func testFuzzyComparisonHandlesTypoAndUnicodeWithoutBroadeningDestructiveMatching() {
        XCTAssertGreaterThanOrEqual(FuzzyNameMatcher.score(query: "Bohemian Rapsody", candidate: "Bohemian Rhapsody"), 85)
        XCTAssertGreaterThanOrEqual(FuzzyNameMatcher.score(query: "Arctic Monkyes", candidate: "Arctic Monkeys"), 85)
        XCTAssertEqual(FuzzyNameMatcher.score(query: "Beyoncé", candidate: "Beyonce"), 100)
        XCTAssertEqual(NameMatcher.score(query: "Bohemian Rapsody", candidate: "Bohemian Rhapsody"), 0)
        XCTAssertLessThan(FuzzyNameMatcher.score(query: "Queen", candidate: "Metallica"), 50)
    }
}

private actor MockWeather: WeatherDataLoading {
    var requests: [URL] = []
    let ambiguous: Bool
    let fail: Bool
    init(ambiguous: Bool = false, fail: Bool = false) { self.ambiguous = ambiguous; self.fail = fail }
    func load(_ url: URL) async throws -> JSONValue {
        requests.append(url)
        if fail { throw URLError(.notConnectedToInternet) }
        if url.host == "geocoding-api.open-meteo.com" {
            let place: JSONValue = ["id": 1, "name": "London", "country": "UK", "latitude": 51.5, "longitude": -0.1, "population": 1000]
            return ["results": ambiguous ? [place, ["id": 2, "name": "London", "country": "Canada", "latitude": 43.0, "longitude": -81.0, "population": 900]] : [place]]
        }
        return ["timezone": "Europe/London", "current": ["temperature_2m": 16.5], "daily": ["time": ["2026-10-18"], "temperature_2m_min": [10], "temperature_2m_max": [18], "precipitation_probability_max": [70], "sunrise": ["2026-10-18T07:30"], "sunset": ["2026-10-18T18:00"], "uv_index_max": [2]]]
    }
}

final class WeatherIntegrationTests: XCTestCase {
    func testRealDataShapeAndAttributionAndCaching() async throws {
        let loader = MockWeather()
        let registry = ToolRegistry(integrations: [WeatherIntegration(cache: WeatherCache(loader: loader))])
        let first = try await registry.run("weather.forecast", ["location": "London", "date": "2026-10-18"])
        XCTAssertEqual(first.output?.data?["days"]?[0]?["rain_probability_percent"]?.doubleValue, 70)
        XCTAssertTrue(first.output?.message.contains("Open-Meteo") == true)
        _ = try await registry.run("weather.forecast", ["location": "London", "date": "2026-10-18"])
        let count = await loader.requests.count
        XCTAssertEqual(count, 2, "geocoding and forecast should each be cached")
    }
    func testMissingLocationAndAmbiguousLocationAskWithoutInventingForecast() async throws {
        let loader = MockWeather(ambiguous: true)
        let registry = ToolRegistry(integrations: [WeatherIntegration(cache: WeatherCache(loader: loader))])
        let missing = try await registry.run("weather.forecast", [:])
        XCTAssertNotNil(missing.clarification)
        let ambiguous = try await registry.run("weather.forecast", ["location": "London"])
        XCTAssertEqual(ambiguous.clarification?.options.count, 2)
        let count = await loader.requests.count
        XCTAssertEqual(count, 1)
    }
    func testLocationChoiceUsesVerifiedID() async throws {
        let loader = MockWeather(ambiguous: true)
        let registry = ToolRegistry(integrations: [WeatherIntegration(cache: WeatherCache(loader: loader))])
        let response = try await registry.run("weather.forecast", ["location": "London", "place_id": 2])
        XCTAssertEqual(response.output?.data?["location"], "London, Canada")
        let urls = await loader.requests
        XCTAssertTrue(urls.last?.query?.contains("latitude=43.0") == true)
    }
    func testUnavailableAndOutOfRangeNeverReturnGuessedWeather() async throws {
        let bad = ToolRegistry(integrations: [WeatherIntegration(cache: WeatherCache(loader: MockWeather(fail: true)))])
        do { _ = try await bad.run("weather.forecast", ["location": "London"]); XCTFail() }
        catch let error as JarvisError { XCTAssertEqual(error.code, "weather_unavailable") }
        let good = ToolRegistry(integrations: [WeatherIntegration(cache: WeatherCache(loader: MockWeather()))])
        do { _ = try await good.run("weather.forecast", ["location": "London", "date": "2027-01-01"]); XCTFail() }
        catch let error as JarvisError { XCTAssertEqual(error.code, "forecast_range") }
    }
}

final class AdvancedRemindersTests: XCTestCase {
    func testSectionsAndSubtasksCannotSilentlyCreateFlatReminders() async throws {
        let store = InMemoryReminderStore.standard()
        let registry = ToolRegistry(integrations: [RemindersIntegration(store: store)])
        for metadata in [["section": JSONValue.string("Mercadona")], ["parent_title": JSONValue.string("Proyecto")]] {
            do { _ = try await registry.run(.remindersCreate, ["title": "Comprar arroz"].merging(metadata) { _, right in right }); XCTFail() }
            catch let error as JarvisError { XCTAssertEqual(error.code, "unsupported") }
        }
        let count = await store.createCalls
        XCTAssertEqual(count, 0)
    }
    func testRecurrenceIsSavedAndReadBack() async throws {
        let store = InMemoryReminderStore.standard()
        let registry = ToolRegistry(integrations: [RemindersIntegration(store: store)])
        let created = try await registry.run(.remindersCreate, ["title": "Stretch", "due": "2026-10-18T09:00:00+01:00", "recurrence": "daily", "priority": "high", "notes": "Breathe"])
        XCTAssertEqual(created.output?.data?["recurrence"], "daily")
        let id = try XCTUnwrap(created.output?.data?["id"]?.stringValue)
        let changed = try await registry.run(.remindersUpdate, ["id": .string(id), "new_recurrence": "none"])
        XCTAssertEqual(changed.output?.data?["recurrence"], .null)
    }
    func testRecurringReminderWithoutFirstDateAsksBeforeSaving() async throws {
        let store = InMemoryReminderStore.standard()
        let outcome = try await ToolRegistry(integrations: [RemindersIntegration(store: store)]).run(.remindersCreate, ["title": "Stretch", "recurrence": "daily"])
        XCTAssertNotNil(outcome.clarification)
        let count = await store.createCalls; XCTAssertEqual(count, 0)
    }
    func testRenameListAndDeleteUseStableIDsAndReadBack() async throws {
        let store = InMemoryReminderStore.standard()
        let registry = ToolRegistry(integrations: [RemindersIntegration(store: store)])
        let renamed = try await registry.run("reminders.rename_list", ["name": "Shopping", "new_name": "Groceries"])
        XCTAssertEqual(renamed.output?.data?["id"], "L-shop")
        let pending = try await registry.run("reminders.delete_list", ["name": "Groceries"])
        let confirmation = try XCTUnwrap(pending.confirmation)
        XCTAssertEqual(confirmation.call.arguments["list_id"], "L-shop")
        let listsBefore = try await store.lists(); XCTAssertTrue(listsBefore.contains { $0.id == "L-shop" })
        let deleted = try await registry.run(confirmation.call.tool, confirmation.call.arguments, context: executionContext(confirmed: true))
        XCTAssertTrue(deleted.output?.verification.isVerified == true)
        let listsAfter = try await store.lists(); XCTAssertFalse(listsAfter.contains { $0.id == "L-shop" })
    }
    func testListContentsChangingAfterConfirmationRequiresFreshConfirmation() async throws {
        let store = InMemoryReminderStore.standard()
        let registry = ToolRegistry(integrations: [RemindersIntegration(store: store)])
        let pending = try await registry.run("reminders.delete_list", ["name": "Shopping"])
        let confirmation = try XCTUnwrap(pending.confirmation)
        _ = try await registry.run(.remindersCreate, ["title": "Milk", "list": "Shopping"])
        let changed = try await registry.run(confirmation.call.tool, confirmation.call.arguments, context: executionContext(confirmed: true))
        XCTAssertNotNil(changed.confirmation)
        let lists = try await store.lists(); XCTAssertTrue(lists.contains { $0.id == "L-shop" })
    }

}

final class ScheduleAnalysisTests: XCTestCase {
    private func at(_ value: String) -> Date { ISODates.date(from: value, timeZone: TimeZone(identifier: "Europe/London")!)! }
    func testSlotsAvoidBusyTimeAcrossCalendars() async throws {
        let store = InMemoryEventStore.standard()
        await store.seed("Class", at("2026-10-19T09:00:00+01:00"), at("2026-10-19T11:00:00+01:00"))
        await store.seed("Meeting", at("2026-10-19T12:00:00+01:00"), at("2026-10-19T13:00:00+01:00"), calendarID: "C-work")
        let registry = ToolRegistry(integrations: [CalendarIntegration(store: store)])
        let outcome = try await registry.run("calendar.find_free_slots", ["start": "2026-10-19", "end": "2026-10-20", "duration_minutes": 120, "limit": 1])
        XCTAssertEqual(outcome.output?.data?["slots"]?[0]?["start"], "2026-10-19T13:00:00+01:00")
        XCTAssertEqual(outcome.output?.data?["slots"]?[0]?["end"], "2026-10-19T15:00:00+01:00")
    }
    func testWeekendAndAllDayBusyEventsAreExcluded() async throws {
        let store = InMemoryEventStore.standard()
        await store.seed("Away", at("2026-10-19T00:00:00+01:00"), at("2026-10-20T00:00:00+01:00"), allDay: true)
        let registry = ToolRegistry(integrations: [CalendarIntegration(store: store)])
        for (start, end) in [("2026-10-17", "2026-10-19"), ("2026-10-19", "2026-10-20")] {
            let outcome = try await registry.run("calendar.find_free_slots", ["start": .string(start), "end": .string(end), "duration_minutes": 60])
            XCTAssertEqual(outcome.output?.data?["count"], 0)
        }
    }
    func testOverlapDetectionIncludesVerifiedEventIDs() async throws {
        let store = InMemoryEventStore.standard()
        await store.seed("Class", at("2026-10-19T09:00:00+01:00"), at("2026-10-19T11:00:00+01:00"))
        await store.seed("Meeting", at("2026-10-19T10:00:00+01:00"), at("2026-10-19T12:00:00+01:00"), calendarID: "C-work")
        let outcome = try await ToolRegistry(integrations: [CalendarIntegration(store: store)]).run("calendar.find_overlaps", ["start": "2026-10-19", "end": "2026-10-20"])
        XCTAssertEqual(outcome.output?.data?["overlaps"]?.arrayValue?.count, 1)
        XCTAssertNotNil(outcome.output?.data?["overlaps"]?[0]?["first"]?["id"])
    }
}
