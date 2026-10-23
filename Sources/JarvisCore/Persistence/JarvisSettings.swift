import Foundation

/// How the calendar integration reacts when a new event overlaps an existing one.
public enum ConflictPolicy: String, Codable, Sendable, CaseIterable, Hashable {
    /// Ask before creating an overlapping event (default).
    case ask
    /// Create it and mention the overlap in the response.
    case warn
    /// Create it without checking.
    case ignore
}

/// Names of the user-created Shortcuts that bridge to the Clock app. See `docs/SHORTCUTS_SETUP.md`.
/// Only the first and fifth are needed to *create* alarms and timers; the others unlock listing, switching,
/// deleting and — importantly — **verifying** that an alarm or timer really exists afterwards.
public struct ShortcutNames: Codable, Sendable, Hashable {
    public var createAlarm: String = "Jarvis Create Alarm"
    public var listAlarms: String = "Jarvis List Alarms"
    public var setAlarmEnabled: String = "Jarvis Set Alarm Enabled"
    public var deleteAlarm: String = "Jarvis Delete Alarm"
    public var startTimer: String = "Jarvis Start Timer"
    public var cancelTimer: String = "Jarvis Cancel Timer"
    public var getTimer: String = "Jarvis Get Timer"

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case createAlarm, listAlarms, setAlarmEnabled, deleteAlarm, startTimer, cancelTimer, getTimer
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ShortcutNames()
        createAlarm = try c.decodeIfPresent(String.self, forKey: .createAlarm) ?? d.createAlarm
        listAlarms = try c.decodeIfPresent(String.self, forKey: .listAlarms) ?? d.listAlarms
        setAlarmEnabled = try c.decodeIfPresent(String.self, forKey: .setAlarmEnabled) ?? d.setAlarmEnabled
        deleteAlarm = try c.decodeIfPresent(String.self, forKey: .deleteAlarm) ?? d.deleteAlarm
        startTimer = try c.decodeIfPresent(String.self, forKey: .startTimer) ?? d.startTimer
        cancelTimer = try c.decodeIfPresent(String.self, forKey: .cancelTimer) ?? d.cancelTimer
        getTimer = try c.decodeIfPresent(String.self, forKey: .getTimer) ?? d.getTimer
    }
}

/// User preferences consumed by the engine and the integrations. A snapshot is taken per command so a
/// running command never sees settings change halfway.
public struct JarvisSettings: Codable, Sendable, Hashable {
    public var languagePreference: LanguagePreference = .automatic
    public var model = ModelConfiguration()
    public var rememberSession = true
    public var preferenceMemoryEnabled = false
    /// Explicit aliases only; no automatic harvesting of private data.
    public var aliases: [String: String] = [:]
    public var weatherLocation: String?

    // Defaults for "default apps" style choices. `nil` means "use the system default".
    public var defaultReminderList: String?
    public var defaultCalendar: String?
    public var defaultNotesAccount: String?
    public var defaultNotesFolder: String?

    public var defaultEventDurationMinutes: Int = 60
    /// Hours used when a phrase names only a part of the day ("tomorrow morning").
    public var morningHour: Int = 9
    public var afternoonHour: Int = 15
    public var eveningHour: Int = 19
    public var nightHour: Int = 21

    public var conflictPolicy: ConflictPolicy = .ask
    public var contactLookupEnabled: Bool = false

    public var musicUsesQueuePlaylist: Bool = true
    public var musicQueuePlaylistName: String = "Jarvis Queue"

    public var shortcutNames = ShortcutNames()

