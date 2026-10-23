import XCTest
import JarvisCore
@testable import JarvisIntegrations

/// "Now" in these tests is Saturday 17 Oct 2026, 13:08 BST (Europe/London); clocks go back on Sunday 25 Oct.
final class CalendarIntegrationTests: XCTestCase {
    private let london = TimeZone(identifier: "Europe/London")!
    private var store = InMemoryEventStore.standard()
    private let contacts = FakeContacts()

    private func registry(withContacts: Bool = false) -> ToolRegistry {
        ToolRegistry(integrations: [CalendarIntegration(store: store, contacts: withContacts ? contacts : nil)])
    }

    private func at(_ text: String) -> Date { ISODates.date(from: text, timeZone: london)! }

    private func settings(_ configure: (inout JarvisSettings) -> Void) -> JarvisSettings {
        var value = JarvisSettings()
        configure(&value)
        return value
    }

    // MARK: Listing

    func testListEventsGroupedByDay() async throws {
        await store.seed("Standup", at("2026-10-18T09:00:00+01:00"), at("2026-10-18T09:15:00+01:00"))
        await store.seed("Dentist", at("2026-10-18T15:00:00+01:00"), at("2026-10-18T16:00:00+01:00"), calendarID: "C-work")
        await store.seed("Mom's birthday", at("2026-10-19T00:00:00+01:00"), at("2026-10-20T00:00:00+01:00"), allDay: true)
        await store.seed("Out of range", at("2026-10-25T09:00:00+00:00"), at("2026-10-25T10:00:00+00:00"))

        let outcome = try await registry().run(.calendarListEvents, ["start": "2026-10-18T00:00:00+01:00", "end": "2026-10-20T00:00:00+01:00"])
        let output = try XCTUnwrap(outcome.output)
        XCTAssertEqual(output.data?["count"], 3)
        XCTAssertTrue(output.message.contains("Standup"))
        XCTAssertTrue(output.message.contains("Dentist (Work)"))
        XCTAssertTrue(output.message.contains("All day"))
        XCTAssertFalse(output.message.contains("Out of range"))
        XCTAssertTrue(output.message.hasPrefix("3 events"))
    }

    func testEmptyRangesSaySo() async throws {
        let outcome = try await registry().run(.calendarListEvents, ["start": "2026-10-18T00:00:00+01:00", "end": "2026-10-19T00:00:00+01:00"])
        XCTAssertEqual(outcome.output?.message, "Nothing scheduled for that period.")
    }

    func testBackwardsRangesAreRejected() async throws {
        do {
            _ = try await registry().run(.calendarListEvents, ["start": "2026-10-19T00:00:00+01:00", "end": "2026-10-18T00:00:00+01:00"])
            XCTFail("should have thrown")
        } catch JarvisError.invalidArgument {}
    }

    func testListCalendarsShowsReadOnlyOnes() async throws {
        let outcome = try await registry().run(.calendarListCalendars, [:])
        let message = try XCTUnwrap(outcome.output).message
        XCTAssertTrue(message.contains("UK Holidays — Subscribed · read-only"))
        XCTAssertTrue(message.contains("Home — iCloud · default"))
    }

    func testFilterByCalendarAndUnknownCalendar() async throws {
        await store.seed("Standup", at("2026-10-18T09:00:00+01:00"), at("2026-10-18T09:15:00+01:00"))
        await store.seed("Dentist", at("2026-10-18T15:00:00+01:00"), at("2026-10-18T16:00:00+01:00"), calendarID: "C-work")
        let work = try await registry().run(.calendarListEvents, ["start": "2026-10-18T00:00:00+01:00", "end": "2026-10-19T00:00:00+01:00", "calendar": "work"])
        XCTAssertEqual(work.output?.data?["count"], 1)
        do {
            _ = try await registry().run(.calendarListEvents, ["start": "2026-10-18T00:00:00+01:00", "end": "2026-10-19T00:00:00+01:00", "calendar": "Nope"])
            XCTFail("should have thrown")
        } catch JarvisError.notFound(let code, _) {
            XCTAssertEqual(code, "calendar_not_found")
        }
    }

    // MARK: Create

