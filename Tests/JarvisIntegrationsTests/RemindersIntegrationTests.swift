import XCTest
import JarvisCore
@testable import JarvisIntegrations

/// "Now" in these tests is Saturday 17 Oct 2026, 13:08 BST (Europe/London).
final class RemindersIntegrationTests: XCTestCase {
    private var store = InMemoryReminderStore.standard()

    private func registry() -> ToolRegistry { ToolRegistry(integrations: [RemindersIntegration(store: store)]) }

    private func seed(_ title: String, list: String = "Reminders", listID: String = "L-rem", due: String? = nil, completed: Bool = false, id: String? = nil) async {
        let when = due.flatMap { ISODates.parse($0, timeZone: TimeZone(identifier: "Europe/London")!) }
        var date: Date?
        var hasTime = false
        switch when {
        case .dateTime(let value)?: date = value; hasTime = true
        case .date(let parts)?:
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/London")!
            date = calendar.date(from: DateComponents(year: parts.year, month: parts.month, day: parts.day))
        case nil: break
        }
        await store.seed(ReminderInfo(
            id: id ?? "seed-\(title)-\(listID)", title: title, notes: nil, listID: listID, listTitle: list, sourceName: "iCloud", isCompleted: completed,
            completionDate: nil, due: date, dueHasTime: hasTime, priority: 0, hasAlarm: hasTime, creationDate: nil
        ))
    }

    // MARK: Create

    func testAddBuyMilkToTheShoppingList() async throws {
        let outcome = try await registry().run(.remindersCreate, ["title": "Buy milk", "list": "Shopping"])
        let output = try XCTUnwrap(outcome.output)
        XCTAssertEqual(output.message, "Reminder created: “Buy milk” in Shopping.")
        XCTAssertEqual(output.data?["title"], "Buy milk")
        XCTAssertEqual(output.data?["list"], "Shopping")
        XCTAssertEqual(output.data?["created"], true)
        XCTAssertNotNil(output.data?["id"]?.stringValue, "real identifiers are returned")
        XCTAssertTrue(output.verification.isVerified)
        let count = await store.createCalls
        XCTAssertEqual(count, 1)
    }

    func testListMatchingIsForgivingAboutCaseAndWordsLikeList() async throws {
        let outcome = try await registry().run(.remindersCreate, ["title": "Eggs", "list": "shopping list"])
        XCTAssertEqual(outcome.output?.data?["list"], "Shopping")
    }

    func testDueDateTimeIsStoredWithAnAlarmAndVerified() async throws {
        let outcome = try await registry().run(.remindersCreate, ["title": "Submit my assignment", "due": "2026-10-18T18:00:00+01:00"])
        let output = try XCTUnwrap(outcome.output)
        XCTAssertEqual(output.data?["due"], "2026-10-18T18:00:00+01:00")
        XCTAssertEqual(output.data?["due_has_time"], true)
        XCTAssertEqual(output.data?["has_alarm"], true, "a timed reminder must actually notify")
        XCTAssertTrue(output.message.contains("Reminders") || output.message.contains("due"))
        XCTAssertTrue(output.message.contains("6:00"), output.message)
        XCTAssertEqual(output.data?["list"], "Reminders", "defaults to the default list")
    }

    func testDateOnlyDueHasNoTimeAndNoAlarm() async throws {
        let outcome = try await registry().run(.remindersCreate, ["title": "Pay rent", "due": "2026-10-19"])
        XCTAssertEqual(outcome.output?.data?["due"], "2026-10-19")
        XCTAssertEqual(outcome.output?.data?["due_has_time"], false)
        XCTAssertEqual(outcome.output?.data?["has_alarm"], false)
    }

    func testAPastDueTimeWarns() async throws {
        let outcome = try await registry().run(.remindersCreate, ["title": "Old", "due": "2026-10-17T09:00:00+01:00"])
        XCTAssertFalse(try XCTUnwrap(outcome.output).warnings.isEmpty)
    }

    func testMissingListAsksWhatToDoInsteadOfPuttingItSomewhereElse() async throws {
        let outcome = try await registry().run(.remindersCreate, ["title": "Buy flour", "list": "Baking"])
        let clarification = try XCTUnwrap(outcome.clarification)
        XCTAssertEqual(clarification.options.count, 2)
        XCTAssertTrue(clarification.options[0].label.contains("Create the list “Baking”"))
        XCTAssertTrue(clarification.options[1].label.contains("Reminders"))
        let count = await store.createCalls
        XCTAssertEqual(count, 0, "nothing is created until the user chooses")

        // Choosing "create the list" creates it, then the reminder.
        let created = try await registry().run(.remindersCreate, clarification.options[0].call.arguments)
        XCTAssertEqual(created.output?.data?["list"], "Baking")
        let lists = try await store.lists()
        XCTAssertTrue(lists.contains { $0.title == "Baking" })
    }

