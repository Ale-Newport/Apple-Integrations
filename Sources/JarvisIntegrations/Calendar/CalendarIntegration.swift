import Foundation
import JarvisCore

/// Apple Calendar through EventKit.
///
/// * Dates are exact instants resolved in the user's time zone; moving an event keeps its duration across DST changes.
/// * Existing events are never modified when the request is ambiguous — the user picks which one.
/// * Overlaps with other events are detected before creating or moving (policy in Settings: ask / warn / ignore).
/// * EventKit cannot add attendees or send invitations; people named in a command are looked up in Contacts (optional)
///   and recorded in the event's notes.
public struct CalendarIntegration: AppIntegration {
    public let id = IntegrationID.calendar
    public let displayName = LocalizedText(en: "Calendar", es: "Calendario")
    public let summary = LocalizedText(
        en: "See your schedule, create, move and delete events, and spot conflicts.",
        es: "Consulta tu agenda, crea, mueve y elimina eventos, y detecta conflictos."
    )
    public let symbolName = "calendar"

    private let store: any EventStoring
    private let contacts: (any ContactsLookup)?

    public init(backend: EventKitBackend, contacts: ContactsIntegration? = nil) {
        self.store = backend.calendarStore()
        self.contacts = SystemContactsLookup()
    }

    init(store: any EventStoring, contacts: (any ContactsLookup)? = nil) {
        self.store = store
        self.contacts = contacts
    }

    public var permissionRequirements: [PermissionRequirement] { [EventKitRequirements.calendars] }

    // MARK: Discovery

    public var tools: [ToolDescriptor] {
        let id = self.id
        func tool(_ name: ToolName, _ title: String, _ summary: String, _ parameters: [ToolParameter] = [], _ constraints: [ToolConstraint] = [], safety: ToolSafety = .modifying, deduplicate: Bool = false, examples: [ToolExample] = []) -> ToolDescriptor {
            ToolDescriptor(name: name, integration: id, title: title, summary: summary, parameters: parameters, constraints: constraints, safety: safety, timeout: 45, deduplicate: deduplicate, examples: examples)
        }
        let selector: [ToolParameter] = [
            .string("id", "Exact event id (from calendar.list_events).", maxLength: 300),
            .string("title", "Title (or part of it) of the event.", maxLength: 500),
            .date("on_date", "Day the event is on (yyyy-MM-dd). Without it, upcoming events are searched."),
            .time("at_time", "Start time of the event (HH:mm) to tell events on the same day apart."),
            .string("calendar", "Only events in this calendar.", maxLength: 200),
        ]
        return [
            tool("calendar.find_free_slots", "Find free slots", "Finds verified free slots across selected calendars, in local working hours, excluding weekends by default. Read first, then create events using the returned slots.", [
                .dateOrDateTime("start", "Start of search range.", required: true), .dateOrDateTime("end", "End of range, at most 31 days.", required: true),
                .integer("duration_minutes", "Minimum slot duration.", required: true, min: 5, max: 1440),
                .integer("start_hour", "First local working hour.", min: 0, max: 23, default: 9), .integer("end_hour", "End local working hour.", min: 1, max: 24, default: 20),
                .boolean("include_weekends", "Include Saturday and Sunday.", default: false), .string("calendar", "Restrict to this calendar.", maxLength: 200),
                .integer("limit", "Maximum returned slots.", min: 1, max: 50, default: 10)
            ], safety: .readOnly),
            tool("calendar.find_overlaps", "Find overlapping events", "Finds pairs of busy overlapping events in a verified range (up to 31 days).", [
                .dateOrDateTime("start", "Range start.", required: true), .dateOrDateTime("end", "Range end.", required: true), .string("calendar", "Only this calendar.", maxLength: 200)
            ], safety: .readOnly),
            tool(.calendarListCalendars, "List calendars", "Lists the user's calendars.", safety: .readOnly),
            tool(.calendarListEvents, "List events", "Lists events between two moments.", [
                .dateOrDateTime("start", "Start of the range.", required: true),
                .dateOrDateTime("end", "End of the range (exclusive).", required: true),
                .string("calendar", "Only this calendar.", maxLength: 200),
                .string("query", "Only events whose title contains this text.", maxLength: 200),
                .integer("limit", "Maximum events.", min: 1, max: 500, default: 100),
            ], safety: .readOnly, examples: [ToolExample("What's on my calendar tomorrow?", arguments: ["start": "2026-10-18T00:00:00-04:00", "end": "2026-10-19T00:00:00-04:00"])]),
            tool(.calendarCreateEvent, "Create an event", "Creates an event. A date without a time creates an all-day event.", [
                .string("title", "Event title.", required: true, maxLength: 500),
                .dateOrDateTime("start", "Start (date-time) or day (all-day).", required: true),
                .dateTime("end", "End date-time."),
                .integer("duration_minutes", "Duration; the default from Settings when neither end nor duration is given.", min: 1, max: 60 * 24 * 14),
                .boolean("all_day", "Make it an all-day event."),
                .string("location", "Location.", maxLength: 500),
                .string("notes", "Notes.", maxLength: 5_000),
                .string("calendar", "Destination calendar name.", maxLength: 200),
                .string("calendar_id", "Exact calendar id.", maxLength: 200),
                .strings("attendees", "Names of people involved (looked up in Contacts when enabled; invitations are not sent)."),
                .boolean("allow_conflicts", "Create even if it overlaps another event."),
                .integer("alert_minutes", "Alert this many minutes before.", min: 0, max: 60 * 24 * 7),
            ], [.atMostOne(["end", "duration_minutes"])], deduplicate: true, examples: [
                ToolExample("Schedule a meeting with Daniel on Friday at 3 PM for one hour", arguments: ["title": "Meeting with Daniel", "start": "2026-10-23T15:00:00-04:00", "duration_minutes": 60, "attendees": ["Daniel"]]),
            ]),
            tool(.calendarUpdateEvent, "Edit or reschedule an event", "Changes an event's title, time, duration, location, notes or calendar.", selector + [
                .string("new_title", "New title.", maxLength: 500),
                .string("new_location", "New location.", maxLength: 500),
                .string("new_notes", "New notes.", maxLength: 5_000),
                .date("new_date", "Move to this day, keeping the time."),
                .time("new_time", "Move to this time of day, keeping the day."),
                .dateTime("new_start", "New exact start (the duration is kept)."),
                .dateTime("new_end", "New exact end."),
                .integer("new_duration_minutes", "New duration.", min: 1, max: 60 * 24 * 14),
                .string("new_calendar", "Move to this calendar.", maxLength: 200),
                .boolean("allow_conflicts", "Apply even if the new slot overlaps another event."),
            ], [
                .atLeastOne(["id", "title", "on_date"]),
                .atLeastOne(["new_title", "new_location", "new_notes", "new_date", "new_time", "new_start", "new_end", "new_duration_minutes", "new_calendar"]),
                .atMostOne(["new_start", "new_date"]), .atMostOne(["new_start", "new_time"]), .atMostOne(["new_end", "new_duration_minutes"]),
            ], examples: [ToolExample("Move my Friday meeting to 3 PM", arguments: ["title": "meeting", "on_date": "2026-10-23", "new_time": "15:00"])]),
            tool(.calendarDeleteEvent, "Delete an event", "Deletes an event after confirmation.", selector, [.atLeastOne(["id", "title", "on_date"])], safety: .destructive),
            tool(.calendarCheckConflicts, "Check availability", "Lists events overlapping a time range, i.e. whether the user is free.", [
                .dateTime("start", "Start of the range.", required: true),
                .dateTime("end", "End of the range.", required: true),
                .string("calendar", "Only this calendar.", maxLength: 200),
            ], safety: .readOnly, examples: [ToolExample("Am I free Friday at 3 PM?", arguments: ["start": "2026-10-23T15:00:00-04:00", "end": "2026-10-23T16:00:00-04:00"])]),
        ]
    }