    func testScheduleMeetingWithDanielForOneHour() async throws {
        let outcome = try await registry().run(.calendarCreateEvent, [
            "title": "Meeting with Daniel", "start": "2026-10-23T15:00:00+01:00", "duration_minutes": 60, "attendees": ["Daniel"],
        ])
        let output = try XCTUnwrap(outcome.output)
        XCTAssertEqual(output.data?["title"], "Meeting with Daniel")
        XCTAssertEqual(output.data?["start"], "2026-10-23T15:00:00+01:00")
        XCTAssertEqual(output.data?["end"], "2026-10-23T16:00:00+01:00")
        XCTAssertEqual(output.data?["calendar"], "Home")
        XCTAssertEqual(output.data?["created"], true)
        XCTAssertTrue(output.verification.isVerified)
        XCTAssertTrue(output.warnings.contains { $0.contains("Invitations are not sent") }, "honest about EventKit's limitation")
        let events = try await store.events(from: at("2026-10-23T00:00:00+01:00"), to: at("2026-10-24T00:00:00+01:00"), calendarIDs: nil)
        XCTAssertEqual(events.count, 1)
    }

    func testDefaultDurationComesFromSettings() async throws {
        let outcome = try await registry().run(.calendarCreateEvent, ["title": "Call", "start": "2026-10-23T15:00:00+01:00"], context: executionContext(settings: settings { $0.defaultEventDurationMinutes = 45 }))
        XCTAssertEqual(outcome.output?.data?["end"], "2026-10-23T15:45:00+01:00")
    }

    func testExplicitEndAndDuration() async throws {
        let ranged = try await registry().run(.calendarCreateEvent, ["title": "Workshop", "start": "2026-10-23T10:00:00+01:00", "end": "2026-10-23T12:30:00+01:00"])
        XCTAssertEqual(ranged.output?.data?["end"], "2026-10-23T12:30:00+01:00")
        do {
            _ = try await registry().run(.calendarCreateEvent, ["title": "x", "start": "2026-10-23T10:00:00+01:00", "end": "2026-10-23T12:00:00+01:00", "duration_minutes": 30])
            XCTFail("end and duration are mutually exclusive")
        } catch JarvisError.validation {}
        do {
            _ = try await registry().run(.calendarCreateEvent, ["title": "x", "start": "2026-10-23T10:00:00+01:00", "end": "2026-10-23T09:00:00+01:00"])
            XCTFail("end before start")
        } catch JarvisError.invalidArgument {}
    }

    func testADateWithoutATimeCreatesAnAllDayEvent() async throws {
        let outcome = try await registry().run(.calendarCreateEvent, ["title": "Mom's birthday", "start": "2027-06-05"])
        XCTAssertEqual(outcome.output?.data?["all_day"], true)
        XCTAssertEqual(outcome.output?.data?["start"], "2027-06-05")
        XCTAssertEqual(outcome.output?.data?["end"], "2027-06-06")
    }

    func testLocationNotesAndDestinationCalendar() async throws {
        let outcome = try await registry().run(.calendarCreateEvent, [
            "title": "Lunch", "start": "2026-10-23T13:00:00+01:00", "location": "Starbucks", "notes": "Bring the contract", "calendar": "Work",
        ])
        XCTAssertEqual(outcome.output?.data?["calendar"], "Work")
        XCTAssertEqual(outcome.output?.data?["location"], "Starbucks")
        XCTAssertTrue(try XCTUnwrap(outcome.output).message.contains("at Starbucks"))
    }

    func testCalendarsThatCannotBeWrittenToAreNotOffered() async throws {
        do {
            _ = try await registry().run(.calendarCreateEvent, ["title": "x", "start": "2026-10-23T13:00:00+01:00", "calendar": "UK Holidays"])
            XCTFail("should have thrown")
        } catch JarvisError.notFound(let code, _) {
            XCTAssertEqual(code, "calendar_not_found")
        }
    }

    func testDuplicateCalendarNamesAsk() async throws {
        await store.setCalendars([
            CalendarInfo(id: "A", title: "Work", sourceName: "iCloud", sourceType: "icloud", allowsModifications: true, isSubscribed: false, isDefault: true),
            CalendarInfo(id: "B", title: "Work", sourceName: "Exchange", sourceType: "exchange", allowsModifications: true, isSubscribed: false, isDefault: false),
        ])
        let outcome = try await registry().run(.calendarCreateEvent, ["title": "x", "start": "2026-10-23T13:00:00+01:00", "calendar": "Work"])
        XCTAssertEqual(outcome.clarification?.options.map(\.detail), ["iCloud", "Exchange"])
    }

