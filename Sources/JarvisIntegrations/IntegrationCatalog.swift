import Foundation
import JarvisCore

/// The set of Apple integrations that ship with Jarvis. The app, the IPC host and tests all start from here;
/// adding another integration means appending it to this list (the engine and registry need no changes).
public enum IntegrationCatalog {
    /// All built-in integrations wired to the real system frameworks.
    public static func makeDefault() -> [any AppIntegration] {
        let eventKit = EventKitBackend()
        return [
            MusicIntegration(),
            RemindersIntegration(backend: eventKit),
            NotesIntegration(),
            CalendarIntegration(backend: eventKit),
            ClockIntegration(),
            ContactsIntegration(),
            WeatherIntegration(),
            UtilitiesIntegration(),
            ManagedTimersIntegration(),
        ]
    }

    /// Every tool name that the interpreter can produce for the built-in integrations.
    public static let builtInToolNames: [ToolName] = [
        .musicPlay, .musicPlayPlaylist, .musicPause, .musicResume, .musicStop, .musicNext, .musicPrevious, .musicSearch,
        .musicListPlaylists, .musicSetVolume, .musicNowPlaying, "music.set_shuffle", "music.set_repeat",
        .remindersCreate, .remindersList, .remindersComplete, .remindersUpdate, .remindersDelete, .remindersListLists, .remindersCreateList, "reminders.rename_list", "reminders.delete_list",
        .notesCreate, .notesList, .notesListFolders, .notesSearch, .notesRead, .notesAppend, .notesUpdate, .notesDelete,
        .calendarListCalendars, .calendarListEvents, .calendarCreateEvent, .calendarUpdateEvent, .calendarDeleteEvent, .calendarCheckConflicts, "calendar.find_free_slots", "calendar.find_overlaps",
        .alarmsCreate, .alarmsList, .alarmsSetEnabled, .alarmsDelete, .timersCreate, .timersCancel,
        .contactsFind,
        "weather.forecast", "utilities.calculate", "utilities.convert", "utilities.date_difference",
        "jarvis_timers.create", "jarvis_timers.list", "jarvis_timers.pause", "jarvis_timers.resume", "jarvis_timers.extend", "jarvis_timers.cancel",
    ]
}