    // MARK: Authorization

    public func status() async -> IntegrationStatus {
        let access = await store.access()
        let entry = IntegrationStatus.PermissionEntry(requirement: EventKitRequirements.calendars, state: EventKitRequirements.state(for: access, requirement: EventKitRequirements.calendars))
        switch access {
        case .authorized: return IntegrationStatus(state: .ready, permissions: [entry])
        case .notDetermined: return IntegrationStatus(state: .needsPermission, detail: EventKitRequirements.calendars.rationale, permissions: [entry])
        case .restricted: return IntegrationStatus(state: .restricted, detail: EventKitRequirements.calendars.rationale, permissions: [entry])
        case .denied, .writeOnly: return IntegrationStatus(state: .denied, detail: EventKitRequirements.calendars.rationale, permissions: [entry])
        }
    }

    public func authorization(for tool: ToolDescriptor) async -> AuthorizationState {
        EventKitRequirements.state(for: await store.access(), requirement: EventKitRequirements.calendars)
    }

    public func requestAuthorization(for tool: ToolDescriptor) async -> AuthorizationState {
        var access = try? await store.requestAccess()
        if access == nil { access = await store.access() }
        return EventKitRequirements.state(for: access ?? .denied, requirement: EventKitRequirements.calendars)
    }

    // MARK: Execution

    public func execute(_ call: ValidatedToolCall, context: ExecutionContext) async throws -> ToolOutcome {
        do {
            switch call.descriptor.name {
            case "calendar.find_free_slots", "calendar.find_overlaps": return try await analyzeSchedule(call, context)
            case .calendarListCalendars: return try await listCalendars(context)
            case .calendarListEvents: return try await listEvents(call, context)
            case .calendarCreateEvent: return try await create(call, context)
            case .calendarUpdateEvent: return try await update(call, context)
            case .calendarDeleteEvent: return try await delete(call, context)
            case .calendarCheckConflicts: return try await checkConflicts(call, context)
            default:
                throw JarvisError.failed("unknown_tool", en: "Calendar does not provide \(call.descriptor.name).", es: "Calendario no ofrece \(call.descriptor.name).")
            }
        } catch let failure as EventKitFailure {
            throw Self.map(failure)
        }
    }