    func testAnIdenticalEventIsNotDuplicated() async throws {
        await store.seed("Meeting with Daniel", at("2026-10-23T15:00:00+01:00"), at("2026-10-23T16:00:00+01:00"))
        let outcome = try await registry().run(.calendarCreateEvent, ["title": "meeting with daniel", "start": "2026-10-23T15:00:00+01:00", "duration_minutes": 60])
        XCTAssertEqual(outcome.output?.data?["created"], false)
        let count = await store.createCalls
        XCTAssertEqual(count, 0)
    }

    func testVerificationCatchesAnEventSavedWithTheWrongTime() async throws {
        await store.setCorrupt { var copy = $0; copy.start = copy.start.addingTimeInterval(3600); return copy }
        do {
            _ = try await registry().run(.calendarCreateEvent, ["title": "x", "start": "2026-10-23T15:00:00+01:00"])
            XCTFail("should have thrown")
        } catch JarvisError.verificationFailed {}
    }

    // MARK: Conflicts

    func testOverlapsAskBeforeCreating() async throws {
        await store.seed("Dentist", at("2026-10-23T15:30:00+01:00"), at("2026-10-23T16:30:00+01:00"))
        let first = try await registry().run(.calendarCreateEvent, ["title": "Meeting", "start": "2026-10-23T15:00:00+01:00", "duration_minutes": 60])
        let confirmation = try XCTUnwrap(first.confirmation)
        XCTAssertFalse(confirmation.destructive)
        XCTAssertTrue(confirmation.prompt.contains("Dentist"))
        let before = await store.createCalls
        XCTAssertEqual(before, 0)

        let confirmed = try await registry().run(.calendarCreateEvent, confirmation.call.arguments, context: executionContext(confirmed: true))
        XCTAssertEqual(confirmed.output?.data?["created"], true)
        XCTAssertTrue(try XCTUnwrap(confirmed.output).warnings.contains { $0.contains("Dentist") })
    }

    func testWarnPolicyCreatesAndMentionsTheOverlap() async throws {
        await store.seed("Dentist", at("2026-10-23T15:30:00+01:00"), at("2026-10-23T16:30:00+01:00"))
        let outcome = try await registry().run(.calendarCreateEvent, ["title": "Meeting", "start": "2026-10-23T15:00:00+01:00", "duration_minutes": 60], context: executionContext(settings: settings { $0.conflictPolicy = .warn }))
        XCTAssertEqual(outcome.output?.data?["created"], true)
        XCTAssertTrue(try XCTUnwrap(outcome.output).warnings.contains { $0.contains("Dentist") })
    }

    func testBackToBackEventsAndAllDayEventsAreNotConflicts() async throws {
        await store.seed("Earlier", at("2026-10-23T14:00:00+01:00"), at("2026-10-23T15:00:00+01:00"))
        await store.seed("Holiday", at("2026-10-23T00:00:00+01:00"), at("2026-10-24T00:00:00+01:00"), allDay: true)
        await store.seed("Declined", at("2026-10-23T15:00:00+01:00"), at("2026-10-23T16:00:00+01:00"), declined: true)
        await store.seed("Free time", at("2026-10-23T15:00:00+01:00"), at("2026-10-23T16:00:00+01:00"), busy: false)
        let outcome = try await registry().run(.calendarCreateEvent, ["title": "Meeting", "start": "2026-10-23T15:00:00+01:00", "duration_minutes": 60])
        XCTAssertEqual(outcome.output?.data?["created"], true)
    }

    func testCheckConflictsReportsFreeAndBusy() async throws {
        await store.seed("Dentist", at("2026-10-23T15:30:00+01:00"), at("2026-10-23T16:30:00+01:00"))
        let busy = try await registry().run(.calendarCheckConflicts, ["start": "2026-10-23T15:00:00+01:00", "end": "2026-10-23T16:00:00+01:00"])
        XCTAssertEqual(busy.output?.data?["free"], false)
        XCTAssertTrue(try XCTUnwrap(busy.output).message.contains("You're busy"))
        let free = try await registry().run(.calendarCheckConflicts, ["start": "2026-10-23T17:00:00+01:00", "end": "2026-10-23T18:00:00+01:00"])
        XCTAssertEqual(free.output?.data?["free"], true)
        XCTAssertTrue(try XCTUnwrap(free.output).message.contains("You're free"))
    }

    // MARK: Contacts

