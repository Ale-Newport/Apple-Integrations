import Foundation
import JarvisCore

@testable import JarvisIntegrations

/// An in-memory stand-in for Reminders with the same observable behaviour as EventKit (ids, lists, completion).
actor InMemoryReminderStore: ReminderStoring {
    var accessState: EventKitAccess = .authorized
    var accessAfterRequest: EventKitAccess = .authorized
    var listData: [ReminderListInfo]
    var reminderData: [ReminderInfo] = []
    var failNextSaveWith: EventKitFailure?
    private(set) var createCalls = 0
    private(set) var deletedIDs: [String] = []
    private var counter = 0
    /// When set, `reminder(id:)` returns what the store "really" saved instead of what was requested.
    var corrupt: (@Sendable (ReminderInfo) -> ReminderInfo)?

    init(lists: [ReminderListInfo]) { listData = lists }

    static func standard() -> InMemoryReminderStore {
        InMemoryReminderStore(lists: [
            ReminderListInfo(
                id: "L-rem", title: "Reminders", sourceID: "S-icloud", sourceName: "iCloud", allowsModifications: true,
                isDefault: true),
            ReminderListInfo(
                id: "L-shop", title: "Shopping", sourceID: "S-icloud", sourceName: "iCloud", allowsModifications: true,
                isDefault: false),
            ReminderListInfo(
                id: "L-work", title: "Work", sourceID: "S-exchange", sourceName: "Exchange", allowsModifications: true,
                isDefault: false),
        ])
    }

    func setAccess(_ value: EventKitAccess) { accessState = value }
    func setCorrupt(_ value: (@Sendable (ReminderInfo) -> ReminderInfo)?) { corrupt = value }
    func setFailNextSave(_ value: EventKitFailure?) { failNextSaveWith = value }
    func seed(_ reminder: ReminderInfo) { reminderData.append(reminder) }
    func setLists(_ lists: [ReminderListInfo]) { listData = lists }

    func access() async -> EventKitAccess { accessState }
    func requestAccess() async throws -> EventKitAccess {
        accessState = accessAfterRequest
        return accessState
    }
    func lists() async throws -> [ReminderListInfo] {
        try guardAccess()
        return listData
    }

    func createList(title: String, preferredSourceID: String?) async throws -> ReminderListInfo {
        try guardAccess()
        counter += 1
        let list = ReminderListInfo(
            id: "L-new\(counter)", title: title, sourceID: preferredSourceID ?? "S-icloud", sourceName: "iCloud",
            allowsModifications: true, isDefault: false)
        listData.append(list)
        return list
    }

    func renameList(id: String, title: String) async throws {
        try guardAccess()
        guard let index = listData.firstIndex(where: { $0.id == id }) else { throw EventKitFailure.notFound }
        guard listData[index].allowsModifications else { throw EventKitFailure.readOnly(listData[index].title) }
        listData[index].title = title
    }
    func deleteList(id: String) async throws {
        try guardAccess()
        guard let list = listData.first(where: { $0.id == id }) else { throw EventKitFailure.notFound }
        guard list.allowsModifications else { throw EventKitFailure.readOnly(list.title) }
        listData.removeAll { $0.id == id }
        reminderData.removeAll { $0.listID == id }
    }

    func reminders(in listIDs: [String]?, calendar: Calendar) async throws -> [ReminderInfo] {
        try guardAccess()
        return reminderData.filter { listIDs?.contains($0.listID) ?? true }
    }

    func reminder(id: String, calendar: Calendar) async throws -> ReminderInfo? {
        try guardAccess()
        guard let found = reminderData.first(where: { $0.id == id }) else { return nil }
        return corrupt?(found) ?? found
    }

    func create(_ draft: ReminderDraft, calendar: Calendar) async throws -> ReminderInfo {
        try guardAccess()
        if let failure = failNextSaveWith {
            failNextSaveWith = nil
            throw failure
        }
        guard let list = listData.first(where: { $0.id == draft.listID }) else { throw EventKitFailure.notFound }
        guard list.allowsModifications else { throw EventKitFailure.readOnly(list.title) }
        counter += 1
        createCalls += 1
        var reminder = ReminderInfo(
            id: "R\(counter)", title: draft.title, notes: draft.notes, listID: list.id, listTitle: list.title,
            sourceName: list.sourceName,
            isCompleted: false, completionDate: nil, due: nil, dueHasTime: false, priority: draft.priority,
            hasAlarm: false, creationDate: Date()
        )
        reminder.recurrence = draft.recurrence
        reminder.recurrenceDetails = draft.recurrenceDetails
        Self.apply(draft.due, to: &reminder, calendar: calendar)
        reminderData.append(reminder)
        return reminder
    }

    func update(id: String, changes: ReminderChanges, calendar: Calendar) async throws -> ReminderInfo {
        try guardAccess()
        guard let index = reminderData.firstIndex(where: { $0.id == id }) else { throw EventKitFailure.notFound }
        if let title = changes.title { reminderData[index].title = title }
        if let notes = changes.notes { reminderData[index].notes = notes }
        if let priority = changes.priority { reminderData[index].priority = priority }
        if let recurrence = changes.recurrence {
            reminderData[index].recurrence = recurrence == "none" ? nil : recurrence
            reminderData[index].recurrenceDetails = changes.recurrenceDetails
        }
        if let completed = changes.completed {
            reminderData[index].isCompleted = completed
            reminderData[index].completionDate = completed ? Date() : nil
        }
        if changes.clearDue {
            reminderData[index].due = nil
            reminderData[index].dueHasTime = false
            reminderData[index].hasAlarm = false
        } else if let due = changes.due {
            Self.apply(due, to: &reminderData[index], calendar: calendar)
        }
        if let listID = changes.listID, let list = listData.first(where: { $0.id == listID }) {
            reminderData[index].listID = list.id
            reminderData[index].listTitle = list.title
            reminderData[index].sourceName = list.sourceName
        }
        return reminderData[index]
    }

    func delete(id: String) async throws {
        try guardAccess()
        guard reminderData.contains(where: { $0.id == id }) else { throw EventKitFailure.notFound }
        reminderData.removeAll { $0.id == id }
        deletedIDs.append(id)
    }

    private func guardAccess() throws { guard accessState == .authorized else { throw EventKitFailure.notAuthorized } }

    private static func apply(_ due: DueSpec?, to reminder: inout ReminderInfo, calendar: Calendar) {
        guard let due else { return }
        switch due {
        case .date(let year, let month, let day):
            reminder.due = calendar.date(from: DateComponents(year: year, month: month, day: day))
            reminder.dueHasTime = false
        case .dateTime(let date):
            reminder.due = date
            reminder.dueHasTime = true
            reminder.hasAlarm = true
        }
    }
}