    static func map(_ failure: EventKitFailure) -> JarvisError {
        switch failure {
        case .notAuthorized: return .permissionRequired(EventKitRequirements.calendars)
        case .notFound: return .notFound("event_not_found", en: "That event or calendar no longer exists.", es: "Ese evento o calendario ya no existe.")
        case .readOnly(let name):
            return .failed("calendar_read_only", en: "The calendar “\(name)” is read-only (subscribed or shared as view-only).", es: "El calendario «\(name)» es de solo lectura (suscrito o compartido solo para ver).")
        case .saveFailed(let message):
            return .failed("save_failed", en: "Calendar could not save the change: \(message)", es: "Calendario no pudo guardar el cambio: \(message)")
        case .noWritableSource:
            return .failed("no_source", en: "No writable calendar account is available.", es: "No hay ninguna cuenta de calendario donde se pueda escribir.")
        }
    }

    // MARK: Helpers

    private func date(_ text: String?, _ context: ExecutionContext) -> Date? {
        text.flatMap { ISODates.date(from: $0, timeZone: context.timeZone) }
    }

    private func describe(_ event: EventInfo, _ context: ExecutionContext, includeDay: Bool = true) -> String {
        let language = context.language
        let when: String
        if event.isAllDay {
            when = includeDay ? Formatting.dateTime(event.start, calendar: context.calendar, language: language, includeTime: false) + " · " + language.pick("all day", "todo el día") : language.pick("All day", "Todo el día")
        } else if DateMath.sameDay(event.start, event.end, calendar: context.calendar) || event.end.timeIntervalSince(event.start) < 60 {
            let day = includeDay ? Formatting.dateTime(event.start, calendar: context.calendar, language: language, includeTime: false) + ", " : ""
            when = day + Formatting.time(event.start, calendar: context.calendar, language: language) + "–" + Formatting.time(event.end, calendar: context.calendar, language: language)
        } else {
            when = Formatting.dateTime(event.start, calendar: context.calendar, language: language) + " → " + Formatting.dateTime(event.end, calendar: context.calendar, language: language)
        }
        return "\(when)  \(event.title.isEmpty ? language.pick("(untitled)", "(sin título)") : event.title) (\(event.calendarTitle))"
    }

    private func resolveCalendars(_ calendars: [CalendarInfo], name: String?) throws -> [CalendarInfo]? {
        guard let name else { return nil }
        let matches = NameMatcher.bestMatches(calendars, query: name, minimumScore: 80) { $0.title }
        guard !matches.isEmpty else {
            throw JarvisError.notFound(code: "calendar_not_found", LocalizedText(
                en: "There is no calendar called “\(name)”. Your calendars: \(calendars.map(\.title).joined(separator: ", ")).",
                es: "No existe un calendario llamado «\(name)». Tus calendarios: \(calendars.map(\.title).joined(separator: ", "))."
            ))
        }
        return matches
    }

    /// Busy, timed events that overlap `[start, end)`.
    private func conflicts(start: Date, end: Date, excluding id: String? = nil, calendars: [CalendarInfo]? = nil) async throws -> [EventInfo] {
        let found = try await store.events(from: start, to: end, calendarIDs: calendars?.map(\.id))
        return found.filter { event in
            event.id != id && !event.isAllDay && event.isBusy && !event.isDeclined && event.overlaps(start: start, end: end)
        }
    }

    // MARK: Calendars and listing

    private func listCalendars(_ context: ExecutionContext) async throws -> ToolOutcome {
        let language = context.language
        let calendars = try await store.calendars()
        let lines = calendars.sorted { $0.sourceName == $1.sourceName ? $0.title < $1.title : $0.sourceName < $1.sourceName }.map { calendar in
            "\(calendar.title) — \(calendar.sourceName)" + (calendar.allowsModifications ? "" : language.pick(" · read-only", " · solo lectura")) + (calendar.isDefault ? language.pick(" · default", " · predeterminado") : "")
        }
        return .done(ToolOutput(
            message: language.pick("You have \(calendars.count) calendars:\n", "Tienes \(calendars.count) calendarios:\n") + Formatting.bullets(lines),
            data: ["calendars": .array(calendars.map(\.json)), "count": .int(calendars.count)], verification: .notApplicable
        ))
    }

    private func listEvents(_ call: ValidatedToolCall, _ context: ExecutionContext) async throws -> ToolOutcome {
        let language = context.language
        guard let start = date(call.string("start"), context), let end = date(call.string("end"), context), end > start else {
            throw JarvisError.invalidArgument(parameter: "end", LocalizedText(en: "The end of the range must be after its start.", es: "El final del rango debe ser posterior al inicio."))
        }
        let calendars = try await store.calendars()
        let selected = try resolveCalendars(calendars, name: call.string("calendar"))
        let query = call.string("query")
        let limit = call.int("limit") ?? 100
        var events = try await store.events(from: start, to: end, calendarIDs: selected?.map(\.id))
        if let query { events = events.filter { TextFolding.fold($0.title).contains(TextFolding.fold(query)) } }
        let shown = Array(events.prefix(limit))

        guard !shown.isEmpty else {
            return .done(ToolOutput(message: language.pick("Nothing scheduled for that period.", "No hay nada agendado en ese periodo."), data: ["events": [], "count": 0], verification: .notApplicable))
        }
        var lines: [String] = []
        for (_, group) in Dictionary(grouping: shown, by: { context.calendar.startOfDay(for: $0.start) }).sorted(by: { $0.key < $1.key }) {
            lines.append(Formatting.day(group[0].start, calendar: context.calendar, language: language) + ":")
            for event in group { lines.append("• " + describe(event, context, includeDay: false)) }
        }
        return .done(ToolOutput(
            message: language.pick("\(events.count) event\(events.count == 1 ? "" : "s"):\n", "\(events.count) evento\(events.count == 1 ? "" : "s"):\n") + lines.joined(separator: "\n"),
            data: ["events": .array(shown.map { $0.json(calendar: context.calendar) }), "count": .int(events.count)], verification: .notApplicable
        ))
    }