    func testChoosingTheDefaultListOption() async throws {
        let first = try await registry().run(.remindersCreate, ["title": "Buy flour", "list": "Baking"])
        let option = try XCTUnwrap(first.clarification?.options.last)
        let done = try await registry().run(.remindersCreate, option.call.arguments)
        XCTAssertEqual(done.output?.data?["list"], "Reminders")
    }

    func testTwoListsWithTheSameNameInDifferentAccountsAreNeverGuessed() async throws {
        await store.setLists([
            ReminderListInfo(id: "A", title: "Shopping", sourceID: "S1", sourceName: "iCloud", allowsModifications: true, isDefault: true),
            ReminderListInfo(id: "B", title: "Shopping", sourceID: "S2", sourceName: "Exchange", allowsModifications: true, isDefault: false),
        ])
        let outcome = try await registry().run(.remindersCreate, ["title": "Milk", "list": "Shopping"])
        let clarification = try XCTUnwrap(outcome.clarification)
        XCTAssertEqual(clarification.options.map(\.detail), ["iCloud", "Exchange"])
        let chosen = try await registry().run(.remindersCreate, clarification.options[1].call.arguments)
        XCTAssertEqual(chosen.output?.data?["list_id"], "B")
    }

    func testReadOnlyListsAreRefusedClearly() async throws {
        await store.setLists([ReminderListInfo(id: "RO", title: "Family", sourceID: "S", sourceName: "iCloud", allowsModifications: false, isDefault: false),
                              ReminderListInfo(id: "L", title: "Reminders", sourceID: "S", sourceName: "iCloud", allowsModifications: true, isDefault: true)])
        do {
            _ = try await registry().run(.remindersCreate, ["title": "x", "list": "Family"])
            XCTFail("should have thrown")
        } catch JarvisError.failed(let code, _) {
            XCTAssertEqual(code, "list_read_only")
        }
    }

    func testAnIdenticalPendingReminderIsNotDuplicated() async throws {
        await seed("Buy milk", list: "Shopping", listID: "L-shop")
        let outcome = try await registry().run(.remindersCreate, ["title": "buy MILK", "list": "Shopping"])
        let output = try XCTUnwrap(outcome.output)
        XCTAssertEqual(output.data?["created"], false)
        XCTAssertTrue(output.message.contains("already exists"))
        let count = await store.createCalls
        XCTAssertEqual(count, 0)
    }

    func testTheSameTitleWithADifferentDueDateIsANewReminder() async throws {
        await seed("Call Mom", due: "2026-10-18T10:00:00+01:00")
        let outcome = try await registry().run(.remindersCreate, ["title": "Call Mom", "due": "2026-10-19T10:00:00+01:00"])
        XCTAssertEqual(outcome.output?.data?["created"], true)
    }

    func testVerificationCatchesAReminderThatWasNotStoredAsRequested() async throws {
        await store.setCorrupt { var copy = $0; copy.title = "Something else"; return copy }
        do {
            _ = try await registry().run(.remindersCreate, ["title": "Buy milk"])
            XCTFail("should have thrown")
        } catch JarvisError.verificationFailed {}
    }

    func testSaveFailuresAreReportedNotSwallowed() async throws {
        await store.setFailNextSave(.saveFailed("disk full"))
        do {
            _ = try await registry().run(.remindersCreate, ["title": "x"])
            XCTFail("should have thrown")
        } catch JarvisError.failed(let code, let text) {
            XCTAssertEqual(code, "save_failed")
            XCTAssertTrue(text.en.contains("disk full"))
        }
    }

    // MARK: Listing

    func testPendingRemindersAreGroupedByListAndSortedByDueDate() async throws {
        await seed("Later", due: "2026-10-20T09:00:00+01:00")
        await seed("Sooner", due: "2026-10-18T09:00:00+01:00")
        await seed("No date")
        await seed("Milk", list: "Shopping", listID: "L-shop")
        await seed("Done thing", completed: true)
        let outcome = try await registry().run(.remindersList, [:])
        let output = try XCTUnwrap(outcome.output)
        XCTAssertEqual(output.data?["count"], 4)
        XCTAssertFalse(output.message.contains("Done thing"))
        let message = output.message
        XCTAssertLessThan(message.range(of: "Sooner")!.lowerBound, message.range(of: "Later")!.lowerBound)
        XCTAssertLessThan(message.range(of: "Later")!.lowerBound, message.range(of: "No date")!.lowerBound)
        XCTAssertTrue(message.contains("Shopping:"))
        XCTAssertTrue(message.hasPrefix("4 pending reminders"))
    }

