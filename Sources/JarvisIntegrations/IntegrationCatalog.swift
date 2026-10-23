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
        ]
    }

    /// Every tool name that the interpreter can produce for the built-in integrations.
    public static let builtInToolNames: [ToolName] = [
        .musicPlay, .musicPlayPlaylist, .musicPause, .musicResume, .musicStop, .musicNext, .musicPrevious, .musicSearch,
        .musicListPlaylists, .musicSetVolume, .musicNowPlaying,
        .remindersCreate, .remindersList, .remindersComplete, .remindersUpdate, .remindersDelete, .remindersListLists, .remindersCreateList,
        .notesCreate, .notesList, .notesListFolders, .notesSearch, .notesRead, .notesAppend, .notesUpdate, .notesDelete,
        .calendarListCalendars, .calendarListEvents, .calendarCreateEvent, .calendarUpdateEvent, .calendarDeleteEvent, .calendarCheckConflicts,
        .alarmsCreate, .alarmsList, .alarmsSetEnabled, .alarmsDelete, .timersCreate, .timersCancel,
        .contactsFind,
    ]
}
