import JarvisCore
import SwiftUI

/// Text field that saves when the user presses Return or leaves the field, so half-typed values (and spaces) are
/// never trimmed or applied while typing.
struct CommitTextField: View {
    let title: String
    let value: String
    let commit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $draft)
            .focused($focused)
            .onSubmit { commit(draft) }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commit(draft) }
            }
            .onChange(of: value) { _, new in
                if !focused { draft = new }
            }
            .onAppear { draft = value }
            .onDisappear { commit(draft) }
    }
}

struct IntegrationSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            musicSection
            remindersSection
            calendarSection
            notesSection
            contactsSection
            timesOfDaySection
            clockSection
            CapabilitySettingsSections()
        }
        .formStyle(.grouped)
        .task {
            model.loadChoices(.reminderLists)
            model.loadChoices(.calendars)
        }
    }

    // MARK: Music

    private var musicSection: some View {
        Section {
            Toggle(
                model.t(
                    "Play albums and artists through a queue playlist",
                    "Reproducir álbumes y artistas mediante una lista de cola"),
                isOn: model.binding(\.musicUsesQueuePlaylist))
            if model.settings.musicUsesQueuePlaylist {
                CommitTextField(
                    title: model.t("Queue playlist name", "Nombre de la lista de cola"),
                    value: model.settings.musicQueuePlaylistName
                ) { text in
                    model.update { $0.musicQueuePlaylistName = text }
                }
            }
            caption(
                model.t(
                    "Apple Music's scripting interface can play playlists and single tracks. To play a whole album or artist, Jarvis fills this playlist with its tracks and plays it; your other playlists are never changed. Turn it off to play single tracks only.",
                    "La interfaz de scripts de Apple Music puede reproducir listas y canciones sueltas. Para reproducir un álbum o artista completo, Jarvis llena esta lista con sus canciones y la reproduce; tus otras listas nunca se modifican. Desactívalo para reproducir solo canciones sueltas."
                ))
        } header: {
            Label("Apple Music", systemImage: "music.note")
        }
    }

    // MARK: Reminders

    private var remindersSection: some View {
        Section {
            choicePicker(
                model.t("Default list", "Lista predeterminada"), kind: .reminderLists,
                selection: model.binding(\.defaultReminderList))
            caption(
                model.t(
                    "Used when a reminder names no list. Without one, the list you set as default in Reminders is used.",
                    "Se usa cuando un recordatorio no indica lista. Sin una, se usa la lista predeterminada de Recordatorios."
                ))
        } header: {
            Label(model.t("Reminders", "Recordatorios"), systemImage: "checklist")
        }
    }

    // MARK: Calendar

    private var calendarSection: some View {
        Section {
            choicePicker(
                model.t("Default calendar", "Calendario predeterminado"), kind: .calendars,
                selection: model.binding(\.defaultCalendar))
            Stepper(value: model.binding(\.defaultEventDurationMinutes), in: 5...480, step: 5) {
                Text(
                    model.t(
                        "Default event length: \(model.settings.defaultEventDurationMinutes) min",
                        "Duración predeterminada: \(model.settings.defaultEventDurationMinutes) min"))
            }
            Picker(
                model.t("When a new event overlaps another", "Cuando un evento nuevo se solapa con otro"),
                selection: model.binding(\.conflictPolicy)
            ) {
                Text(model.t("Ask me first", "Preguntarme antes")).tag(ConflictPolicy.ask)
                Text(model.t("Create it and warn me", "Crearlo y avisarme")).tag(ConflictPolicy.warn)
                Text(model.t("Create it without checking", "Crearlo sin comprobar")).tag(ConflictPolicy.ignore)
            }
        } header: {
            Label(model.t("Calendar", "Calendario"), systemImage: "calendar")
        }
    }

    // MARK: Notes

    @ViewBuilder
    private var notesSection: some View {
        let set = model.choices[.noteFolders] ?? AppModel.ChoiceSet()
        Section {
            if set.isLoaded, set.problem == nil {
                let accounts = Array(Set(set.items.map(\.group))).sorted()
                Picker(
                    model.t("Default account", "Cuenta predeterminada"), selection: model.binding(\.defaultNotesAccount)
                ) {
                    Text(model.t("Notes' default", "La predeterminada de Notas")).tag(String?.none)
                    ForEach(accounts, id: \.self) { Text($0).tag(Optional($0)) }
                }
                let account = model.settings.defaultNotesAccount
                let folders = Array(Set(set.items.filter { account == nil || $0.group == account }.map(\.name)))
                    .sorted()
                Picker(
                    model.t("Default folder", "Carpeta predeterminada"), selection: model.binding(\.defaultNotesFolder)
                ) {
                    Text(model.t("Notes' default", "La predeterminada de Notas")).tag(String?.none)
                    ForEach(folders, id: \.self) { Text($0).tag(Optional($0)) }
                }
            } else {
                HStack {
                    Button(
                        set.isLoading
                            ? model.t("Loading…", "Cargando…")
                            : model.t("Load accounts and folders", "Cargar cuentas y carpetas")
                    ) {
                        model.loadChoices(.noteFolders, force: true, allowPrompt: true)
                    }
                    .disabled(set.isLoading)
                    if let problem = set.problem {
                        Text(problem).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
                if model.settings.defaultNotesAccount != nil || model.settings.defaultNotesFolder != nil {
                    Text(
                        [model.settings.defaultNotesAccount, model.settings.defaultNotesFolder].compactMap { $0 }
                            .joined(separator: " ▸ ")
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            caption(
                model.t(
                    "Loading these opens Notes in the background to read its folders.",
                    "Cargarlas abre Notas en segundo plano para leer sus carpetas."))
        } header: {
            Label(model.t("Notes", "Notas"), systemImage: "note.text")
        }
    }

    // MARK: Contacts

    private var contactsSection: some View {
        Section {
            Toggle(
                model.t("Look up people in Contacts", "Buscar personas en Contactos"),
                isOn: model.binding(\.contactLookupEnabled))
            caption(
                model.t(
                    "When you mention a person (“meeting with Daniel”), Jarvis can match them to a contact and add their name and email to the event notes. Off by default; it asks for the Contacts permission only when enabled.",
                    "Cuando mencionas a una persona («reunión con Daniel»), Jarvis puede relacionarla con un contacto y añadir su nombre y correo a las notas del evento. Desactivado por defecto; solo pide el permiso de Contactos al activarlo."
                ))
        } header: {
            Label(model.t("Contacts (optional)", "Contactos (opcional)"), systemImage: "person.crop.circle")
        }
    }

    // MARK: Times of day

    private var timesOfDaySection: some View {
        Section {
            hourStepper(model.t("Morning", "Mañana"), \.morningHour)
            hourStepper(model.t("Afternoon", "Tarde"), \.afternoonHour)
            hourStepper(model.t("Evening", "Noche temprana"), \.eveningHour)
            hourStepper(model.t("Night", "Noche"), \.nightHour)
            caption(
                model.t(
                    "The time Jarvis assumes for phrases like “tomorrow morning” or “esta tarde”. It always tells you what it assumed.",
                    "La hora que Jarvis supone en frases como «mañana por la mañana» o «this evening». Siempre te dice lo que supuso."
                ))
        } header: {
            Label(model.t("Parts of the day", "Partes del día"), systemImage: "sun.max")
        }
    }

    private func hourStepper(_ title: String, _ keyPath: WritableKeyPath<JarvisSettings, Int>) -> some View {
        Stepper(value: model.binding(keyPath), in: 0...23) {
            Text("\(title): \(String(format: "%02d:00", model.settings[keyPath: keyPath]))")
        }
    }

    // MARK: Clock

    private var clockSection: some View {
        Section {
            ClockSetupView()
            DisclosureGroup(model.t("Shortcut names", "Nombres de los atajos")) {
                shortcutName(model.t("Create alarm", "Crear alarma"), \.createAlarm)
                shortcutName(model.t("List alarms", "Listar alarmas"), \.listAlarms)
                shortcutName(model.t("Turn alarm on/off", "Activar/desactivar alarma"), \.setAlarmEnabled)
                shortcutName(model.t("Delete alarm", "Eliminar alarma"), \.deleteAlarm)
                shortcutName(model.t("Start timer", "Iniciar temporizador"), \.startTimer)
                shortcutName(model.t("Cancel timer", "Cancelar temporizador"), \.cancelTimer)
                shortcutName(model.t("Get timer", "Leer temporizador"), \.getTimer)
                caption(
                    model.t(
                        "Only change these if you named your shortcuts differently.",
                        "Cámbialos solo si pusiste otros nombres a tus atajos."))
            }
        } header: {
            Label(model.t("Clock (alarms and timers)", "Reloj (alarmas y temporizadores)"), systemImage: "alarm")
        }
    }

    private func shortcutName(_ title: String, _ keyPath: WritableKeyPath<ShortcutNames, String>) -> some View {
        LabeledContent(title) {
            CommitTextField(title: title, value: model.settings.shortcutNames[keyPath: keyPath]) { text in
                let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty, clean != model.settings.shortcutNames[keyPath: keyPath] else { return }
                model.update { $0.shortcutNames[keyPath: keyPath] = clean }
                model.refreshShortcutPresence()
            }
            .multilineTextAlignment(.trailing)
        }
    }

    // MARK: Helpers

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    /// A picker over names the system reported, with “system default” first. A saved value that is no longer in the
    /// list (renamed or deleted elsewhere) stays visible so it can be changed deliberately.
    @ViewBuilder
    private func choicePicker(_ title: String, kind: AppModel.ChoiceKind, selection: Binding<String?>) -> some View {
        let set = model.choices[kind] ?? AppModel.ChoiceSet()
        let names = Array(Set(set.items.map(\.name))).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        Picker(title, selection: selection) {
            Text(model.t("System default", "Predeterminada del sistema")).tag(String?.none)
            if let current = selection.wrappedValue, !names.contains(current) {
                Text(current).tag(Optional(current))
            }
            ForEach(names, id: \.self) { Text($0).tag(Optional($0)) }
        }
        if let problem = set.problem {
            HStack {
                Text(problem).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                Spacer()
                Button(model.t("Retry", "Reintentar")) { model.loadChoices(kind, force: true, allowPrompt: true) }
                    .buttonStyle(.link)
            }
        }
    }
}