/// An in-memory Calendar. Event ids embed the start time, exactly like the real backend.
actor InMemoryEventStore: EventStoring {
    var accessState: EventKitAccess = .authorized
    var calendarData: [CalendarInfo]
    var eventData: [EventInfo] = []
    private var counter = 0
    private(set) var createCalls = 0
    private(set) var updateCalls = 0
    private(set) var deleteCalls = 0
    var corrupt: (@Sendable (EventInfo) -> EventInfo)?

    init(calendars: [CalendarInfo]) { calendarData = calendars }

    static func standard() -> InMemoryEventStore {
        InMemoryEventStore(calendars: [
            CalendarInfo(
                id: "C-home", title: "Home", sourceName: "iCloud", sourceType: "icloud", allowsModifications: true,
                isSubscribed: false, isDefault: true),
            CalendarInfo(
                id: "C-work", title: "Work", sourceName: "Exchange", sourceType: "exchange", allowsModifications: true,
                isSubscribed: false, isDefault: false),
            CalendarInfo(
                id: "C-holidays", title: "UK Holidays", sourceName: "Subscribed", sourceType: "subscribed",
                allowsModifications: false, isSubscribed: true, isDefault: false),
        ])
    }

    func setAccess(_ value: EventKitAccess) { accessState = value }
    func setCorrupt(_ value: (@Sendable (EventInfo) -> EventInfo)?) { corrupt = value }
    func setCalendars(_ value: [CalendarInfo]) { calendarData = value }

    @discardableResult
    func seed(
        _ title: String, _ start: Date, _ end: Date, calendarID: String = "C-home", allDay: Bool = false,
        recurring: Bool = false, attendees: Bool = false, busy: Bool = true, declined: Bool = false,
        location: String? = nil
    ) -> EventInfo {
        counter += 1
        let calendar = calendarData.first { $0.id == calendarID }!
        let event = EventInfo(
            id: "E\(counter)|\(Int(start.timeIntervalSince1970))", title: title, start: start, end: end,
            isAllDay: allDay, location: location, notes: nil,
            calendarID: calendarID, calendarTitle: calendar.title, sourceName: calendar.sourceName,
            isRecurring: recurring, hasAttendees: attendees,
            isBusy: busy, isDeclined: declined, canModify: calendar.allowsModifications
        )
        eventData.append(event)
        return event
    }

    func access() async -> EventKitAccess { accessState }
    func requestAccess() async throws -> EventKitAccess { accessState }
    func calendars() async throws -> [CalendarInfo] {
        try guardAccess()
        return calendarData
    }

    func events(from start: Date, to end: Date, calendarIDs: [String]?) async throws -> [EventInfo] {
        try guardAccess()
        return eventData.filter { $0.start < end && $0.end > start && (calendarIDs?.contains($0.calendarID) ?? true) }
            .sorted { $0.start < $1.start }
    }

    func event(id: String) async throws -> EventInfo? {
        try guardAccess()
        guard let found = eventData.first(where: { $0.id == id }) else { return nil }
        return corrupt?(found) ?? found
    }

    func create(_ draft: EventDraft) async throws -> EventInfo {
        try guardAccess()
        guard let calendar = calendarData.first(where: { $0.id == draft.calendarID }) else {
            throw EventKitFailure.notFound
        }
        guard calendar.allowsModifications else { throw EventKitFailure.readOnly(calendar.title) }
        createCalls += 1
        let event = seed(
            draft.title, draft.start, draft.end, calendarID: calendar.id, allDay: draft.isAllDay,
            location: draft.location)
        if let index = eventData.firstIndex(where: { $0.id == event.id }) {
            eventData[index].notes = draft.notes
            eventData[index].recurrence = draft.recurrence
            eventData[index].isRecurring = draft.recurrence != nil
            eventData[index].alertMinutes = draft.alertMinutesBefore.map { [$0] } ?? []
            eventData[index].timeZoneID = draft.timeZoneID
        }
        return eventData.first { $0.id == event.id } ?? event
    }

    func update(id: String, changes: EventChanges) async throws -> EventInfo {
        try guardAccess()
        guard let index = eventData.firstIndex(where: { $0.id == id }) else { throw EventKitFailure.notFound }
        updateCalls += 1
        if let value = changes.alertMinutesBefore {
            eventData[index].alertMinutes = [value]
        } else if changes.clearAlerts {
            eventData[index].alertMinutes = []
        }
        if let value = changes.timeZoneID { eventData[index].timeZoneID = value }
        if let value = changes.isAllDay { eventData[index].isAllDay = value }
        if let title = changes.title { eventData[index].title = title }
        if let start = changes.start { eventData[index].start = start }
        if let end = changes.end { eventData[index].end = end }
        if let location = changes.location { eventData[index].location = location }
        if let notes = changes.notes { eventData[index].notes = notes }
        if let calendarID = changes.calendarID, let calendar = calendarData.first(where: { $0.id == calendarID }) {
            eventData[index].calendarID = calendar.id
            eventData[index].calendarTitle = calendar.title
        }
        let base = eventData[index].id.split(separator: "|").first.map(String.init) ?? "E"
        eventData[index].id = "\(base)|\(Int(eventData[index].start.timeIntervalSince1970))"
        return eventData[index]
    }

    func delete(id: String) async throws {
        try guardAccess()
        guard eventData.contains(where: { $0.id == id }) else { throw EventKitFailure.notFound }
        deleteCalls += 1
        eventData.removeAll { $0.id == id }
    }

    private func guardAccess() throws { guard accessState == .authorized else { throw EventKitFailure.notAuthorized } }
}

actor FakeContacts: ContactsLookup {
    var accessState: ContactsAccess = .authorized
    var people: [ContactMatch] = []
    private(set) var queries: [String] = []

    func setAccess(_ value: ContactsAccess) { accessState = value }
    func add(_ person: ContactMatch) { people.append(person) }

    func access() async -> ContactsAccess { accessState }
    func requestAccess() async -> ContactsAccess { accessState }
    func find(_ query: String, limit: Int) async throws -> [ContactMatch] {
        queries.append(query)
        return people.filter { $0.fullName.localizedCaseInsensitiveContains(query) }.prefix(limit).map { $0 }
    }
}
