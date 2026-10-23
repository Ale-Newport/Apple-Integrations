import Foundation

/// Identifies an Apple application integration (`music`, `reminders`, …).
public struct IntegrationID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let music: IntegrationID = "music"
    public static let reminders: IntegrationID = "reminders"
    public static let notes: IntegrationID = "notes"
    public static let calendar: IntegrationID = "calendar"
    public static let clock: IntegrationID = "clock"
    public static let contacts: IntegrationID = "contacts"
}

/// The dotted, namespaced name of a tool, e.g. `music.play` or `reminders.create`.
///
/// The names of the built-in tools are declared here (rather than inside each integration) so the
/// interpreter can emit them without depending on the integration implementations. A test asserts
/// that every built-in name is registered by exactly one integration.
public struct ToolName: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible, Comparable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: ToolName, rhs: ToolName) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The namespace before the first dot (`music` for `music.play`).
    public var namespace: String { rawValue.split(separator: ".", maxSplits: 1).first.map(String.init) ?? rawValue }
}

public extension ToolName {
    // Music
    static let musicPlay: ToolName = "music.play"
    static let musicPlayPlaylist: ToolName = "music.play_playlist"
    static let musicPause: ToolName = "music.pause"
    static let musicResume: ToolName = "music.resume"
    static let musicStop: ToolName = "music.stop"
    static let musicNext: ToolName = "music.next"
    static let musicPrevious: ToolName = "music.previous"
    static let musicSearch: ToolName = "music.search"
    static let musicListPlaylists: ToolName = "music.list_playlists"
    static let musicSetVolume: ToolName = "music.set_volume"
    static let musicNowPlaying: ToolName = "music.now_playing"

    // Reminders
    static let remindersCreate: ToolName = "reminders.create"
    static let remindersList: ToolName = "reminders.list"
    static let remindersComplete: ToolName = "reminders.complete"
    static let remindersUpdate: ToolName = "reminders.update"
    static let remindersDelete: ToolName = "reminders.delete"
    static let remindersListLists: ToolName = "reminders.list_lists"
    static let remindersCreateList: ToolName = "reminders.create_list"

    // Notes
    static let notesCreate: ToolName = "notes.create"
    static let notesList: ToolName = "notes.list"
    static let notesListFolders: ToolName = "notes.list_folders"
    static let notesSearch: ToolName = "notes.search"
    static let notesRead: ToolName = "notes.read"
    static let notesAppend: ToolName = "notes.append"
    static let notesUpdate: ToolName = "notes.update"
    static let notesDelete: ToolName = "notes.delete"

    // Calendar
    static let calendarListCalendars: ToolName = "calendar.list_calendars"
    static let calendarListEvents: ToolName = "calendar.list_events"
    static let calendarCreateEvent: ToolName = "calendar.create_event"
    static let calendarUpdateEvent: ToolName = "calendar.update_event"
    static let calendarDeleteEvent: ToolName = "calendar.delete_event"
    static let calendarCheckConflicts: ToolName = "calendar.check_conflicts"

    // Clock (Shortcuts-backed)
    static let alarmsCreate: ToolName = "alarms.create"
    static let alarmsList: ToolName = "alarms.list"
    static let alarmsSetEnabled: ToolName = "alarms.set_enabled"
    static let alarmsDelete: ToolName = "alarms.delete"
    static let timersCreate: ToolName = "timers.create"
    static let timersCancel: ToolName = "timers.cancel"

    // Contacts
    static let contactsFind: ToolName = "contacts.find"
}
