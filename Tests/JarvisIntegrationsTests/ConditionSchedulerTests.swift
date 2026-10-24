import JarvisCore
import XCTest

@testable import JarvisIntegrations

private actor ConditionWeather: WeatherDataLoading {
    var requests = 0
    let probability: Double
    let fail: Bool
    init(probability: Double = 80, fail: Bool = false) {
        self.probability = probability
        self.fail = fail
    }
    func load(_ url: URL) async throws -> JSONValue {
        requests += 1
        if fail { throw URLError(.notConnectedToInternet) }
        if url.host?.hasPrefix("geocoding") == true {
            return [
                "results": [
                    [
                        "id": 1, "name": "London", "country": "United Kingdom", "latitude": 51.5, "longitude": -0.1,
                        "population": 9_000_000,
                    ]
                ]
            ]
        }
        return [
            "timezone": "Europe/London",
            "daily": [
                "time": ["2026-10-25"], "temperature_2m_min": [8], "temperature_2m_max": [14],
                "precipitation_probability_max": [.double(probability)],
            ],
        ]
    }
}
private actor ConditionNotifications: ConditionNotifying {
    var scheduled: Set<String> = []
    var calls = 0
    var authorized = true
    func allowed(request: Bool) async -> Bool { authorized }
    func contains(_ id: String) async -> Bool { scheduled.contains(id) }
    func schedule(id: String, title: String, body: String) async throws {
        scheduled.insert(id)
        calls += 1
    }
    func remove(_ id: String) async { scheduled.remove(id) }
}
final class ConditionSchedulerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_882_800)
    private func file() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "jarvis-conditions-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("conditions.json")
    }
    private func job(_ now: Date, threshold: Double = 50) -> WeatherConditionJob {
        WeatherConditionJob(
            id: UUID().uuidString, location: "London", placeID: 1, forecastDate: "2026-10-25", threshold: threshold,
            title: "Carry umbrella", checkAt: now, expires: now.addingTimeInterval(3600))
    }
    func testPersistedFutureCheckWaitsThenNotifiesOnceAcrossRestarts() async throws {
        let url = try file()
        let notifier = ConditionNotifications()
        let weather = WeatherIntegration(cache: WeatherCache(loader: ConditionWeather()))
        let first = ConditionJobStore(url: url, weather: weather, notifier: notifier)
        let value = job(now.addingTimeInterval(60))
        try await first.insert(value)
        await first.evaluate(now: now)
        var count = await notifier.calls
        XCTAssertEqual(count, 0)
        let restarted = ConditionJobStore(url: url, weather: weather, notifier: notifier)
        await restarted.evaluate(now: now.addingTimeInterval(60))
        await restarted.evaluate(now: now.addingTimeInterval(960))
        count = await notifier.calls
        XCTAssertEqual(count, 1)
        let jobs = try await restarted.all()
        XCTAssertEqual(jobs.first?.status, "notified")
        XCTAssertEqual(jobs.first?.rainProbability, 80)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testConditionNotMetExpiredAndCancelledNeverNotify() async throws {
        let notifier = ConditionNotifications()
        let store = ConditionJobStore(
            url: try file(),
            weather: WeatherIntegration(cache: WeatherCache(loader: ConditionWeather(probability: 10))),
            notifier: notifier)
        let unmet = job(now)
        let expired = job(now.addingTimeInterval(-7200))
        let cancelled = job(now)
        for value in [unmet, expired, cancelled] { try await store.insert(value) }
        try await store.cancel(cancelled.id)
        await store.evaluate(now: now)
        let jobs = try await store.all()
        let states = Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, $0.status) })
        XCTAssertEqual(states[unmet.id], "condition_not_met")
        XCTAssertEqual(states[expired.id], "expired")
        XCTAssertEqual(states[cancelled.id], "cancelled")
        let count = await notifier.calls
        XCTAssertEqual(count, 0)
    }
    func testOfflineFailureRemainsPendingWithBoundedRetryAndNoFabricatedWeather() async throws {
        let notifier = ConditionNotifications()
        let loader = ConditionWeather(fail: true)
        let store = ConditionJobStore(
            url: try file(), weather: WeatherIntegration(cache: WeatherCache(loader: loader)), notifier: notifier)
        try await store.insert(job(now))
        await store.evaluate(now: now)
        let jobs = try await store.all()
        XCTAssertEqual(jobs[0].status, "pending")
        XCTAssertNotNil(jobs[0].error)
        XCTAssertNil(jobs[0].rainProbability)
        await store.evaluate(now: now.addingTimeInterval(30))
        let requests = await loader.requests
        XCTAssertEqual(requests, 1)
        let count = await notifier.calls
        XCTAssertEqual(count, 0)
    }
    func testDisabledServiceRefusesToPromiseAFutureCheck() async throws {
        let integration = ConditionsIntegration(
            store: ConditionJobStore(url: try file()), enabled: { false }, notificationsAuthorized: { true })
        let registry = ToolRegistry(integrations: [integration])
        do {
            _ = try await registry.run(
                "conditions.schedule_rain",
                [
                    "location": "London", "place_id": 1, "forecast_date": "2026-10-25",
                    "check_at": "2026-10-25T07:00:00Z", "title": "Umbrella",
                ])
            XCTFail()
        } catch let error as JarvisError { XCTAssertEqual(error.code, "condition_agent_disabled") }
    }
    func testStopwatchPersistsLapsAndPausedElapsedTime() async throws {
        let url = try file()
        let registry = ToolRegistry(integrations: [StopwatchIntegration(store: StopwatchStore(url: url))])
        _ = try await registry.run("stopwatch.control", ["operation": "start"], context: executionContext(now: now))
        _ = try await registry.run(
            "stopwatch.control", ["operation": "lap"], context: executionContext(now: now.addingTimeInterval(30)))
        _ = try await registry.run(
            "stopwatch.control", ["operation": "pause"], context: executionContext(now: now.addingTimeInterval(60)))
        let restarted = ToolRegistry(integrations: [StopwatchIntegration(store: StopwatchStore(url: url))])
        let outcome = try await restarted.run(
            "stopwatch.control", ["operation": "status"], context: executionContext(now: now.addingTimeInterval(300)))
        XCTAssertEqual(outcome.output?.data?["elapsed_seconds"]?.doubleValue, 60)
        XCTAssertEqual(outcome.output?.data?["laps_seconds"]?[0]?.doubleValue, 30)
        let reset = try await restarted.run("stopwatch.control", ["operation": "reset"])
        XCTAssertNotNil(reset.confirmation)
    }
}