    func testFiltersByStatusDateRangeAndList() async throws {
        await seed("Today thing", due: "2026-10-17T18:00:00+01:00")
        await seed("Tomorrow thing", due: "2026-10-18T09:00:00+01:00")
        await seed("Done thing", completed: true)
        await seed("Milk", list: "Shopping", listID: "L-shop")

        let tomorrow = try await registry().run(.remindersList, ["due_from": "2026-10-18T00:00:00+01:00", "due_to": "2026-10-19T00:00:00+01:00"])
        XCTAssertEqual(tomorrow.output?.data?["reminders"]?.arrayValue?.compactMap { $0["title"]?.stringValue }, ["Tomorrow thing"])

        let completed = try await registry().run(.remindersList, ["status": "completed"])
        XCTAssertEqual(completed.output?.data?["reminders"]?.arrayValue?.compactMap { $0["title"]?.stringValue }, ["Done thing"])

        let shopping = try await registry().run(.remindersList, ["list": "Shopping"])
        XCTAssertEqual(shopping.output?.data?["reminders"]?.arrayValue?.compactMap { $0["title"]?.stringValue }, ["Milk"])

        let all = try await registry().run(.remindersList, ["status": "all"])
        XCTAssertEqual(all.output?.data?["count"], 4)

        let search = try await registry().run(.remindersList, ["query": "MILK"])
        XCTAssertEqual(search.output?.data?["count"], 1)
    }

    func testEmptyListingsSaySo() async throws {
        let outcome = try await registry().run(.remindersList, [:])
        XCTAssertEqual(outcome.output?.message, "You have no pending reminders.")
        let spanish = try await registry().run(.remindersList, [:], context: executionContext(language: .es))
        XCTAssertEqual(spanish.output?.message, "No tienes recordatorios pendientes.")
    }

    func testUnknownListInAQueryIsAnError() async throws {
        do {
            _ = try await registry().run(.remindersList, ["list": "Nope"])
            XCTFail("should have thrown")
        } catch JarvisError.notFound(let code, _) {
            XCTAssertEqual(code, "list_not_found")
        }
    }

    // MARK: Complete / update / delete

    func testCompleteByTitleAndReopen() async throws {
        await seed("Buy milk", list: "Shopping", listID: "L-shop")
        let done = try await registry().run(.remindersComplete, ["title": "buy milk"])
        XCTAssertEqual(done.output?.message, "Marked “Buy milk” as completed.")
        XCTAssertEqual(done.output?.data?["completed"], true)

        let again = try await registry().run(.remindersComplete, ["title": "Buy milk"])
        XCTAssertTrue(try XCTUnwrap(again.output).message.contains("already completed"))

        let reopened = try await registry().run(.remindersComplete, ["title": "Buy milk", "completed": false])
        XCTAssertEqual(reopened.output?.message, "Reopened “Buy milk”.")
    }

    func testCompletingSomethingAmbiguousAsksWhichOne() async throws {
        await seed("Call Mom", list: "Reminders", listID: "L-rem", due: "2026-10-18T10:00:00+01:00", id: "r1")
        await seed("Call Mom", list: "Work", listID: "L-work", id: "r2")
        let outcome = try await registry().run(.remindersComplete, ["title": "Call Mom"])
        let clarification = try XCTUnwrap(outcome.clarification)
        XCTAssertEqual(clarification.options.map { $0.call.arguments["id"] }, ["r1", "r2"])
        XCTAssertTrue(clarification.options[0].detail?.contains("Reminders") == true)
        let reminders = try await store.reminders(in: nil, calendar: Calendar(identifier: .gregorian))
        XCTAssertTrue(reminders.allSatisfy { !$0.isCompleted }, "nothing completed before the user chooses")

        let chosen = try await registry().run(.remindersComplete, clarification.options[1].call.arguments)
        XCTAssertEqual(chosen.output?.data?["id"], "r2")
    }

    func testListNarrowsTheSearch() async throws {
        await seed("Call Mom", list: "Reminders", listID: "L-rem", id: "r1")
        await seed("Call Mom", list: "Work", listID: "L-work", id: "r2")
        let outcome = try await registry().run(.remindersComplete, ["title": "Call Mom", "list": "Work"])
        XCTAssertEqual(outcome.output?.data?["id"], "r2")
    }

    func testMissingReminderSuggestsSimilarOnes() async throws {
        await seed("Buy bread", list: "Shopping", listID: "L-shop")
        do {
            _ = try await registry().run(.remindersComplete, ["title": "Buy butter"])
            XCTFail("should have thrown")
        } catch JarvisError.notFound(let code, let text) {
            XCTAssertEqual(code, "reminder_not_found")
            XCTAssertTrue(text.en.contains("Buy bread"))
        }
    }

