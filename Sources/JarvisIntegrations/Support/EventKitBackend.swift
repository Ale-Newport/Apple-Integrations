import EventKit
import Foundation
import JarvisCore

/// The real EventKit access for Reminders and Calendar. One `EKEventStore` is shared by both integrations.
///
/// All EventKit objects stay inside this actor; the rest of the app only sees Sendable value types
/// (`ReminderInfo`, `EventInfo`, …). That keeps Swift 6 data-race checking happy and makes the integrations
/// testable with in-memory stores.
public actor EventKitBackend: ReminderStoring {
    private let store = EKEventStore()

    public init() {}

    // MARK: Authorization

    private static func map(_ status: EKAuthorizationStatus) -> EventKitAccess {
        switch status {
        case .fullAccess: return .authorized
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .writeOnly: return .writeOnly
        default: return .denied
        }
    }

    private func entityAccess(_ entity: EKEntityType) -> EventKitAccess {
        Self.map(EKEventStore.authorizationStatus(for: entity))
    }

    private func request(_ entity: EKEntityType) async throws -> EventKitAccess {
        _ =
            switch entity {
            case .reminder: try await store.requestFullAccessToReminders()
            default: try await store.requestFullAccessToEvents()
            }
        // After the user answers, the store must reload its sources to see the data.
        store.reset()
        return entityAccess(entity)
    }

    func access() async -> EventKitAccess { entityAccess(.reminder) }
    func requestAccess() async throws -> EventKitAccess { try await request(.reminder) }

    /// The calendar (events) view of this backend. Both protocols want an `access()` method, hence the facade.
    nonisolated func calendarStore() -> CalendarFacade { CalendarFacade(backend: self) }

    fileprivate func calendarAccess() -> EventKitAccess { entityAccess(.event) }
    fileprivate func requestCalendarAccess() async throws -> EventKitAccess { try await request(.event) }

    // MARK: Reminders

    private func requireReminders() throws {
        guard entityAccess(.reminder) == .authorized else { throw EventKitFailure.notAuthorized }
    }

    func lists() async throws -> [ReminderListInfo] {
        try requireReminders()
        let defaultID = store.defaultCalendarForNewReminders()?.calendarIdentifier
        return store.calendars(for: .reminder).map { calendar in
            ReminderListInfo(
                id: calendar.calendarIdentifier, title: calendar.title,
                sourceID: calendar.source?.sourceIdentifier ?? "", sourceName: calendar.source?.title ?? "",
                allowsModifications: calendar.allowsContentModifications,
                isDefault: calendar.calendarIdentifier == defaultID
            )
        }
    }

    func createList(title: String, preferredSourceID: String?) async throws -> ReminderListInfo {
        try requireReminders()
        let list = EKCalendar(for: .reminder, eventStore: store)
        list.title = title
        let sources = store.sources
        let source =
            sources.first { $0.sourceIdentifier == preferredSourceID }
            ?? store.defaultCalendarForNewReminders()?.source
            ?? sources.first { $0.sourceType == .calDAV }
            ?? sources.first { $0.sourceType == .local }
        guard let source else { throw EventKitFailure.noWritableSource }
        list.source = source
        do {
            try store.saveCalendar(list, commit: true)
        } catch {
            throw EventKitFailure.saveFailed(error.localizedDescription)
        }
        return ReminderListInfo(
            id: list.calendarIdentifier, title: list.title, sourceID: source.sourceIdentifier, sourceName: source.title,
            allowsModifications: true, isDefault: false
        )
    }

    func renameList(id: String, title: String) async throws {
        try requireReminders()
        guard let list = store.calendar(withIdentifier: id), list.allowedEntityTypes.contains(.reminder) else {
            throw EventKitFailure.notFound
        }
        guard list.allowsContentModifications else { throw EventKitFailure.readOnly(list.title) }
        list.title = title
        do { try store.saveCalendar(list, commit: true) } catch {
            throw EventKitFailure.saveFailed(error.localizedDescription)
        }
    }

    func deleteList(id: String) async throws {
        try requireReminders()
        guard let list = store.calendar(withIdentifier: id), list.allowedEntityTypes.contains(.reminder) else {
            throw EventKitFailure.notFound
        }
        guard list.allowsContentModifications else { throw EventKitFailure.readOnly(list.title) }
        do { try store.removeCalendar(list, commit: true) } catch {
            throw EventKitFailure.saveFailed(error.localizedDescription)
        }
    }

    func reminders(in listIDs: [String]?, calendar: Calendar) async throws -> [ReminderInfo] {
        try requireReminders()
        var calendars: [EKCalendar]?
        if let listIDs {
            calendars = listIDs.compactMap { store.calendar(withIdentifier: $0) }
            if calendars?.isEmpty == true { return [] }
        }
        let predicate = store.predicateForReminders(in: calendars)
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { found in
                continuation.resume(returning: (found ?? []).map { Self.info($0, calendar: calendar) })
            }
        }
    }

    func reminder(id: String, calendar: Calendar) async throws -> ReminderInfo? {
        try requireReminders()
        guard let item = store.calendarItem(withIdentifier: id) as? EKReminder else { return nil }
        return Self.info(item, calendar: calendar)
    }

    func create(_ draft: ReminderDraft, calendar: Calendar) async throws -> ReminderInfo {
        try requireReminders()
        guard let list = store.calendar(withIdentifier: draft.listID) else { throw EventKitFailure.notFound }
        guard list.allowsContentModifications else { throw EventKitFailure.readOnly(list.title) }
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = list
        reminder.title = draft.title
        reminder.notes = draft.notes
        reminder.priority = draft.priority
        Self.apply(due: draft.due, to: reminder, calendar: calendar)
        if let recurrence = draft.recurrence {
            reminder.addRecurrenceRule(draft.recurrenceDetails?.rule ?? Self.recurrenceRule(recurrence))
            reminder.startDateComponents = reminder.dueDateComponents
        }
        do {
            try store.save(reminder, commit: true)
        } catch {
            throw EventKitFailure.saveFailed(error.localizedDescription)
        }
        return Self.info(reminder, calendar: calendar)
    }

    func update(id: String, changes: ReminderChanges, calendar: Calendar) async throws -> ReminderInfo {
        try requireReminders()
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw EventKitFailure.notFound
        }
        if let title = changes.title { reminder.title = title }
        if let notes = changes.notes { reminder.notes = notes }
        if let priority = changes.priority { reminder.priority = priority }
        if let completed = changes.completed { reminder.isCompleted = completed }
        if let recurrence = changes.recurrence {
            for rule in reminder.recurrenceRules ?? [] { reminder.removeRecurrenceRule(rule) }
            if recurrence != "none" {
                reminder.addRecurrenceRule(changes.recurrenceDetails?.rule ?? Self.recurrenceRule(recurrence))
            }
        }
        if changes.clearDue {
            reminder.dueDateComponents = nil
            for alarm in reminder.alarms ?? [] { reminder.removeAlarm(alarm) }
        } else if let due = changes.due {
            for alarm in reminder.alarms ?? [] where alarm.absoluteDate != nil { reminder.removeAlarm(alarm) }
            Self.apply(due: due, to: reminder, calendar: calendar)
        }
        if let listID = changes.listID {
            guard let list = store.calendar(withIdentifier: listID) else { throw EventKitFailure.notFound }
            guard list.allowsContentModifications else { throw EventKitFailure.readOnly(list.title) }
            reminder.calendar = list
        }
        do {
            try store.save(reminder, commit: true)
        } catch {
            throw EventKitFailure.saveFailed(error.localizedDescription)
        }
        return Self.info(reminder, calendar: calendar)
    }

    func delete(id: String) async throws {
        try requireReminders()
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw EventKitFailure.notFound
        }
        do {
            try store.remove(reminder, commit: true)
        } catch {
            throw EventKitFailure.saveFailed(error.localizedDescription)
        }
    }

    private static func recurrenceRule(_ name: String) -> EKRecurrenceRule {
        RecurrenceSpecification(
            frequency: ["weekdays", "weekends"].contains(name) ? "weekly" : name,
            weekdays: name == "weekdays" ? [1, 2, 3, 4, 5] : name == "weekends" ? [6, 7] : []
        ).rule
    }

    private static func apply(due: DueSpec?, to reminder: EKReminder, calendar: Calendar) {
        guard let due else { return }
        switch due {
        case .date(let year, let month, let day):
            reminder.dueDateComponents = DateComponents(calendar: calendar, year: year, month: month, day: day)
        case .dateTime(let date):
            // Floating components (no time zone), like the Reminders app itself writes them…
            var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            components.calendar = calendar
            reminder.dueDateComponents = components
            // …plus an alarm at that moment, otherwise the reminder shows a due time but never notifies.
            reminder.addAlarm(EKAlarm(absoluteDate: date))
        }
    }

    private static func info(_ reminder: EKReminder, calendar: Calendar) -> ReminderInfo {
        var due: Date?
        var hasTime = false
        if var components = reminder.dueDateComponents {
            hasTime = components.hour != nil
            components.calendar = components.calendar ?? calendar
            if components.timeZone == nil { components.timeZone = calendar.timeZone }
            due = components.date
        }
        return ReminderInfo(
            id: reminder.calendarItemIdentifier, title: reminder.title ?? "", notes: reminder.notes,
            listID: reminder.calendar?.calendarIdentifier ?? "", listTitle: reminder.calendar?.title ?? "",
            sourceName: reminder.calendar?.source?.title ?? "", isCompleted: reminder.isCompleted,
            completionDate: reminder.completionDate, due: due, dueHasTime: hasTime, priority: reminder.priority,
            hasAlarm: reminder.hasAlarms, creationDate: reminder.creationDate,
            recurrence: reminder.recurrenceRules?.first.map { RecurrenceSpecification(rule: $0).simpleName },
            recurrenceDetails: reminder.recurrenceRules?.first.map(RecurrenceSpecification.init(rule:))
        )
    }

    // MARK: Events

    private func requireEvents() throws {
        guard entityAccess(.event) == .authorized else { throw EventKitFailure.notAuthorized }
    }

    fileprivate func allCalendars() throws -> [CalendarInfo] {
        try requireEvents()
        let defaultID = store.defaultCalendarForNewEvents?.calendarIdentifier
        return store.calendars(for: .event).map { calendar in
            CalendarInfo(
                id: calendar.calendarIdentifier, title: calendar.title, sourceName: calendar.source?.title ?? "",
                sourceType: Self.sourceTypeName(calendar.source?.sourceType),
                allowsModifications: calendar.allowsContentModifications,
                isSubscribed: calendar.type == .subscription || calendar.type == .birthday,
                isDefault: calendar.calendarIdentifier == defaultID
            )
        }
    }

    fileprivate func eventsBetween(_ start: Date, _ end: Date, calendarIDs: [String]?) throws -> [EventInfo] {
        try requireEvents()
        var calendars: [EKCalendar]?
        if let calendarIDs {
            calendars = calendarIDs.compactMap { store.calendar(withIdentifier: $0) }
            if calendars?.isEmpty == true { return [] }
        }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        return store.events(matching: predicate).map(Self.info).sorted { $0.start < $1.start }
    }

    fileprivate func findEvent(id: String) throws -> EKEvent? {
        try requireEvents()
        let parts = id.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let stamp = TimeInterval(parts[1]) else {
            return store.event(withIdentifier: id)
        }
        let start = Date(timeIntervalSince1970: stamp)
        let predicate = store.predicateForEvents(
            withStart: start.addingTimeInterval(-86_400), end: start.addingTimeInterval(86_400 * 2), calendars: nil)
        return store.events(matching: predicate).first {
            $0.eventIdentifier == parts[0] && abs($0.startDate.timeIntervalSince(start)) < 1
        }
    }

    fileprivate func eventByID(_ id: String) throws -> EventInfo? {
        try findEvent(id: id).map(Self.info)
    }

    fileprivate func createEvent(_ draft: EventDraft) throws -> EventInfo {
        try requireEvents()
        guard let calendar = store.calendar(withIdentifier: draft.calendarID) else { throw EventKitFailure.notFound }
        guard calendar.allowsContentModifications else { throw EventKitFailure.readOnly(calendar.title) }
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = draft.title
        event.isAllDay = draft.isAllDay
        event.startDate = draft.start
        event.endDate = draft.end
        event.location = draft.location
        event.notes = draft.notes
        if let zone = draft.timeZoneID { event.timeZone = TimeZone(identifier: zone) }
        if let rule = draft.recurrence { event.addRecurrenceRule(rule.rule) }
        if let minutes = draft.alertMinutesBefore {
            event.addAlarm(EKAlarm(relativeOffset: -TimeInterval(minutes) * 60))
        }
        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            throw EventKitFailure.saveFailed(error.localizedDescription)
        }
        return Self.info(event)
    }

    fileprivate func updateEvent(id: String, changes: EventChanges) throws -> EventInfo {
        guard let event = try findEvent(id: id) else { throw EventKitFailure.notFound }
        if let zone = changes.timeZoneID { event.timeZone = TimeZone(identifier: zone) }
        if let allDay = changes.isAllDay { event.isAllDay = allDay }
        if changes.clearAlerts || changes.alertMinutesBefore != nil {
            for alarm in event.alarms ?? [] { event.removeAlarm(alarm) }
        }
        if let minutes = changes.alertMinutesBefore { event.addAlarm(EKAlarm(relativeOffset: -Double(minutes) * 60)) }
        if let title = changes.title { event.title = title }
        if let start = changes.start { event.startDate = start }
        if let end = changes.end { event.endDate = end }
        if let location = changes.location { event.location = location }
        if let notes = changes.notes { event.notes = notes }
        if let calendarID = changes.calendarID {
            guard let calendar = store.calendar(withIdentifier: calendarID) else { throw EventKitFailure.notFound }
            guard calendar.allowsContentModifications else { throw EventKitFailure.readOnly(calendar.title) }
            event.calendar = calendar
        }
        do {
            // Only this occurrence changes for repeating events.
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            throw EventKitFailure.saveFailed(error.localizedDescription)
        }
        return Self.info(event)
    }

    fileprivate func deleteEvent(id: String) throws {
        guard let event = try findEvent(id: id) else { throw EventKitFailure.notFound }
        do {
            try store.remove(event, span: .thisEvent, commit: true)
        } catch {
            throw EventKitFailure.saveFailed(error.localizedDescription)
        }
    }

    private static func info(_ event: EKEvent) -> EventInfo {
        let me = event.attendees?.first { $0.isCurrentUser }
        return EventInfo(
            id: "\(event.eventIdentifier ?? "")|\(Int(event.startDate.timeIntervalSince1970))",
            title: event.title ?? "",
            start: event.startDate, end: event.endDate, isAllDay: event.isAllDay, location: event.location,
            notes: event.notes,
            calendarID: event.calendar?.calendarIdentifier ?? "", calendarTitle: event.calendar?.title ?? "",
            sourceName: event.calendar?.source?.title ?? "", isRecurring: event.hasRecurrenceRules || event.isDetached,
            hasAttendees: event.hasAttendees, isBusy: event.availability != .free,
            isDeclined: me?.participantStatus == .declined,
            canModify: event.calendar?.allowsContentModifications ?? false,
            recurrence: event.recurrenceRules?.first.map(RecurrenceSpecification.init(rule:)),
            alertMinutes: (event.alarms ?? []).filter { $0.absoluteDate == nil }.map { Int(-$0.relativeOffset / 60) },
            timeZoneID: event.timeZone?.identifier
        )
    }

    private static func sourceTypeName(_ type: EKSourceType?) -> String {
        switch type {
        case .local?: return "local"
        case .exchange?: return "exchange"
        case .calDAV?: return "caldav"
        case .mobileMe?: return "icloud"
        case .subscribed?: return "subscribed"
        case .birthdays?: return "birthdays"
        default: return "other"
        }
    }
}

/// `EventStoring` view of the backend (the two protocols both declare `access()`, so the calendar side is a facade).
struct CalendarFacade: EventStoring {
    let backend: EventKitBackend

    func access() async -> EventKitAccess { await backend.calendarAccess() }
    func requestAccess() async throws -> EventKitAccess { try await backend.requestCalendarAccess() }
    func calendars() async throws -> [CalendarInfo] { try await backend.allCalendars() }
    func events(from start: Date, to end: Date, calendarIDs: [String]?) async throws -> [EventInfo] {
        try await backend.eventsBetween(start, end, calendarIDs: calendarIDs)
    }
    func event(id: String) async throws -> EventInfo? { try await backend.eventByID(id) }
    func create(_ draft: EventDraft) async throws -> EventInfo { try await backend.createEvent(draft) }
    func update(id: String, changes: EventChanges) async throws -> EventInfo {
        try await backend.updateEvent(id: id, changes: changes)
    }
    func delete(id: String) async throws { try await backend.deleteEvent(id: id) }
}