    func testContactLookupEnrichesTheEventNotesWhenEnabledAndAuthorized() async throws {
        await contacts.add(ContactMatch(id: "c1", fullName: "Daniel Smith", emails: ["daniel@example.com"], phones: [], organization: "Acme"))
        let enabled = settings { $0.contactLookupEnabled = true }
        let outcome = try await registry(withContacts: true).run(.calendarCreateEvent, ["title": "Meeting with Daniel", "start": "2026-10-23T15:00:00+01:00", "attendees": ["Daniel"]], context: executionContext(settings: enabled))
        let events = try await store.events(from: at("2026-10-23T00:00:00+01:00"), to: at("2026-10-24T00:00:00+01:00"), calendarIDs: nil)
        let notes = try XCTUnwrap(events.first?.notes)
        XCTAssertTrue(notes.contains("Daniel Smith <daniel@example.com>"))
        XCTAssertEqual(outcome.output?.data?["people"]?[0]?["name"], "Daniel Smith")
    }

    func testContactsAreNotTouchedWhenTheSettingIsOff() async throws {
        await contacts.add(ContactMatch(id: "c1", fullName: "Daniel Smith", emails: ["daniel@example.com"], phones: [], organization: ""))
        _ = try await registry(withContacts: true).run(.calendarCreateEvent, ["title": "Meeting with Daniel", "start": "2026-10-23T15:00:00+01:00", "attendees": ["Daniel"]])
        let queries = await contacts.queries
        XCTAssertTrue(queries.isEmpty, "privacy: no lookup unless the user enabled it")
    }

    func testContactsAreNotTouchedWithoutPermission() async throws {
        await contacts.setAccess(.denied)
        _ = try await registry(withContacts: true).run(.calendarCreateEvent, ["title": "Meeting with Daniel", "start": "2026-10-23T15:00:00+01:00", "attendees": ["Daniel"]], context: executionContext(settings: settings { $0.contactLookupEnabled = true }))
        let queries = await contacts.queries
        XCTAssertTrue(queries.isEmpty)
    }

    // MARK: Update

    func testMoveMyFridayMeetingTo3PMKeepsDateAndDuration() async throws {
        await store.seed("Team meeting", at("2026-10-23T10:00:00+01:00"), at("2026-10-23T11:30:00+01:00"))
        await store.seed("Team meeting", at("2026-10-28T10:00:00+00:00"), at("2026-10-28T11:00:00+00:00"))
        let outcome = try await registry().run(.calendarUpdateEvent, ["title": "meeting", "on_date": "2026-10-23", "new_time": "15:00"])
        let output = try XCTUnwrap(outcome.output)
        XCTAssertEqual(output.data?["start"], "2026-10-23T15:00:00+01:00")
        XCTAssertEqual(output.data?["end"], "2026-10-23T16:30:00+01:00", "the 90-minute duration is preserved")
        XCTAssertTrue(output.verification.isVerified)
        let events = try await store.events(from: at("2026-10-28T00:00:00+00:00"), to: at("2026-10-29T00:00:00+00:00"), calendarIDs: nil)
        XCTAssertEqual(events.first?.start, at("2026-10-28T10:00:00+00:00"), "the other meeting was not touched")
    }

    func testAmbiguousMeetingsAreNeverModifiedSilently() async throws {
        await store.seed("Meeting with Daniel", at("2026-10-23T10:00:00+01:00"), at("2026-10-23T11:00:00+01:00"))
        await store.seed("Meeting with Maria", at("2026-10-23T13:00:00+01:00"), at("2026-10-23T14:00:00+01:00"))
        let outcome = try await registry().run(.calendarUpdateEvent, ["title": "meeting", "on_date": "2026-10-23", "new_time": "16:00"])
        let clarification = try XCTUnwrap(outcome.clarification)
        XCTAssertEqual(clarification.options.map(\.label), ["Meeting with Daniel", "Meeting with Maria"])
        let updates = await store.updateCalls
        XCTAssertEqual(updates, 0)

        // The chosen option pins the event id and keeps the requested change.
        let chosen = clarification.options[1].call
        XCTAssertEqual(chosen.arguments["new_time"], "16:00")
        XCTAssertNil(chosen.arguments["title"])
        let done = try await registry().run(.calendarUpdateEvent, chosen.arguments)
        XCTAssertEqual(done.output?.data?["title"], "Meeting with Maria")
        XCTAssertEqual(done.output?.data?["start"], "2026-10-23T16:00:00+01:00")
    }