    private func checkConflicts(_ call: ValidatedToolCall, _ context: ExecutionContext) async throws -> ToolOutcome {
        let language = context.language
        guard let start = date(call.string("start"), context), let end = date(call.string("end"), context), end > start else {
            throw JarvisError.invalidArgument(parameter: "end", LocalizedText(en: "The end of the range must be after its start.", es: "El final del rango debe ser posterior al inicio."))
        }
        let calendars = try await store.calendars()
        let overlapping = try await conflicts(start: start, end: end, calendars: try resolveCalendars(calendars, name: call.string("calendar")))
        let range = Formatting.dateTime(start, calendar: context.calendar, language: language) + "–" + Formatting.time(end, calendar: context.calendar, language: language)
        guard !overlapping.isEmpty else {
            return .done(ToolOutput(message: language.pick("You're free \(range).", "Estás libre \(range)."), data: ["free": true, "conflicts": []], verification: .notApplicable))
        }
        return .done(ToolOutput(
            message: language.pick("You're busy \(range):\n", "Estás ocupado \(range):\n") + Formatting.bullets(overlapping.map { describe($0, context) }),
            data: ["free": false, "conflicts": .array(overlapping.map { $0.json(calendar: context.calendar) })], verification: .notApplicable
        ))
    }

    // MARK: Create