    public var saveHistory: Bool = true
    public var duplicateWindowSeconds: Double = 8
    public var ipcEnabled: Bool = true

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case model, rememberSession, preferenceMemoryEnabled, aliases, weatherLocation
        case languagePreference, defaultReminderList, defaultCalendar, defaultNotesAccount, defaultNotesFolder
        case defaultEventDurationMinutes, morningHour, afternoonHour, eveningHour, nightHour
        case conflictPolicy, contactLookupEnabled, musicUsesQueuePlaylist, musicQueuePlaylistName
        case shortcutNames, saveHistory, duplicateWindowSeconds, ipcEnabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = JarvisSettings()
        model = try c.decodeIfPresent(ModelConfiguration.self, forKey: .model) ?? d.model
        rememberSession = try c.decodeIfPresent(Bool.self, forKey: .rememberSession) ?? true
        preferenceMemoryEnabled = try c.decodeIfPresent(Bool.self, forKey: .preferenceMemoryEnabled) ?? false
        aliases = try c.decodeIfPresent([String: String].self, forKey: .aliases) ?? [:]
        weatherLocation = try c.decodeIfPresent(String.self, forKey: .weatherLocation)
        languagePreference = try c.decodeIfPresent(LanguagePreference.self, forKey: .languagePreference) ?? d.languagePreference
        defaultReminderList = try c.decodeIfPresent(String.self, forKey: .defaultReminderList)
        defaultCalendar = try c.decodeIfPresent(String.self, forKey: .defaultCalendar)
        defaultNotesAccount = try c.decodeIfPresent(String.self, forKey: .defaultNotesAccount)
        defaultNotesFolder = try c.decodeIfPresent(String.self, forKey: .defaultNotesFolder)
        defaultEventDurationMinutes = try c.decodeIfPresent(Int.self, forKey: .defaultEventDurationMinutes) ?? d.defaultEventDurationMinutes
        morningHour = try c.decodeIfPresent(Int.self, forKey: .morningHour) ?? d.morningHour
        afternoonHour = try c.decodeIfPresent(Int.self, forKey: .afternoonHour) ?? d.afternoonHour
        eveningHour = try c.decodeIfPresent(Int.self, forKey: .eveningHour) ?? d.eveningHour
        nightHour = try c.decodeIfPresent(Int.self, forKey: .nightHour) ?? d.nightHour
        conflictPolicy = try c.decodeIfPresent(ConflictPolicy.self, forKey: .conflictPolicy) ?? d.conflictPolicy
        contactLookupEnabled = try c.decodeIfPresent(Bool.self, forKey: .contactLookupEnabled) ?? d.contactLookupEnabled
        musicUsesQueuePlaylist = try c.decodeIfPresent(Bool.self, forKey: .musicUsesQueuePlaylist) ?? d.musicUsesQueuePlaylist
        musicQueuePlaylistName = try c.decodeIfPresent(String.self, forKey: .musicQueuePlaylistName) ?? d.musicQueuePlaylistName
        shortcutNames = try c.decodeIfPresent(ShortcutNames.self, forKey: .shortcutNames) ?? d.shortcutNames
        saveHistory = try c.decodeIfPresent(Bool.self, forKey: .saveHistory) ?? d.saveHistory
        duplicateWindowSeconds = try c.decodeIfPresent(Double.self, forKey: .duplicateWindowSeconds) ?? d.duplicateWindowSeconds
        ipcEnabled = try c.decodeIfPresent(Bool.self, forKey: .ipcEnabled) ?? d.ipcEnabled
    }

    /// Clamps values that came from disk or the UI into safe ranges.
    public func sanitized() -> JarvisSettings {
        var copy = self
        copy.model.maxRounds = min(max(copy.model.maxRounds, 1), 16)
        copy.model.endpoint = String(copy.model.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000))
        copy.model.model = String(copy.model.model.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        copy.aliases = copy.aliases.sorted { $0.key < $1.key }.prefix(100).reduce(into: [String: String]()) { $0[String($1.key.prefix(200))] = String($1.value.prefix(500)) }
        copy.defaultEventDurationMinutes = min(max(copy.defaultEventDurationMinutes, 5), 24 * 60)
        copy.morningHour = min(max(copy.morningHour, 0), 23)
        copy.afternoonHour = min(max(copy.afternoonHour, 0), 23)
        copy.eveningHour = min(max(copy.eveningHour, 0), 23)
        copy.nightHour = min(max(copy.nightHour, 0), 23)
        copy.duplicateWindowSeconds = min(max(copy.duplicateWindowSeconds, 0), 120)
        let trimmedQueue = copy.musicQueuePlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.musicQueuePlaylistName = trimmedQueue.isEmpty ? "Jarvis Queue" : String(trimmedQueue.prefix(80))
        return copy
    }
}

/// Source of the current settings. The engine asks for a snapshot at the start of each command.
public protocol SettingsProviding: Sendable {
    func snapshot() -> JarvisSettings
}

/// A thread-safe, observable-free settings container, convenient for tests and headless use.
public final class InMemorySettings: SettingsProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var value: JarvisSettings

    public init(_ value: JarvisSettings = JarvisSettings()) { self.value = value }

    public func snapshot() -> JarvisSettings {
        lock.lock(); defer { lock.unlock() }
        return value.sanitized()
    }

    public func update(_ change: (inout JarvisSettings) -> Void) {
        lock.lock(); defer { lock.unlock() }
        change(&value)
    }
}

/// Persists settings as a single JSON blob in `UserDefaults`.
public final class UserDefaultsSettingsStore: SettingsProviding, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()
    private var cached: JarvisSettings?

    public init(defaults: UserDefaults = .standard, key: String = "jarvis.settings.v1") {
        self.defaults = defaults
        self.key = key
    }

    public func snapshot() -> JarvisSettings {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached.sanitized() }
        let loaded = loadLocked()
        cached = loaded
        return loaded.sanitized()
    }

    public func save(_ settings: JarvisSettings) {
        lock.lock(); defer { lock.unlock() }
        let clean = settings.sanitized()
        cached = clean
        if let data = try? JSONEncoder().encode(clean) {
            defaults.set(data, forKey: key)
        }
    }

    private func loadLocked() -> JarvisSettings {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(JarvisSettings.self, from: data) else {
            return JarvisSettings()
        }
        return decoded
    }
}