    func testAtTimeDistinguishesEventsOnTheSameDay() async throws {
        await store.seed("Meeting with Daniel", at("2026-10-23T10:00:00+01:00"), at("2026-10-23T11:00:00+01:00"))
        await store.seed("Meeting with Maria", at("2026-10-23T13:00:00+01:00"), at("2026-10-23T14:00:00+01:00"))
        let outcome = try await registry().run(.calendarUpdateEvent, ["title": "meeting", "on_date": "2026-10-23", "at_time": "13:00", "new_title": "Meeting with Maria (moved)"])
        XCTAssertEqual(outcome.output?.data?["title"], "Meeting with Maria (moved)")
    }

    func testUpcomingRepeatingEventPicksTheNextOccurrence() async throws {
        await store.seed("Standup", at("2026-10-19T09:00:00+01:00"), at("2026-10-19T09:15:00+01:00"), recurring: true)
        await store.seed("Standup", at("2026-10-20T09:00:00+01:00"), at("2026-10-20T09:15:00+01:00"), recurring: true)
        let outcome = try await registry().run(.calendarUpdateEvent, ["title": "standup", "new_time": "10:00"])
        XCTAssertEqual(outcome.output?.data?["start"], "2026-10-19T10:00:00+01:00")
        XCTAssertTrue(try XCTUnwrap(outcome.output).warnings.contains { $0.contains("only this occurrence") })
    }

    func testMovingToANewDateAcrossTheClockChange() async throws {
        await store.seed("Lecture", at("2026-10-23T10:00:00+01:00"), at("2026-10-23T12:00:00+01:00"))
        let outcome = try await registry().run(.calendarUpdateEvent, ["title": "Lecture", "new_date": "2026-10-26"])
        // 10:00 on the 26th is GMT (+00:00); the wall-clock time and the 2 h duration are preserved.
        XCTAssertEqual(outcome.output?.data?["start"], "2026-10-26T10:00:00+00:00")
        XCTAssertEqual(outcome.output?.data?["end"], "2026-10-26T12:00:00+00:00")
    }

    func testExplicitNewStartAndDuration() async throws {
        await store.seed("Call", at("2026-10-23T10:00:00+01:00"), at("2026-10-23T10:30:00+01:00"))
        let outcome = try await registry().run(.calendarUpdateEvent, ["title": "Call", "new_start": "2026-10-24T11:00:00+01:00", "new_duration_minutes": 45])
        XCTAssertEqual(outcome.output?.data?["start"], "2026-10-24T11:00:00+01:00")
        XCTAssertEqual(outcome.output?.data?["end"], "2026-10-24T11:45:00+01:00")
    }

    func testRenameRelocateAndMoveToAnotherCalendar() async throws {
        await store.seed("Call", at("2026-10-23T10:00:00+01:00"), at("2026-10-23T10:30:00+01:00"))
        let outcome = try await registry().run(.calendarUpdateEvent, ["title": "Call", "new_title": "Project sync", "new_location": "Room 5", "new_calendar": "Work"])
        XCTAssertEqual(outcome.output?.data?["title"], "Project sync")
        XCTAssertEqual(outcome.output?.data?["location"], "Room 5")
        XCTAssertEqual(outcome.output?.data?["calendar"], "Work")
    }

    func testMovingOntoAnotherEventAsksFirst() async throws {
        await store.seed("Call", at("2026-10-23T10:00:00+01:00"), at("2026-10-23T11:00:00+01:00"))
        await store.seed("Dentist", at("2026-10-23T15:00:00+01:00"), at("2026-10-23T16:00:00+01:00"))
        let first = try await registry().run(.calendarUpdateEvent, ["title": "Call", "new_time": "15:30"])
        let confirmation = try XCTUnwrap(first.confirmation)
        XCTAssertTrue(confirmation.prompt.contains("Dentist"))
        let updates = await store.updateCalls
        XCTAssertEqual(updates, 0)
        let done = try await registry().run(.calendarUpdateEvent, confirmation.call.arguments, context: executionContext(confirmed: true))
        XCTAssertEqual(done.output?.data?["start"], "2026-10-23T15:30:00+01:00")
    }

    func testEventsInReadOnlyCalendarsCannotBeChangedOrDeleted() async throws {
        await store.seed("Bank Holiday", at("2026-10-26T00:00:00+00:00"), at("2026-10-27T00:00:00+00:00"), calendarID: "C-holidays", allDay: true)
        do {
            _ = try await registry().run(.calendarUpdateEvent, ["title": "Bank Holiday", "new_title": "Day off"])
            XCTFail("should have thrown")
        } catch JarvisError.notFound(let code, _) {
            XCTAssertEqual(code, "event_not_found", "read-only events are filtered out of change candidates")
        }
    }