    private func create(_ call: ValidatedToolCall, _ context: ExecutionContext) async throws -> ToolOutcome {
        let language = context.language
        let title = call.string("title") ?? ""
        let calendars = try await store.calendars()

        // Destination calendar.
        let writable = calendars.filter { $0.allowsModifications && !$0.isSubscribed }
        var destination: CalendarInfo?
        if let id = call.string("calendar_id") {
            destination = calendars.first { $0.id == id }
        } else if let name = call.string("calendar") ?? context.settings.defaultCalendar {
            let matches = NameMatcher.bestMatches(writable, query: name, minimumScore: 80) { $0.title }
            if matches.count > 1 {
                let options = matches.map { calendar in
                    ClarificationOption(label: calendar.title, detail: calendar.sourceName, call: call.call.adding(["calendar_id": .string(calendar.id)]))
                }
                return .clarify(Clarification(
                    question: language.pick("You have several calendars called “\(name)”. Which one?", "Tienes varios calendarios llamados «\(name)». ¿Cuál?"),
                    options: options
                ))
            }
            destination = matches.first
            if destination == nil, call.string("calendar") != nil {
                throw JarvisError.notFound(code: "calendar_not_found", LocalizedText(
                    en: "There is no writable calendar called “\(name)”. Your calendars: \(writable.map(\.title).joined(separator: ", ")).",
                    es: "No existe un calendario editable llamado «\(name)». Tus calendarios: \(writable.map(\.title).joined(separator: ", "))."
                ))
            }
        }
        destination = destination ?? writable.first(where: \.isDefault) ?? writable.first
        guard let destination else {
            throw JarvisError.failed("no_writable_calendar", en: "You have no calendar that Jarvis can add events to.", es: "No tienes ningún calendario donde Jarvis pueda añadir eventos.")
        }

        // Times.
        guard let parsedStart = ISODates.parse(call.string("start") ?? "", timeZone: context.timeZone) else {
            throw JarvisError.invalidArgument(parameter: "start", LocalizedText(en: "The start is not a valid date.", es: "El inicio no es una fecha válida."))
        }
        var start: Date
        var end: Date
        var allDay = call.bool("all_day") ?? false
        switch parsedStart {
        case .date(let parts):
            allDay = true
            start = context.calendar.date(from: DateComponents(year: parts.year, month: parts.month, day: parts.day)) ?? context.now
            end = context.calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        case .dateTime(let moment):
            if allDay {
                start = context.calendar.startOfDay(for: moment)
                end = context.calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
            } else {
                start = moment
                if let explicitEnd = date(call.string("end"), context) {
                    end = explicitEnd
                } else {
                    let minutes = call.int("duration_minutes") ?? context.settings.defaultEventDurationMinutes
                    end = start.addingTimeInterval(TimeInterval(minutes) * 60)
                }
            }
        }
        guard end > start else {
            throw JarvisError.invalidArgument(parameter: "end", LocalizedText(en: "The event must end after it starts.", es: "El evento debe terminar después de empezar."))
        }

        // Duplicate check: the same event already exists at the same time.
        let existing = try await store.events(from: start.addingTimeInterval(-60), to: end.addingTimeInterval(60), calendarIDs: [destination.id])
        if let same = existing.first(where: { TextFolding.fold($0.title) == TextFolding.fold(title) && abs($0.start.timeIntervalSince(start)) < 60 && abs($0.end.timeIntervalSince(end)) < 60 }) {
            return .done(ToolOutput(
                message: language.pick("“\(title)” is already on your calendar at that time, so I didn't add a second copy.", "«\(title)» ya está en tu calendario a esa hora, así que no añadí una segunda copia."),
                data: .object((same.json(calendar: context.calendar).objectValue ?? [:]).merging(["created": false]) { _, new in new }),
                verification: .verified(language.pick("The existing event was found in Calendar.", "Se encontró el evento existente en Calendario."))
            ))
        }

        // Conflicts.
        var conflictList: [EventInfo] = []
        if !allDay, context.settings.conflictPolicy != .ignore {
            conflictList = try await conflicts(start: start, end: end)
        }
        if !conflictList.isEmpty, context.settings.conflictPolicy == .ask, call.bool("allow_conflicts") != true, !context.isConfirmed {
            return .confirm(ConfirmationRequest(
                prompt: language.pick(
                    "“\(title)” would overlap with:\n\(conflictList.prefix(4).map { "• " + describe($0, context) }.joined(separator: "\n"))\nCreate it anyway?",
                    "«\(title)» se solaparía con:\n\(conflictList.prefix(4).map { "• " + describe($0, context) }.joined(separator: "\n"))\n¿Crearlo de todos modos?"
                ),
                call: call.call.adding(["allow_conflicts": true, "calendar_id": .string(destination.id)]), destructive: false
            ))
        }

        // People mentioned in the command.
        let people = call.strings("attendees")
        var notes = call.string("notes")
        var resolvedPeople: [JSONValue] = []
        if !people.isEmpty {
            var lines: [String] = []
            for name in people {
                var line = name
                if context.settings.contactLookupEnabled, let contacts, await contacts.access() == .authorized,
                   let match = try? await contacts.find(name, limit: 1).first {
                    line = ([match.fullName] + match.emails.prefix(1).map { "<\($0)>" }).joined(separator: " ")
                    resolvedPeople.append(match.json)
                } else {
                    resolvedPeople.append(.object(["name": .string(name)]))
                }
                lines.append(line)
            }
            let withLine = language.pick("With: ", "Con: ") + lines.joined(separator: ", ")
            notes = [notes, withLine].compactMap { $0 }.joined(separator: "\n")
        }

        let draft = EventDraft(
            title: title, start: start, end: end, isAllDay: allDay, location: call.string("location"), notes: notes,
            calendarID: destination.id, alertMinutesBefore: call.int("alert_minutes")
        )
        let created = try await store.create(draft)

        // Verify by reading the event back.
        guard let stored = try await store.event(id: created.id),
              stored.title == title, abs(stored.start.timeIntervalSince(start)) < 1, abs(stored.end.timeIntervalSince(end)) < 1, stored.calendarID == destination.id else {
            throw JarvisError.verificationFailed(LocalizedText(en: "Calendar did not return the event as saved; please check the app.", es: "Calendario no devolvió el evento tal como se guardó; revisa la app."))
        }

        var warnings: [String] = []
        if !conflictList.isEmpty {
            warnings.append(language.pick("Overlaps with: ", "Se solapa con: ") + conflictList.prefix(3).map(\.title).joined(separator: ", "))
        }
        if !people.isEmpty {
            warnings.append(language.pick("Invitations are not sent: Calendar's public API cannot add attendees.", "No se envían invitaciones: la API pública de Calendario no puede añadir asistentes."))
        }
        let place = stored.location.map { language.pick(" at \($0)", " en \($0)") } ?? ""
        var data = stored.json(calendar: context.calendar).objectValue ?? [:]
        data["created"] = true
        if !resolvedPeople.isEmpty { data["people"] = .array(resolvedPeople) }
        return .done(ToolOutput(
            message: language.pick("Created “\(stored.title)”: ", "Creé «\(stored.title)»: ") + describe(stored, context).replacingOccurrences(of: "  \(stored.title) ", with: " ") + place + ".",
            data: .object(data),
            verification: .verified(language.pick("Re-read from Calendar: title, times and calendar match.", "Releído desde Calendario: título, horas y calendario coinciden.")),
            warnings: warnings
        ))
    }

    // MARK: Resolving one event

    private enum Resolution {
        case found(EventInfo)
        case outcome(ToolOutcome)
    }

