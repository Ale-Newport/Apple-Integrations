import Foundation
import JarvisCore

/// Authorization state shared by the Reminders and Calendar stores.
public enum EventKitAccess: Sendable, Equatable {
    case authorized
    case notDetermined
    case denied
    case restricted
    /// Calendar only: the user granted "add events only" access, which cannot read or modify events.
    case writeOnly
}

public enum EventKitFailure: Error, Sendable, Equatable {
    case notAuthorized
    case notFound
    case readOnly(String)
    case saveFailed(String)
    case noWritableSource
}

// MARK: - Reminders

struct ReminderListInfo: Sendable, Hashable {
    var id: String
    var title: String
    var sourceID: String
    var sourceName: String
    var allowsModifications: Bool
    var isDefault: Bool

    var json: JSONValue {
        .object(["id": .string(id), "name": .string(title), "account": .string(sourceName), "is_default": .bool(isDefault)])
    }
}

enum DueSpec: Sendable, Hashable {
    /// A calendar day without a time.
    case date(year: Int, month: Int, day: Int)
    /// An exact moment; the reminder also gets an alarm at that moment so it actually notifies.
    case dateTime(Date)
}

struct ReminderInfo: Sendable, Hashable {
    var id: String
    var title: String
    var notes: String?
    var listID: String
    var listTitle: String
    var sourceName: String
    var isCompleted: Bool
    var completionDate: Date?
    var due: Date?
    var dueHasTime: Bool
    var priority: Int
    var hasAlarm: Bool
    var creationDate: Date?

    /// Reminders' own priority scale: 1–4 high, 5 medium, 6–9 low, 0 none.
    var priorityName: String {
        switch priority {
        case 1...4: return "high"
        case 5: return "medium"
        case 6...9: return "low"
        default: return "none"
        }
    }

    func json(calendar: Calendar) -> JSONValue {
        var object: JSONObject = [
            "id": .string(id), "title": .string(title), "list": .string(listTitle), "list_id": .string(listID),
            "account": .string(sourceName), "completed": .bool(isCompleted), "priority": .string(priorityName),
            "has_alarm": .bool(hasAlarm),
        ]
        if let notes, !notes.isEmpty { object["notes"] = .string(notes) }
        if let due {
            object["due"] = dueHasTime ? .string(ISODates.string(from: due, timeZone: calendar.timeZone)) : .string(ISODates.dayString(from: due, timeZone: calendar.timeZone))
            object["due_has_time"] = .bool(dueHasTime)
        }
        if let completionDate { object["completed_at"] = .string(ISODates.string(from: completionDate, timeZone: calendar.timeZone)) }
        return .object(object)
    }
}

struct ReminderDraft: Sendable {
    var title: String
    var notes: String?
    var listID: String
    var due: DueSpec?
    var priority: Int
}

struct ReminderChanges: Sendable {
    var title: String?
    var notes: String?
    var due: DueSpec?
    var clearDue = false
    var listID: String?
    var priority: Int?
    var completed: Bool?
}

enum ReminderStatusFilter: String, Sendable { case pending, completed, all }

protocol ReminderStoring: Sendable {
    func access() async -> EventKitAccess
    func requestAccess() async throws -> EventKitAccess
    func lists() async throws -> [ReminderListInfo]
    func createList(title: String, preferredSourceID: String?) async throws -> ReminderListInfo
    func reminders(in listIDs: [String]?, calendar: Calendar) async throws -> [ReminderInfo]
    func reminder(id: String, calendar: Calendar) async throws -> ReminderInfo?
    func create(_ draft: ReminderDraft, calendar: Calendar) async throws -> ReminderInfo
    func update(id: String, changes: ReminderChanges, calendar: Calendar) async throws -> ReminderInfo
    func delete(id: String) async throws
}

// MARK: - Calendar

struct CalendarInfo: Sendable, Hashable {
    var id: String
    var title: String
    var sourceName: String
    var sourceType: String
    var allowsModifications: Bool
    var isSubscribed: Bool
    var isDefault: Bool

