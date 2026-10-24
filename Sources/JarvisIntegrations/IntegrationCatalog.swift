import Foundation
import JarvisCore

/// The set of Apple integrations that ship with Jarvis. The app, the IPC host and tests all start from here;
/// adding another integration means appending it to this list (the engine and registry need no changes).
public enum IntegrationCatalog {
    /// All built-in integrations wired to the real system frameworks.
    public static func makeDefault() -> [any AppIntegration] {
        let eventKit = EventKitBackend()
        return [
            MusicIntegration(), CatalogIntegration(),
            RemindersIntegration(backend: eventKit),
            NotesIntegration(),
            CalendarIntegration(backend: eventKit),
            ClockIntegration(),
            ContactsIntegration(),
            WeatherIntegration(),
            UtilitiesIntegration(),
            ManagedTimersIntegration(),
            SystemIntegration(), FilesIntegration(), BrowserIntegration(), WorkflowIntegration(),
            MailIntegration(), MessagesIntegration(), ResearchIntegration(), ConditionsIntegration(),
            StopwatchIntegration(),
        ]
    }

    /// Every tool name that the interpreter can produce for the built-in integrations.
    public static let builtInToolNames: [ToolName] = [
        "catalog.search", "catalog.album_tracks", "catalog.artist_albums",
        "music.find_tracks", "music.play_tracks", "music.create_playlist", "music.playlist_tracks",
        "music.add_to_playlist",
        .musicPlay, .musicPlayPlaylist, .musicPause, .musicResume, .musicStop, .musicNext, .musicPrevious, .musicSearch,
        .musicListPlaylists, .musicSetVolume, .musicNowPlaying, "music.set_shuffle", "music.set_repeat",
        "reminders.find_duplicates", "reminders.batch_complete", "reminders.batch_delete",
        .remindersCreate, .remindersList, .remindersComplete, .remindersUpdate, .remindersDelete, .remindersListLists,
        .remindersCreateList, "reminders.rename_list", "reminders.delete_list",
        "notes.create_folder", "notes.move", "notes.replace_text", "notes.merge", "notes.backups",
        "notes.restore_backup",
        .notesCreate, .notesList, .notesListFolders, .notesSearch, .notesRead, .notesAppend, .notesUpdate, .notesDelete,
        .calendarListCalendars, .calendarListEvents, .calendarCreateEvent, .calendarUpdateEvent, .calendarDeleteEvent,
        .calendarCheckConflicts, "calendar.find_free_slots", "calendar.find_overlaps",
        .alarmsCreate, .alarmsList, .alarmsSetEnabled, .alarmsDelete, .timersCreate, .timersCancel,
        "system.brightness", "system.sleep_display",
        "stopwatch.control",
        "conditions.schedule_rain", "conditions.list", "conditions.cancel",
        "research.search",
        .contactsFind,
        "system.list_apps", "system.open_app", "system.close_app", "system.information", "system.volume",
        "system.clipboard_read", "system.clipboard_write", "system.open_url", "system.settings", "system.screenshot",
        "files.list", "files.search", "files.metadata", "files.read", "files.create_folder", "files.copy", "files.move",
        "files.rename", "files.trash", "files.duplicates", "files.organize", "files.open", "files.compress",
        "files.extract", "files.convert_text", "files.convert_image", "browser.tabs", "browser.read_tab",
        "browser.open", "workflows.list", "workflows.run", "workflows.focus", "mail.search", "mail.read", "mail.draft",
        "mail.reply", "mail.forward", "mail.attach", "mail.read_draft", "mail.send", "messages.find",
        "messages.conversations",
        "messages.draft", "messages.send", "contacts.get", "contacts.create", "contacts.update",
        "weather.forecast", "utilities.calculate", "utilities.convert", "utilities.date_difference",
        "utilities.differentiate", "utilities.integrate", "utilities.solve_equation", "utilities.linear_system",
        "utilities.matrix", "utilities.statistics", "utilities.probability", "utilities.finance", "utilities.random",
        "utilities.currency",
        "jarvis_timers.create", "jarvis_timers.list", "jarvis_timers.pause", "jarvis_timers.resume",
        "jarvis_timers.extend", "jarvis_timers.cancel",
    ]
}