    private func resolve(_ call: ValidatedToolCall, _ context: ExecutionContext, forChange: Bool) async throws -> Resolution {
        let language = context.language
        if let id = call.string("id") {
            guard let event = try await store.event(id: id) else {
                throw JarvisError.notFound("event_not_found", en: "That event no longer exists.", es: "Ese evento ya no existe.")
            }
            return .found(event)
        }
        let calendars = try await store.calendars()
        let selected = try resolveCalendars(calendars, name: call.string("calendar"))

        var windowStart: Date
        var windowEnd: Date
        if let day = call.string("on_date"), let parts = ISODates.parseDateParts(day),
           let start = context.calendar.date(from: DateComponents(year: parts.year, month: parts.month, day: parts.day)) {
            windowStart = start
            windowEnd = context.calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        } else {
            windowStart = context.calendar.startOfDay(for: context.now)
            windowEnd = context.calendar.date(byAdding: .day, value: 90, to: windowStart) ?? windowStart.addingTimeInterval(90 * 86_400)
        }
        var pool = try await store.events(from: windowStart, to: windowEnd, calendarIDs: selected?.map(\.id))
        if forChange { pool = pool.filter(\.canModify) }
        if let time = call.string("at_time").flatMap(ISODates.parseTime) {
            pool = pool.filter { !$0.isAllDay && DateMath.clock(of: $0.start, calendar: context.calendar) == (time.hour, time.minute) }
        }

        var matches: [EventInfo]
        if let title = call.string("title") {
            let ranked = NameMatcher.rank(pool, query: title, minimumScore: 60) { $0.title }
            guard let top = ranked.first?.score else {
                let words = Set(TextFolding.tokens(title).filter { $0.count >= 3 })
                let similar = pool.filter { !words.isDisjoint(with: TextFolding.tokens($0.title)) }.prefix(5).map(\.title)
                let hint = similar.isEmpty ? "" : language.pick(" Similar events: \(similar.joined(separator: ", ")).", " Eventos parecidos: \(similar.joined(separator: ", ")).")
                throw JarvisError.notFound(code: "event_not_found", LocalizedText(
                    en: "I couldn't find an event matching “\(title)”\(call.string("on_date") != nil ? " on that day" : " in the next 90 days").\(hint)",
                    es: "No encontré un evento que coincida con «\(title)»\(call.string("on_date") != nil ? " ese día" : " en los próximos 90 días").\(hint)"
                ))
            }
            matches = ranked.filter { $0.score == top }.map(\.item)
        } else {
            matches = pool
            guard !matches.isEmpty else {
                throw JarvisError.notFound("event_not_found", en: "I couldn't find an event at that time.", es: "No encontré ningún evento a esa hora.")
            }
        }
        matches.sort { $0.start < $1.start }

        if matches.count == 1 { return .found(matches[0]) }

        // Several occurrences of one repeating event: the next one is the natural reading.
        let sameSeries = Set(matches.map { TextFolding.fold($0.title) + "|" + $0.calendarID }).count == 1 && matches.allSatisfy(\.isRecurring)
        if sameSeries, call.string("on_date") == nil, let next = matches.first(where: { $0.end > context.now }) { return .found(next) }

        let options = matches.prefix(6).map { event in
            ClarificationOption(
                label: event.title.isEmpty ? language.pick("(untitled)", "(sin título)") : event.title,
                detail: describe(event, context),
                call: ToolCall(tool: call.descriptor.name, arguments: Self.replacingSelector(call.arguments, with: event.id))
            )
        }
        return .outcome(.clarify(Clarification(
            question: language.pick("I found \(matches.count) matching events. Which one?", "Encontré \(matches.count) eventos que coinciden. ¿Cuál?"),
            options: Array(options)
        )))
    }

    private static func replacingSelector(_ arguments: JSONObject, with id: String) -> JSONObject {
        var copy = arguments
        for key in ["title", "on_date", "at_time", "calendar"] { copy[key] = nil }
        copy["id"] = .string(id)
        return copy
    }

    // MARK: Update