    var json: JSONValue {
        .object([
            "id": .string(id), "name": .string(title), "account": .string(sourceName), "type": .string(sourceType),
            "writable": .bool(allowsModifications), "is_default": .bool(isDefault),
        ])
    }
}

struct EventInfo: Sendable, Hashable {
    /// `<eventIdentifier>|<start timestamp>` — unique per occurrence, so recurring events can be addressed precisely.
    var id: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var location: String?
    var notes: String?
    var calendarID: String
    var calendarTitle: String
    var sourceName: String
    var isRecurring: Bool
    var hasAttendees: Bool
    var isBusy: Bool
    var isDeclined: Bool
    var canModify: Bool

    func json(calendar: Calendar) -> JSONValue {
        var object: JSONObject = [
            "id": .string(id), "title": .string(title), "calendar": .string(calendarTitle), "calendar_id": .string(calendarID),
            "all_day": .bool(isAllDay), "recurring": .bool(isRecurring), "has_attendees": .bool(hasAttendees),
            "start": isAllDay ? .string(ISODates.dayString(from: start, timeZone: calendar.timeZone)) : .string(ISODates.string(from: start, timeZone: calendar.timeZone)),
            "end": isAllDay ? .string(ISODates.dayString(from: end, timeZone: calendar.timeZone)) : .string(ISODates.string(from: end, timeZone: calendar.timeZone)),
        ]
        if let location, !location.isEmpty { object["location"] = .string(location) }
        if let notes, !notes.isEmpty { object["notes"] = .string(notes) }
        return .object(object)
    }

    func overlaps(start otherStart: Date, end otherEnd: Date) -> Bool {
        start < otherEnd && end > otherStart
    }
}

struct EventDraft: Sendable {
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var location: String?
    var notes: String?
    var calendarID: String
    var alertMinutesBefore: Int?
}

struct EventChanges: Sendable {
    var title: String?
    var start: Date?
    var end: Date?
    var location: String?
    var notes: String?
    var calendarID: String?
}

protocol EventStoring: Sendable {
    func access() async -> EventKitAccess
    func requestAccess() async throws -> EventKitAccess
    func calendars() async throws -> [CalendarInfo]
    func events(from start: Date, to end: Date, calendarIDs: [String]?) async throws -> [EventInfo]
    func event(id: String) async throws -> EventInfo?
    func create(_ draft: EventDraft) async throws -> EventInfo
    func update(id: String, changes: EventChanges) async throws -> EventInfo
    func delete(id: String) async throws
}

// MARK: - Permission requirements

enum EventKitRequirements {
    static let reminders = PermissionRequirement(
        id: "reminders",
        title: LocalizedText(en: "Reminders", es: "Recordatorios"),
        rationale: LocalizedText(
            en: "Jarvis creates, reads and completes reminders using Apple's EventKit. Full access is needed to find existing reminders.",
            es: "Jarvis crea, lee y completa recordatorios con EventKit de Apple. Se necesita acceso completo para encontrar recordatorios existentes."
        ),
        settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders"
    )

    static let calendars = PermissionRequirement(
        id: "calendars",
        title: LocalizedText(en: "Calendars", es: "Calendarios"),
        rationale: LocalizedText(
            en: "Jarvis reads and edits your events using Apple's EventKit. Full access is needed to move or delete events and to check conflicts.",
            es: "Jarvis lee y edita tus eventos con EventKit de Apple. Se necesita acceso completo para mover o eliminar eventos y detectar conflictos."
        ),
        settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
    )

    static let contacts = PermissionRequirement(
        id: "contacts",
        title: LocalizedText(en: "Contacts", es: "Contactos"),
        rationale: LocalizedText(
            en: "Optional: Jarvis can look up the people you mention (for example “meeting with Daniel”) to add their details to events.",
            es: "Opcional: Jarvis puede buscar a las personas que mencionas (por ejemplo «reunión con Daniel») para añadir sus datos a los eventos."
        ),
        settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts"
    )

    static func state(for access: EventKitAccess, requirement: PermissionRequirement) -> AuthorizationState {
        switch access {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined(requirement)
        case .denied, .writeOnly: return .denied(requirement)
        case .restricted: return .restricted(requirement)
        }
    }
}
