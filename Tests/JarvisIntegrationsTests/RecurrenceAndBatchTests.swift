import EventKit
import JarvisCore
import XCTest

@testable import JarvisIntegrations

final class RecurrenceAndBatchTests: XCTestCase {
    func testEventKitRecurrenceRoundtripPreservesIntervalWeekdaysAndCount() {
        let spec = RecurrenceSpecification(frequency: "weekly", interval: 2, weekdays: [1, 3, 5], count: 12)
        XCTAssertEqual(RecurrenceSpecification(rule: spec.rule), spec)
        XCTAssertEqual(spec.rule.frequency, .weekly)
        XCTAssertEqual(spec.rule.recurrenceEnd?.occurrenceCount, 12)
    }
    func testRecurringEventAndAlertEditsAreReadBack() async throws {
        let registry = ToolRegistry(integrations: [CalendarIntegration(store: InMemoryEventStore.standard())])
        let created = try await registry.run(
            .calendarCreateEvent,
            [
                "title": "Study", "start": "2026-10-27T10:00:00Z", "duration_minutes": 60, "recurrence": "weekly",
                "repeat_interval": 2, "repeat_weekdays": ["tue", "thu"], "repeat_count": 8, "alert_minutes": 15,
                "timezone": "Europe/London",
            ])
        XCTAssertEqual(created.output?.data?["recurrence"]?["interval"]?.intValue, 2)
        XCTAssertEqual(created.output?.data?["recurrence"]?["count"]?.intValue, 8)
        XCTAssertEqual(created.output?.data?["alert_minutes"]?[0]?.intValue, 15)
        let id = try XCTUnwrap(created.output?.data?["id"])
        let changed = try await registry.run(.calendarUpdateEvent, ["id": id, "new_alert_minutes": 30])
        XCTAssertEqual(changed.output?.data?["alert_minutes"]?[0]?.intValue, 30)
        let cleared = try await registry.run(.calendarUpdateEvent, ["id": id, "clear_alerts": true])
        XCTAssertEqual(cleared.output?.data?["alert_minutes"]?.arrayValue, [])
    }
    func testReminderRecurrenceUsesFullRuleAndDoesNotDeduplicateDifferentIntervals() async throws {
        let registry = ToolRegistry(integrations: [RemindersIntegration(store: InMemoryReminderStore.standard())])
        let args: JSONObject = [
            "title": "Stretch", "due": "2026-10-27T10:00:00Z", "recurrence": "weekly", "repeat_interval": 2,
            "repeat_weekdays": ["tue", "thu"], "repeat_count": 8,
        ]
        let first = try await registry.run(.remindersCreate, args)
        XCTAssertEqual(first.output?.data?["recurrence_details"]?["interval"]?.intValue, 2)
        let second = try await registry.run(.remindersCreate, args.merging(["repeat_interval": 3]) { _, v in v })
        XCTAssertNotEqual(first.output?.data?["id"], second.output?.data?["id"])
    }
    func testDuplicateCandidatesAndBatchDeletionRequireFreshSnapshot() async throws {
        let store = InMemoryReminderStore.standard()
        let registry = ToolRegistry(integrations: [RemindersIntegration(store: store)])
        let a = try await store.create(
            ReminderDraft(title: "Milk", notes: nil, listID: "L-shop", due: nil, priority: 0),
            calendar: executionContext().calendar)
        let b = try await store.create(
            ReminderDraft(title: "milk", notes: nil, listID: "L-shop", due: nil, priority: 0),
            calendar: executionContext().calendar)
        let duplicates = try await registry.run("reminders.find_duplicates", ["list_id": "L-shop"])
        XCTAssertEqual(duplicates.output?.data?["groups"]?.arrayValue?.count, 1)
        let review = try await registry.run("reminders.batch_delete", ["ids": [.string(a.id), .string(b.id)]])
        let confirmation = try XCTUnwrap(review.confirmation)
        let before = await store.deletedIDs
        XCTAssertTrue(before.isEmpty)
        var changes = ReminderChanges()
        changes.notes = "Keep this one"
        _ = try await store.update(id: b.id, changes: changes, calendar: executionContext().calendar)
        let changed = try await registry.run(
            "reminders.batch_delete", confirmation.call.arguments, context: executionContext(confirmed: true))
        XCTAssertNotNil(changed.confirmation)
        let still = await store.deletedIDs
        XCTAssertTrue(still.isEmpty)
    }
}