    private func update(_ call: ValidatedToolCall, _ context: ExecutionContext) async throws -> ToolOutcome {
        let language = context.language
        let event: EventInfo
        switch try await resolve(call, context, forChange: true) {
        case .found(let found): event = found
        case .outcome(let outcome): return outcome
        }
        guard event.canModify else {
            throw JarvisError.failed("calendar_read_only", en: "“\(event.title)” is in a read-only calendar and cannot be changed.", es: "«\(event.title)» está en un calendario de solo lectura y no se puede cambiar.")
        }

        var changes = EventChanges()
        changes.title = call.string("new_title")
        changes.location = call.string("new_location")
        changes.notes = call.string("new_notes")

        let originalDuration = event.end.timeIntervalSince(event.start)
        var newStart = event.start
        var newEnd = event.end
        let wantsTimeMove = call.has("new_date") || call.has("new_time") || call.has("new_start")
        if wantsTimeMove {
            if event.isAllDay && call.has("new_time") {
                throw JarvisError.failed("all_day_event", en: "“\(event.title)” is an all-day event; give a full start time (for example “Friday at 3 PM”) to make it a timed event.", es: "«\(event.title)» es un evento de todo el día; indica una hora de inicio completa (por ejemplo «el viernes a las 3 PM») para convertirlo en un evento con hora.")
            }
            if let exact = date(call.string("new_start"), context) {
                newStart = exact
            } else {
                let day = call.string("new_date").flatMap(ISODates.parseDateParts).flatMap { context.calendar.date(from: DateComponents(year: $0.year, month: $0.month, day: $0.day)) }
                let time = call.string("new_time").flatMap(ISODates.parseTime).map { (hour: $0.hour, minute: $0.minute) }
                newStart = DateMath.moving(event.start, toDay: day, time: time, calendar: context.calendar)
            }
            newEnd = newStart.addingTimeInterval(originalDuration)
        }
        if let exactEnd = date(call.string("new_end"), context) {
            newEnd = exactEnd
        } else if let minutes = call.int("new_duration_minutes") {
            newEnd = newStart.addingTimeInterval(TimeInterval(minutes) * 60)
        }
        guard newEnd > newStart else {
            throw JarvisError.invalidArgument(parameter: "new_end", LocalizedText(en: "The event must end after it starts.", es: "El evento debe terminar después de empezar."))
        }
        if newStart != event.start { changes.start = newStart }
        if newEnd != event.end { changes.end = newEnd }

        if let calendarName = call.string("new_calendar") {
            let calendars = try await store.calendars().filter { $0.allowsModifications && !$0.isSubscribed }
            let matches = NameMatcher.bestMatches(calendars, query: calendarName, minimumScore: 80) { $0.title }
            guard let target = matches.first, matches.count == 1 else {
                throw JarvisError.notFound("calendar_not_found", en: "I couldn't find exactly one writable calendar called “\(calendarName)”.", es: "No encontré exactamente un calendario editable llamado «\(calendarName)».")
            }
            changes.calendarID = target.id
        }

        // Conflicts at the new time.
        if (changes.start != nil || changes.end != nil), !event.isAllDay, context.settings.conflictPolicy != .ignore {
            let clash = try await conflicts(start: newStart, end: newEnd, excluding: event.id)
            if !clash.isEmpty {
                if context.settings.conflictPolicy == .ask, call.bool("allow_conflicts") != true, !context.isConfirmed {
                    var pinned = call.call
                    pinned.arguments = Self.replacingSelector(call.arguments, with: event.id)
                    return .confirm(ConfirmationRequest(
                        prompt: language.pick(
                            "Moving “\(event.title)” to \(Formatting.dateTime(newStart, calendar: context.calendar, language: language)) would overlap with:\n\(clash.prefix(4).map { "• " + describe($0, context) }.joined(separator: "\n"))\nMove it anyway?",
                            "Mover «\(event.title)» a \(Formatting.dateTime(newStart, calendar: context.calendar, language: language)) se solaparía con:\n\(clash.prefix(4).map { "• " + describe($0, context) }.joined(separator: "\n"))\n¿Moverlo de todos modos?"
                        ),
                        call: pinned.adding(["allow_conflicts": true]), destructive: false
                    ))
                }
            }
        }

        let updated = try await store.update(id: event.id, changes: changes)

        // Verify (the id changes when the start changes, so use the id EventKit returned).
        guard let stored = try await store.event(id: updated.id),
              changes.title.map({ stored.title == $0 }) ?? true,
              changes.start.map({ abs(stored.start.timeIntervalSince($0)) < 1 }) ?? true,
              changes.end.map({ abs(stored.end.timeIntervalSince($0)) < 1 }) ?? true,
              changes.location.map({ stored.location == $0 }) ?? true,
              changes.calendarID.map({ stored.calendarID == $0 }) ?? true else {
            throw JarvisError.verificationFailed(LocalizedText(en: "Calendar did not keep every change; please check the app.", es: "Calendario no conservó todos los cambios; revisa la app."))
        }
        var warnings: [String] = []
        if event.isRecurring {
            warnings.append(language.pick("This is a repeating event: only this occurrence was changed.", "Es un evento repetitivo: solo se cambió esta ocurrencia."))
        }
        if event.hasAttendees {
            warnings.append(language.pick("Attendees are not notified of the change.", "No se notifica el cambio a los asistentes."))
        }
        return .done(ToolOutput(
            message: language.pick("Updated “\(stored.title)”: ", "Actualicé «\(stored.title)»: ") + describe(stored, context).replacingOccurrences(of: "  \(stored.title) ", with: " ") + ".",
            data: stored.json(calendar: context.calendar),
            verification: .verified(language.pick("Re-read from Calendar: the changes are saved.", "Releído desde Calendario: los cambios están guardados.")),
            warnings: warnings
        ))
    }

    // MARK: Delete