    func testMissingEventSuggestsSimilarOnes() async throws {
        await store.seed("Dentist appointment", at("2026-10-23T15:00:00+01:00"), at("2026-10-23T16:00:00+01:00"))
        do {
            _ = try await registry().run(.calendarUpdateEvent, ["title": "Dentist checkup meeting", "new_time": "16:00"])
            XCTFail("should have thrown")
        } catch JarvisError.notFound(let code, let text) {
            XCTAssertEqual(code, "event_not_found")
            XCTAssertTrue(text.en.contains("Dentist appointment"))
        }
    }

    func testAllDayEventsNeedAFullStartToGainATime() async throws {
        await store.seed("Birthday", at("2026-10-23T00:00:00+01:00"), at("2026-10-24T00:00:00+01:00"), allDay: true)
        do {
            _ = try await registry().run(.calendarUpdateEvent, ["title": "Birthday", "new_time": "15:00"])
            XCTFail("should have thrown")
        } catch JarvisError.failed(let code, _) {
            XCTAssertEqual(code, "all_day_event")
        }
    }

    func testUpdateVerificationNoticesAChangeThatDidNotStick() async throws {
        await store.seed("Call", at("2026-10-23T10:00:00+01:00"), at("2026-10-23T10:30:00+01:00"))
        await store.setCorrupt { var copy = $0; copy.title = "Call"; return copy }
        do {
            _ = try await registry().run(.calendarUpdateEvent, ["title": "Call", "new_title": "Renamed"])
            XCTFail("should have thrown")
        } catch JarvisError.verificationFailed {}
    }

    // MARK: Delete

    func testDeleteAsksThenDeletesAndWarnsAboutAttendees() async throws {
        await store.seed("Meeting with Daniel", at("2026-10-23T10:00:00+01:00"), at("2026-10-23T11:00:00+01:00"), attendees: true)
        let first = try await registry().run(.calendarDeleteEvent, ["title": "meeting with daniel", "on_date": "2026-10-23"])
        let confirmation = try XCTUnwrap(first.confirmation)
        XCTAssertTrue(confirmation.destructive)
        let before = await store.deleteCalls
        XCTAssertEqual(before, 0)

        let done = try await registry().run(.calendarDeleteEvent, confirmation.call.arguments, context: executionContext(confirmed: true))
        XCTAssertTrue(try XCTUnwrap(done.output).verification.isVerified)
        XCTAssertTrue(try XCTUnwrap(done.output).warnings.contains { $0.contains("not notified") })
        let after = await store.deleteCalls
        XCTAssertEqual(after, 1)
    }

    func testDeletingARepeatingEventSaysOnlyOneOccurrenceGoes() async throws {
        await store.seed("Standup", at("2026-10-19T09:00:00+01:00"), at("2026-10-19T09:15:00+01:00"), recurring: true)
        let first = try await registry().run(.calendarDeleteEvent, ["title": "Standup"])
        XCTAssertTrue(try XCTUnwrap(first.confirmation).prompt.contains("Only this occurrence"))
    }

    // MARK: Permissions

    func testPermissionStatesIncludingWriteOnly() async throws {
        let integration = CalendarIntegration(store: store)
        let tool = try XCTUnwrap(integration.tools.first)

        await store.setAccess(.writeOnly)
        guard case .denied(let requirement) = await integration.authorization(for: tool) else { return XCTFail("write-only access cannot read events") }
        XCTAssertEqual(requirement.id, "calendars")
        let status = await integration.status()
        XCTAssertEqual(status.state, .denied)

        await store.setAccess(.authorized)
        let ready = await integration.status()
        XCTAssertEqual(ready.state, .ready)
    }

    func testUsingTheStoreWithoutAccessIsAPermissionError() async throws {
        await store.setAccess(.denied)
        do {
            _ = try await registry().run(.calendarListCalendars, [:])
            XCTFail("should have thrown")
        } catch JarvisError.permissionRequired(let requirement) {
            XCTAssertEqual(requirement.id, "calendars")
        }
    }

    func testEveryToolHasAnExampleThatValidates() throws {
        let registry = registry()
        for descriptor in registry.descriptors {
            for example in descriptor.examples {
                XCTAssertNoThrow(try registry.validate(ToolCall(tool: descriptor.name, arguments: example.arguments)), "\(descriptor.name): \(example.phrase)")
            }
        }
    }
}