    func testRescheduleRenameAndMoveToAnotherList() async throws {
        await seed("Call Mom", due: "2026-10-18T10:00:00+01:00", id: "r1")
        let rescheduled = try await registry().run(.remindersUpdate, ["id": "r1", "new_due": "2026-10-19T17:00:00+01:00"])
        XCTAssertEqual(rescheduled.output?.data?["due"], "2026-10-19T17:00:00+01:00")

        let renamed = try await registry().run(.remindersUpdate, ["id": "r1", "new_title": "Call Grandma"])
        XCTAssertEqual(renamed.output?.data?["title"], "Call Grandma")

        let moved = try await registry().run(.remindersUpdate, ["id": "r1", "new_list": "Work"])
        XCTAssertEqual(moved.output?.data?["list"], "Work")

        let cleared = try await registry().run(.remindersUpdate, ["id": "r1", "clear_due": true])
        XCTAssertNil(cleared.output?.data?["due"])
    }

    func testUpdateNeedsAtLeastOneChange() async throws {
        do {
            _ = try await registry().run(.remindersUpdate, ["id": "r1"])
            XCTFail("should have thrown")
        } catch JarvisError.validation {}
    }

    func testUpdateVerificationNoticesAnIgnoredChange() async throws {
        await seed("Call Mom", id: "r1")
        await store.setCorrupt { var copy = $0; copy.title = "Call Mom"; return copy }
        do {
            _ = try await registry().run(.remindersUpdate, ["id": "r1", "new_title": "Call Grandma"])
            XCTFail("should have thrown")
        } catch JarvisError.verificationFailed {}
    }

    func testDeleteAsksFirstThenDeletesAndVerifies() async throws {
        await seed("Call Mom", id: "r1")
        let first = try await registry().run(.remindersDelete, ["title": "Call Mom"])
        let confirmation = try XCTUnwrap(first.confirmation)
        XCTAssertTrue(confirmation.destructive)
        XCTAssertTrue(confirmation.prompt.contains("cannot be undone"))
        let beforeDeleted = await store.deletedIDs
        XCTAssertTrue(beforeDeleted.isEmpty)

        let done = try await registry().run(.remindersDelete, confirmation.call.arguments, context: executionContext(confirmed: true))
        XCTAssertTrue(try XCTUnwrap(done.output).verification.isVerified)
        let afterDeleted = await store.deletedIDs
        XCTAssertEqual(afterDeleted, ["r1"])
    }

    // MARK: Lists

    func testListsAreCountedAndCreated() async throws {
        await seed("A", list: "Shopping", listID: "L-shop")
        await seed("B", list: "Shopping", listID: "L-shop")
        let lists = try await registry().run(.remindersListLists, [:])
        XCTAssertTrue(try XCTUnwrap(lists.output).message.contains("Shopping — 2 pending (iCloud)"))

        let created = try await registry().run(.remindersCreateList, ["name": "Groceries"])
        XCTAssertEqual(created.output?.data?["created"], true)
        XCTAssertTrue(created.output!.verification.isVerified)

        let again = try await registry().run(.remindersCreateList, ["name": "groceries"])
        XCTAssertEqual(again.output?.data?["created"], false, "no duplicate list")
    }

    // MARK: Permissions

    func testPermissionStates() async throws {
        let integration = RemindersIntegration(store: store)
        let tool = try XCTUnwrap(integration.tools.first)

        await store.setAccess(.notDetermined)
        guard case .notDetermined(let requirement) = await integration.authorization(for: tool) else { return XCTFail("expected notDetermined") }
        XCTAssertEqual(requirement.id, "reminders")
        XCTAssertEqual(requirement.settingsURL, "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")

        await store.setAccess(.denied)
        guard case .denied = await integration.authorization(for: tool) else { return XCTFail("expected denied") }
        await store.setAccess(.restricted)
        guard case .restricted = await integration.authorization(for: tool) else { return XCTFail("expected restricted") }

        await store.setAccess(.notDetermined)
        let granted = await integration.requestAuthorization(for: tool)
        XCTAssertTrue(granted.isAuthorized)
        let status = await integration.status()
        XCTAssertEqual(status.state, .ready)
    }

    func testUsingTheStoreWithoutAccessIsAPermissionError() async throws {
        await store.setAccess(.denied)
        do {
            _ = try await registry().run(.remindersList, [:])
            XCTFail("should have thrown")
        } catch JarvisError.permissionRequired(let requirement) {
            XCTAssertEqual(requirement.id, "reminders")
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