    private func delete(_ call: ValidatedToolCall, _ context: ExecutionContext) async throws -> ToolOutcome {
        let language = context.language
        let event: EventInfo
        switch try await resolve(call, context, forChange: true) {
        case .found(let found): event = found
        case .outcome(let outcome): return outcome
        }
        guard event.canModify else {
            throw JarvisError.failed("calendar_read_only", en: "“\(event.title)” is in a read-only calendar and cannot be deleted.", es: "«\(event.title)» está en un calendario de solo lectura y no se puede eliminar.")
        }
        if !context.isConfirmed {
            let repeating = event.isRecurring ? language.pick(" Only this occurrence will be deleted.", " Solo se eliminará esta ocurrencia.") : ""
            return .confirm(ConfirmationRequest(
                prompt: language.pick("Delete “\(event.title)” (\(describe(event, context).components(separatedBy: "  ").first ?? ""))?\(repeating)", "¿Eliminar «\(event.title)» (\(describe(event, context).components(separatedBy: "  ").first ?? ""))?\(repeating)"),
                call: ToolCall(tool: .calendarDeleteEvent, arguments: ["id": .string(event.id)]), destructive: true
            ))
        }
        try await store.delete(id: event.id)
        guard try await store.event(id: event.id) == nil else {
            throw JarvisError.verificationFailed(LocalizedText(en: "The event is still in Calendar after deleting it.", es: "El evento sigue en Calendario después de eliminarlo."))
        }
        var warnings: [String] = []
        if event.hasAttendees { warnings.append(language.pick("Attendees are not notified.", "No se notifica a los asistentes.")) }
        return .done(ToolOutput(
            message: language.pick("Deleted “\(event.title)”.", "Eliminé «\(event.title)»."),
            data: ["id": .string(event.id), "title": .string(event.title), "deleted": true],
            verification: .verified(language.pick("The event is no longer in Calendar.", "El evento ya no está en Calendario.")),
            warnings: warnings
        ))
    }
}


private extension CalendarIntegration {
    func analyzeSchedule(_ call: ValidatedToolCall, _ context: ExecutionContext) async throws -> ToolOutcome {
        guard let start = call.string("start").flatMap({ ISODates.date(from: $0, timeZone: context.timeZone) }),
              let end = call.string("end").flatMap({ ISODates.date(from: $0, timeZone: context.timeZone) }),
              end > start, end.timeIntervalSince(start) <= 32 * 86400 else {
            throw JarvisError.failed("range", en: "Choose a range of up to 31 days.", es: "Elige un intervalo de hasta 31 días.")
        }
        let calendars = try await store.calendars()
        let selected = try resolveCalendars(calendars, name: call.string("calendar"))
        let events = try await store.events(from: start, to: end, calendarIDs: selected?.map(\.id)).filter { $0.isBusy && !$0.isDeclined }.sorted { $0.start < $1.start }
        if call.descriptor.name.rawValue == "calendar.find_overlaps" {
            var pairs: [JSONValue] = []
            for (index, first) in events.enumerated() {
                for second in events.dropFirst(index + 1) {
                    if second.start >= first.end { break }
                    if first.overlaps(start: second.start, end: second.end) {
                        pairs.append(.object(["first": first.json(calendar: context.calendar), "second": second.json(calendar: context.calendar)]))
                        if pairs.count >= 200 { break }
                    }
                }
                if pairs.count >= 200 { break }
            }
            return .done(ToolOutput(message: context.language.pick("Found \(pairs.count) overlapping event pairs.", "Encontré \(pairs.count) pares de eventos que se solapan."), data: ["overlaps": .array(pairs), "truncated": .bool(pairs.count >= 200)], verification: .verified("Calendar events read and compared.")))
        }
        let firstHour = call.int("start_hour") ?? 9
        let lastHour = call.int("end_hour") ?? 20
        guard firstHour < lastHour else { throw JarvisError.failed("hours", en: "Working hours must end after they start.", es: "El horario debe terminar después de empezar.") }
        let duration = TimeInterval(call.int("duration_minutes") ?? 60) * 60
        let limit = call.int("limit") ?? 10
        var day = context.calendar.startOfDay(for: start)
        var slots: [JSONValue] = []
        while day < end, slots.count < limit {
            try Task.checkCancellation()
            guard let nextDay = context.calendar.date(byAdding: .day, value: 1, to: day) else { break }
            defer { day = nextDay }
            if call.bool("include_weekends") != true, context.calendar.isDateInWeekend(day) { continue }
            guard let morning = context.calendar.date(bySettingHour: firstHour, minute: 0, second: 0, of: day) else { continue }
            let evening = lastHour == 24 ? nextDay : context.calendar.date(bySettingHour: lastHour, minute: 0, second: 0, of: day) ?? nextDay
            var cursor = max(start, morning)
            let boundary = min(end, evening)
            func appendGap(until: Date) {
                while cursor.addingTimeInterval(duration) <= until, slots.count < limit {
                    let finish = cursor.addingTimeInterval(duration)
                    slots.append(.object(["start": .string(ISODates.string(from: cursor, timeZone: context.timeZone)), "end": .string(ISODates.string(from: finish, timeZone: context.timeZone))]))
                    cursor = finish
                }
            }
            for event in events where event.start < boundary && event.end > cursor {
                appendGap(until: min(event.start, boundary))
                cursor = max(cursor, event.end)
                if cursor >= boundary { break }
            }
            appendGap(until: boundary)
        }
        let lines = slots.compactMap { slot -> String? in
            guard let start = slot["start"]?.stringValue, let end = slot["end"]?.stringValue else { return nil }
            return "\(start) → \(end)"
        }
        return .done(ToolOutput(message: context.language.pick("Available slots", "Huecos disponibles") + ":\n" + lines.joined(separator: "\n"), data: ["slots": .array(slots), "count": .int(slots.count)], verification: .verified(context.language.pick("Checked all busy events in the selected calendars.", "Comprobados los eventos ocupados en los calendarios seleccionados."))))
    }
}
