import Foundation
import XCTest
import JarvisCore
@testable import JarvisIntegrations

private actor FakeTimerNotifications: TimerNotifying {
    var scheduled: [String: TimeInterval] = [:]
    var available = true
    var fail = false
    func authorized(request: Bool) async -> Bool { available }
    func schedule(id: String, title: String, seconds: TimeInterval) async throws {
        if fail { throw URLError(.cannotConnectToHost) }
        scheduled[id] = seconds
    }
    func remove(id: String) async { scheduled[id] = nil }
    func contains(id: String) async -> Bool { scheduled[id] != nil }
    func setFailure() { fail = true }
}

final class ManagedTimerTests: XCTestCase {
    private func file() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-timer-tests-" + UUID().uuidString).appendingPathComponent("timers.json") }
    private func registry(_ url: URL, _ notifier: FakeTimerNotifications) -> ToolRegistry {
        ToolRegistry(integrations: [ManagedTimersIntegration(store: ManagedTimerStore(url: url, notifier: notifier), notifier: notifier)])
    }
    func testPauseResumeExtendAndRestartUsePersistedDeadlines() async throws {
        let url = file(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let notifier = FakeTimerNotifications()
        let first = registry(url, notifier)
        let now = Date(timeIntervalSince1970: 1_792_238_880)
        let created = try await first.run("jarvis_timers.create", ["duration_seconds": 120, "label": "Kitchen"], context: executionContext(now: now))
        let id = try XCTUnwrap(created.output?.data?["id"]?.stringValue)
        XCTAssertEqual(created.output?.data?["backend"], "jarvis_notifications")
        let paused = try await first.run("jarvis_timers.pause", ["id": .string(id)], context: executionContext(now: now.addingTimeInterval(30)))
        XCTAssertEqual(paused.output?.data?["remaining_seconds"], 90)
        XCTAssertEqual(paused.output?.data?["paused"], true)
        let restarted = registry(url, notifier)
        let extended = try await restarted.run("jarvis_timers.extend", ["id": .string(id), "seconds": 30], context: executionContext(now: now.addingTimeInterval(60)))
        XCTAssertEqual(extended.output?.data?["remaining_seconds"], 120)
        let resumed = try await restarted.run("jarvis_timers.resume", ["id": .string(id)], context: executionContext(now: now.addingTimeInterval(100)))
        XCTAssertEqual(resumed.output?.data?["paused"], false)
        let stored = try await registry(url, notifier).run("jarvis_timers.list", [:], context: executionContext(now: now.addingTimeInterval(110)))
        XCTAssertEqual(stored.output?.data?["timers"]?[0]?["remaining_seconds"], 110)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testDuplicateLabelsAskAndCancellationRemovesNotification() async throws {
        let url = file(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let notifier = FakeTimerNotifications()
        let registry = registry(url, notifier)
        let first = try await registry.run("jarvis_timers.create", ["duration_seconds": 120, "label": "Kitchen"])
        _ = try await registry.run("jarvis_timers.create", ["duration_seconds": 60, "label": "Kitchen"])
        let ambiguous = try await registry.run("jarvis_timers.cancel", ["label": "Kitchen"])
        XCTAssertEqual(ambiguous.clarification?.options.count, 2)
        let id = try XCTUnwrap(first.output?.data?["id"]?.stringValue)
        _ = try await registry.run("jarvis_timers.cancel", ["id": .string(id)])
        let contains = await notifier.contains(id: id); XCTAssertFalse(contains)
        let count = try await registry.run("jarvis_timers.list", [:]).output?.data?["timers"]?.arrayValue?.count
        XCTAssertEqual(count, 1)
    }
    func testSchedulingFailureDoesNotReportOrSaveSuccessfulTimer() async throws {
        let url = file(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let notifier = FakeTimerNotifications(); await notifier.setFailure()
        let registry = registry(url, notifier)
        do { _ = try await registry.run("jarvis_timers.create", ["duration_seconds": 120]); XCTFail() } catch {}
        let list = try await registry.run("jarvis_timers.list", [:])
        XCTAssertEqual(list.output?.data?["timers"]?.arrayValue?.count, 0)
    }
    func testConcurrentCreatesDoNotLoseTimersAcrossActorSuspensions() async throws {
        let url = file(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let registry = registry(url, FakeTimerNotifications())
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<10 {
                group.addTask { _ = try await registry.run("jarvis_timers.create", ["duration_seconds": 120, "label": .string("Timer \(index)")]) }
            }
            try await group.waitForAll()
        }
        let list = try await registry.run("jarvis_timers.list", [:])
        XCTAssertEqual(list.output?.data?["timers"]?.arrayValue?.count, 10)
    }
}
