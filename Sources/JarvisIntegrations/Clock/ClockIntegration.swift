import AppKit
import Foundation
import JarvisCore

struct ClockAlarm: Sendable, Hashable {
    var hour: Int
    var minute: Int
    var isEnabled: Bool
    var label: String

    /// Parses `hours|minutes|enabled|label` lines written by the “Jarvis List Alarms” shortcut.
    static func parse(_ output: String) -> [ClockAlarm] {
        output.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let parts = rawLine.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 3, let hour = Int(parts[0]), let minute = Int(parts[1]), (0...23).contains(hour), (0...59).contains(minute) else { return nil }
            return ClockAlarm(hour: hour, minute: minute, isEnabled: isTruthy(parts[2]), label: parts.count > 3 ? parts[3] : "")
        }
    }

    static func isTruthy(_ text: String) -> Bool {
        ["yes", "si", "true", "1", "on", "verdadero", "activada", "activado", "enabled", "sí"].contains(TextFolding.fold(text))
    }

    var time: String { ISODates.timeString(hour: hour, minute: minute) }

    var json: JSONValue {
        .object(["time": .string(time), "hour": .int(hour), "minute": .int(minute), "enabled": .bool(isEnabled), "label": label.isEmpty ? .null : .string(label)])
    }

    func display(_ language: Language) -> String {
        let clock = String(format: "%d:%02d %@", hour % 12 == 0 ? 12 : hour % 12, minute, hour >= 12 ? "PM" : "AM")
        var text = clock + (label.isEmpty ? "" : " — \(label)")
        text += isEnabled ? "" : language.pick(" (off)", " (desactivada)")
        return text
    }
}

/// Alarms and timers for the Clock app, through the user's “Jarvis …” shortcuts (see ``ClockShortcut``).
///
/// What is genuinely supported (macOS 27): create, list, turn on/off and delete alarms; start and cancel the timer.
/// Not supported by any public interface: alarm sounds, snooze settings, repeating alarms through Jarvis' shortcut
/// contract, timer labels, and several simultaneous timers. Jarvis states these limits instead of pretending.
public struct ClockIntegration: AppIntegration {
    public let id = IntegrationID.clock
    public let displayName = LocalizedText(en: "Clock", es: "Reloj")
    public let summary = LocalizedText(
        en: "Create, list, switch and delete alarms; start and cancel timers (through Shortcuts).",
        es: "Crea, lista, activa y elimina alarmas; inicia y cancela temporizadores (mediante Atajos)."
    )
    public let symbolName = "alarm"

    private let shortcuts: any ShortcutsRunning
    private let clockInstalled: @Sendable () -> Bool

    public init(shortcuts: any ShortcutsRunning = ShortcutsCLIRunner()) {
        self.init(shortcuts: shortcuts, clockInstalled: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.clock") != nil })
    }

    init(shortcuts: any ShortcutsRunning, clockInstalled: @escaping @Sendable () -> Bool) {
        self.shortcuts = shortcuts
        self.clockInstalled = clockInstalled
    }

    // MARK: Discovery

    public var permissionRequirements: [PermissionRequirement] { [] }

    public var tools: [ToolDescriptor] {
        let id = self.id
        func tool(_ name: ToolName, _ title: String, _ summary: String, _ parameters: [ToolParameter] = [], _ constraints: [ToolConstraint] = [], safety: ToolSafety = .modifying, deduplicate: Bool = false, examples: [ToolExample] = []) -> ToolDescriptor {
            ToolDescriptor(name: name, integration: id, title: title, summary: summary, parameters: parameters, constraints: constraints, safety: safety, timeout: 60, deduplicate: deduplicate, examples: examples)
        }
        let alarmSelector: [ToolParameter] = [
            .time("time", "Time of the alarm (HH:mm, 24 h)."),
            .boolean("time_is_ambiguous", "true when the user gave no AM/PM: both HH:mm and HH:mm+12h match."),
            .string("label", "Label (or part of it) of the alarm.", maxLength: 200),
        ]
        return [
            tool(.alarmsCreate, "Create an alarm", "Creates a Clock alarm that rings at the next occurrence of the given time.", [
                .time("time", "Time of day (HH:mm, 24 h).", required: true),
                .string("label", "Alarm label.", maxLength: 200),
                .date("date", "The day the user expects it to ring. Clock alarms ring at the next occurrence of the time; if that is another day, Jarvis refuses instead of creating a misleading alarm."),
                .strings("repeat_days", "Weekdays to repeat (mon…sun). Not supported by Jarvis' shortcut contract."),
            ], deduplicate: true, examples: [ToolExample("Set an alarm for 7:30 tomorrow morning", arguments: ["time": "07:30", "date": "2026-10-18"])]),
            tool(.alarmsList, "List alarms", "Lists the alarms in the Clock app.", safety: .readOnly, examples: [ToolExample("Show my alarms", arguments: [:])]),
            tool(.alarmsSetEnabled, "Turn an alarm on or off", "Enables or disables an existing alarm.", [
                .boolean("enabled", "true = on, false = off.", required: true),
            ] + alarmSelector, [.atLeastOne(["time", "label"])], examples: [ToolExample("Turn off my 7:30 alarm", arguments: ["enabled": false, "time": "07:30"])]),
            tool(.alarmsDelete, "Delete an alarm", "Deletes an alarm after confirmation.", alarmSelector, [.atLeastOne(["time", "label"])], safety: .destructive),
            tool(.timersCreate, "Start a timer", "Starts the Clock timer.", [
                .integer("duration_seconds", "Duration in seconds.", required: true, min: 1, max: 86_400),
                .string("label", "Timer label (the Clock action cannot store it; it is only echoed back).", maxLength: 200),
            ], deduplicate: true, examples: [ToolExample("Set a timer for 10 minutes", arguments: ["duration_seconds": 600])]),
            tool(.timersCancel, "Cancel the timer", "Cancels the running timer.", examples: [ToolExample("Cancel the timer", arguments: [:])]),
        ]
    }

    // MARK: Authorization and setup

    public func status() async -> IntegrationStatus {
        guard clockInstalled() else {
            return IntegrationStatus(state: .unavailable, detail: LocalizedText(en: "The Clock app is not available on this Mac.", es: "La app Reloj no está disponible en este Mac."))
        }
        let names = ShortcutNames()
        do {
            let installed = try await shortcuts.installedShortcutNames()
            let missing = ClockShortcut.allCases.filter { !installed.contains($0.name(in: names)) }
            if missing.isEmpty { return IntegrationStatus(state: .ready) }
            let essential = missing.filter(\.isEssentialForCreating)
            let list = missing.map { $0.name(in: names) }.joined(separator: ", ")
            return IntegrationStatus(
                state: essential.isEmpty ? .ready : .needsSetup,
                detail: LocalizedText(en: "Missing shortcuts: \(list).", es: "Atajos que faltan: \(list).")
            )
        } catch {
            return IntegrationStatus(state: .needsSetup, detail: LocalizedText(en: "The Shortcuts tool is not available.", es: "La herramienta de Atajos no está disponible."))
        }
    }

    public func authorization(for tool: ToolDescriptor) async -> AuthorizationState {
        guard clockInstalled() else {
            return .unavailable(LocalizedText(en: "The Clock app is not available on this Mac.", es: "La app Reloj no está disponible en este Mac."))
        }
        guard FileManager.default.isExecutableFile(atPath: ShortcutsCLIRunner.executable) else {
            return .unavailable(LocalizedText(en: "The Shortcuts command-line tool is not available on this Mac.", es: "La herramienta de línea de comandos de Atajos no está disponible en este Mac."))
        }
        return .authorized   // no macOS privacy permission is involved; shortcut setup is checked at run time
    }

    public func requestAuthorization(for tool: ToolDescriptor) async -> AuthorizationState { await authorization(for: tool) }

    // MARK: Execution

    public func execute(_ call: ValidatedToolCall, context: ExecutionContext) async throws -> ToolOutcome {
        switch call.descriptor.name {
        case .alarmsCreate: return try await createAlarm(call, context)
        case .alarmsList: return try await listAlarms(context)
        case .alarmsSetEnabled: return try await setEnabled(call, context)
        case .alarmsDelete: return try await deleteAlarm(call, context)
        case .timersCreate: return try await startTimer(call, context)
        case .timersCancel: return try await cancelTimer(context)
        default:
            throw JarvisError.failed("unknown_tool", en: "Clock does not provide \(call.descriptor.name).", es: "Reloj no ofrece \(call.descriptor.name).")
        }
    }

    // MARK: Running shortcuts

    private func installed() async throws -> Set<String> {
        do {
            return try await shortcuts.installedShortcutNames()
        } catch ShortcutsError.toolUnavailable {
            throw JarvisError.unavailable(LocalizedText(en: "The Shortcuts command-line tool is not available on this Mac.", es: "La herramienta de línea de comandos de Atajos no está disponible en este Mac."))
        } catch ShortcutsError.timedOut {
            throw JarvisError.failed("shortcuts_timeout", en: "The Shortcuts app did not answer in time.", es: "La app Atajos no respondió a tiempo.")
        } catch {
            throw JarvisError.failed("shortcuts_error", en: "Shortcuts could not be queried: \(error.localizedDescription)", es: "No se pudo consultar Atajos: \(error.localizedDescription)")
        }
    }

    /// Throws `setupRequired` with exact instructions when a needed shortcut does not exist.
    private func require(_ needed: [ClockShortcut], context: ExecutionContext, because reason: LocalizedText) async throws {
        let names = context.settings.shortcutNames
        let present = try await installed()
        let missing = needed.filter { !present.contains($0.name(in: names)) }
        guard missing.isEmpty else {
            let list = missing.map { "“\($0.name(in: names))”" }.joined(separator: ", ")
            throw JarvisError.setupRequired(
                ClockShortcut.instructions(missing: missing, names: names, language: context.language),
                LocalizedText(
                    en: "\(reason.en) This needs the Shortcut \(list), which is not in your Shortcuts app yet. Open “Clock” in the Jarvis sidebar (or Settings ▸ Integrations) for the exact steps (about two minutes, once).",
                    es: "\(reason.es) Esto necesita el Atajo \(list), que todavía no está en tu app Atajos. Abre «Reloj» en la barra lateral de Jarvis (o Ajustes ▸ Integraciones) para ver los pasos exactos (unos dos minutos, una sola vez)."
                )
            )
        }
    }

    private func isInstalled(_ shortcut: ClockShortcut, _ context: ExecutionContext) async -> Bool {
        guard let present = try? await shortcuts.installedShortcutNames() else { return false }
        return present.contains(shortcut.name(in: context.settings.shortcutNames))
    }

    @discardableResult
    private func run(_ shortcut: ClockShortcut, input: JSONObject? = nil, context: ExecutionContext) async throws -> String {
        let name = shortcut.name(in: context.settings.shortcutNames)
        let payload = input.flatMap { try? String(data: JSONEncoder().encode(JSONValue.object($0)), encoding: .utf8) }
        do {
            return try await shortcuts.run(name: name, input: payload, timeout: 45).text
        } catch ShortcutsError.timedOut {
            throw JarvisError.failed("shortcut_timeout", en: "The shortcut “\(name)” did not finish. Run it once from the Shortcuts app and choose “Always Allow” if macOS asks for permission.", es: "El atajo «\(name)» no terminó. Ejecútalo una vez desde la app Atajos y elige «Permitir siempre» si macOS pide permiso.")
        } catch ShortcutsError.failed(_, let message) {
            let detail = message.isEmpty ? "" : " (\(String(message.prefix(200))))"
            throw JarvisError.failed("shortcut_failed", en: "The shortcut “\(name)” reported an error\(detail). Open it in the Shortcuts app and run it manually to see why.", es: "El atajo «\(name)» informó de un error\(detail). Ábrelo en la app Atajos y ejecútalo manualmente para ver por qué.")
        } catch ShortcutsError.toolUnavailable {
            throw JarvisError.unavailable(LocalizedText(en: "The Shortcuts command-line tool is not available on this Mac.", es: "La herramienta de línea de comandos de Atajos no está disponible en este Mac."))
        }
    }

    private func readAlarms(_ context: ExecutionContext) async throws -> [ClockAlarm] {
        ClockAlarm.parse(try await run(.listAlarms, context: context))
    }

    // MARK: alarms.create

    private func createAlarm(_ call: ValidatedToolCall, _ context: ExecutionContext) async throws -> ToolOutcome {
        let language = context.language
        guard let time = call.string("time").flatMap(ISODates.parseTime) else {
            throw JarvisError.invalidArgument(parameter: "time", LocalizedText(en: "Give the alarm time as HH:mm.", es: "Indica la hora de la alarma como HH:mm."))
        }
        if !call.strings("repeat_days").isEmpty {
            throw JarvisError.unsupported(
                LocalizedText(en: "Jarvis creates one-time alarms only; repeating alarms cannot be set through its Clock shortcut.", es: "Jarvis solo crea alarmas de una sola vez; las alarmas repetitivas no se pueden crear con su atajo del Reloj."),
                alternative: LocalizedText(en: "Create the repeating alarm in the Clock app, or ask me for a single alarm.", es: "Crea la alarma repetitiva en la app Reloj, o pídeme una alarma única.")
            )
        }

        // A Clock alarm rings at the next time the clock shows HH:mm — it cannot be pinned to a later date.
        let nextRing = nextOccurrence(hour: time.hour, minute: time.minute, context: context)
        if let day = call.string("date").flatMap(ISODates.parseDateParts),
           let requested = context.calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day)),
           !DateMath.sameDay(requested, nextRing, calendar: context.calendar) {
            let nextText = Formatting.dateTime(nextRing, calendar: context.calendar, language: language)
            throw JarvisError.failed("alarm_date_mismatch", en: "A Clock alarm rings the next time the clock reaches \(call.string("time") ?? ""), which would be \(nextText) — not the day you asked for. I didn't create it. Ask again closer to the day, or use a reminder if you only need a notification.", es: "Una alarma del Reloj suena la próxima vez que el reloj llega a las \(call.string("time") ?? ""), que sería \(nextText), no el día que pediste. No la creé. Pídemela más cerca del día, o usa un recordatorio si solo necesitas un aviso.")
        }

        try await require([.createAlarm], context: context, because: LocalizedText(en: "I can't create alarms yet.", es: "Todavía no puedo crear alarmas."))
        let canVerify = await isInstalled(.listAlarms, context)
        let before = canVerify ? try await readAlarms(context) : []

        let label = call.string("label") ?? ""
        var input: JSONObject = [
            "hour": .int(time.hour), "minute": .int(time.minute), "time": .string(ISODates.timeString(hour: time.hour, minute: time.minute)),
            "iso": .string(ISODates.string(from: nextRing, timeZone: context.timeZone).replacingOccurrences(of: #"[+-]\d{2}:\d{2}$"#, with: "", options: .regularExpression)),
        ]
        input["label"] = .string(label)
        try await run(.createAlarm, input: input, context: context)

        var verification: Verification = .unverified(language.pick(
            "The shortcut ran, but “Jarvis List Alarms” is not installed, so I could not read the alarm back.",
            "El atajo se ejecutó, pero «Jarvis List Alarms» no está instalado, así que no pude leer la alarma de vuelta."
        ))
        if canVerify {
            let after = try await readAlarms(context)
            func count(_ alarms: [ClockAlarm]) -> Int { alarms.filter { $0.hour == time.hour && $0.minute == time.minute && TextFolding.fold($0.label) == TextFolding.fold(label) }.count }
            guard count(after) > count(before) else {
                throw JarvisError.verificationFailed(LocalizedText(
                    en: "The shortcut ran but the new alarm does not appear in the Clock app's alarm list.",
                    es: "El atajo se ejecutó pero la alarma nueva no aparece en la lista de alarmas del Reloj."
                ))
            }
            verification = .verified(language.pick("The alarm now appears in Clock's alarm list.", "La alarma ya aparece en la lista de alarmas del Reloj."))
        }
        let when = Formatting.dateTime(nextRing, calendar: context.calendar, language: language)
        let labelText = label.isEmpty ? "" : " (\(label))"
        return .done(ToolOutput(
            message: language.pick("Alarm set for \(call.string("time") ?? "")\(labelText) — it will ring \(when).", "Alarma puesta a las \(call.string("time") ?? "")\(labelText); sonará \(when)."),
            data: ["time": .string(call.string("time") ?? ""), "label": label.isEmpty ? .null : .string(label), "next_ring": .string(ISODates.string(from: nextRing, timeZone: context.timeZone))],
            verification: verification
        ))
    }

    private func nextOccurrence(hour: Int, minute: Int, context: ExecutionContext) -> Date {
        let today = DateMath.combine(day: context.now, hour: hour, minute: minute, calendar: context.calendar)
        if today > context.now { return today }
        let tomorrow = context.calendar.date(byAdding: .day, value: 1, to: context.now) ?? context.now.addingTimeInterval(86_400)
        return DateMath.combine(day: tomorrow, hour: hour, minute: minute, calendar: context.calendar)
    }

    // MARK: alarms.list

    private func listAlarms(_ context: ExecutionContext) async throws -> ToolOutcome {
        let language = context.language
        try await require([.listAlarms], context: context, because: LocalizedText(en: "I can't read your alarms yet.", es: "Todavía no puedo leer tus alarmas."))
        let alarms = try await readAlarms(context).sorted { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
        guard !alarms.isEmpty else {
            return .done(ToolOutput(message: language.pick("You have no alarms.", "No tienes alarmas."), data: ["alarms": [], "count": 0], verification: .notApplicable))
        }
        return .done(ToolOutput(
            message: language.pick("You have \(alarms.count) alarm\(alarms.count == 1 ? "" : "s"):\n", "Tienes \(alarms.count) alarma\(alarms.count == 1 ? "" : "s"):\n") + Formatting.bullets(alarms.map { $0.display(language) }),
            data: ["alarms": .array(alarms.map(\.json)), "count": .int(alarms.count)], verification: .notApplicable
        ))
    }

    // MARK: Selecting alarms

    private enum AlarmSelection {
        case one(ClockAlarm, all: [ClockAlarm])
        case outcome(ToolOutcome)
    }

    private func select(_ call: ValidatedToolCall, _ context: ExecutionContext) async throws -> AlarmSelection {
        let language = context.language
        let alarms = try await readAlarms(context)
        let wantedTime = call.string("time").flatMap(ISODates.parseTime)
        let ambiguous = call.bool("time_is_ambiguous") == true
        let label = call.string("label")

        var matches = alarms.filter { alarm in
            if let wantedTime {
                let exact = alarm.hour == wantedTime.hour && alarm.minute == wantedTime.minute
                let twin = ambiguous && alarm.minute == wantedTime.minute && alarm.hour == (wantedTime.hour + 12) % 24
                if !(exact || twin) { return false }
            }
            if let label, NameMatcher.score(query: label, candidate: alarm.label) < 60 { return false }
            return true
        }
        matches.sort { ($0.hour, $0.minute) < ($1.hour, $1.minute) }

        guard !matches.isEmpty else {
            let known = alarms.isEmpty ? language.pick("You have no alarms.", "No tienes alarmas.") : language.pick("Your alarms: ", "Tus alarmas: ") + alarms.map { $0.display(language) }.joined(separator: ", ")
            throw JarvisError.notFound("alarm_not_found", en: "I couldn't find that alarm. \(known)", es: "No encontré esa alarma. \(known)")
        }
        if matches.count == 1 { return .one(matches[0], all: alarms) }

        var options: [ClarificationOption] = []
        for alarm in matches {
            var arguments = call.arguments
            arguments["time"] = .string(alarm.time)
            arguments["time_is_ambiguous"] = false
            if !alarm.label.isEmpty { arguments["label"] = .string(alarm.label) }
            options.append(ClarificationOption(label: alarm.display(language), call: ToolCall(tool: call.descriptor.name, arguments: arguments)))
        }
        return .outcome(.clarify(Clarification(
            question: language.pick("Which alarm do you mean?", "¿A qué alarma te refieres?"), options: options
        )))
    }

    // MARK: alarms.set_enabled

    private func setEnabled(_ call: ValidatedToolCall, _ context: ExecutionContext) async throws -> ToolOutcome {
        let language = context.language
        let enabled = call.bool("enabled") ?? true
        try await require([.listAlarms, .setAlarmEnabled], context: context, because: LocalizedText(en: "I can't switch alarms yet.", es: "Todavía no puedo activar o desactivar alarmas."))
        let alarm: ClockAlarm
        switch try await select(call, context) {
        case .one(let found, _): alarm = found
        case .outcome(let outcome): return outcome
        }
        if alarm.isEnabled == enabled {
            return .done(ToolOutput(
                message: enabled ? language.pick("The \(alarm.display(language)) alarm is already on.", "La alarma \(alarm.display(language)) ya estaba activada.") : language.pick("The \(alarm.display(language)) alarm is already off.", "La alarma \(alarm.display(language)) ya estaba desactivada."),
                data: alarm.json, verification: .verified(language.pick("Read from Clock.", "Leído desde Reloj."))
            ))
        }
        try await run(.setAlarmEnabled, input: ["hour": .int(alarm.hour), "minute": .int(alarm.minute), "state": .string(enabled ? "on" : "off"), "enabled": .bool(enabled)], context: context)
        let after = try await readAlarms(context).first { $0.hour == alarm.hour && $0.minute == alarm.minute && $0.label == alarm.label }
        guard let after, after.isEnabled == enabled else {
            throw JarvisError.verificationFailed(LocalizedText(en: "The shortcut ran but the alarm did not change state in Clock.", es: "El atajo se ejecutó pero la alarma no cambió de estado en Reloj."))
        }
        return .done(ToolOutput(
            message: enabled ? language.pick("Turned on the \(after.display(language)) alarm.", "Activé la alarma \(after.display(language)).") : language.pick("Turned off the \(after.display(language)) alarm.", "Desactivé la alarma \(after.display(language))."),
            data: after.json, verification: .verified(language.pick("Read the alarm back from Clock.", "Se volvió a leer la alarma en Reloj."))
        ))
    }

    // MARK: alarms.delete

    private func deleteAlarm(_ call: ValidatedToolCall, _ context: ExecutionContext) async throws -> ToolOutcome {
        let language = context.language
        try await require([.listAlarms, .deleteAlarm], context: context, because: LocalizedText(en: "I can't delete alarms yet.", es: "Todavía no puedo eliminar alarmas."))
        let alarm: ClockAlarm
        let existing: [ClockAlarm]
        switch try await select(call, context) {
        case .one(let found, let all): alarm = found; existing = all
        case .outcome(let outcome): return outcome
        }
        if !context.isConfirmed {
            var pinned: JSONObject = ["time": .string(alarm.time), "time_is_ambiguous": false]
            if !alarm.label.isEmpty { pinned["label"] = .string(alarm.label) }
            return .confirm(ConfirmationRequest(
                prompt: language.pick("Delete the \(alarm.display(language)) alarm?", "¿Eliminar la alarma \(alarm.display(language))?"),
                call: ToolCall(tool: .alarmsDelete, arguments: pinned), destructive: true
            ))
        }
        // The delete shortcut identifies alarms by time, so every alarm at that exact time goes with it.
        let sameTime = existing.filter { $0.hour == alarm.hour && $0.minute == alarm.minute }
        if sameTime.count > 1 {
            throw JarvisError.failed("alarm_time_shared", en: "You have \(sameTime.count) alarms at \(alarm.time); deleting one would delete them all, so I left them alone. Delete the one you want in the Clock app.", es: "Tienes \(sameTime.count) alarmas a las \(alarm.time); eliminar una borraría todas, así que no toqué ninguna. Elimina la que quieras en la app Reloj.")
        }
        try await run(.deleteAlarm, input: ["hour": .int(alarm.hour), "minute": .int(alarm.minute)], context: context)
        let remaining = try await readAlarms(context).filter { $0.hour == alarm.hour && $0.minute == alarm.minute }
        guard remaining.isEmpty else {
            throw JarvisError.verificationFailed(LocalizedText(en: "The shortcut ran but the alarm is still in Clock.", es: "El atajo se ejecutó pero la alarma sigue en Reloj."))
        }
        return .done(ToolOutput(
            message: language.pick("Deleted the \(alarm.display(language)) alarm.", "Eliminé la alarma \(alarm.display(language))."),
            data: alarm.json, verification: .verified(language.pick("The alarm is no longer in Clock's list.", "La alarma ya no está en la lista del Reloj."))
        ))
    }

    // MARK: timers

    private func startTimer(_ call: ValidatedToolCall, _ context: ExecutionContext) async throws -> ToolOutcome {
        let language = context.language
        let seconds = call.int("duration_seconds") ?? 0
        try await require([.startTimer], context: context, because: LocalizedText(en: "I can't start timers yet.", es: "Todavía no puedo iniciar temporizadores."))
        let canVerify = await isInstalled(.getTimer, context)

        var input: JSONObject = ["seconds": .int(seconds)]
        if let label = call.string("label") { input["label"] = .string(label) }
        try await run(.startTimer, input: input, context: context)

        var verification: Verification = .unverified(language.pick(
            "The shortcut ran, but “Jarvis Get Timer” is not installed, so I could not confirm the timer is running.",
            "El atajo se ejecutó, pero «Jarvis Get Timer» no está instalado, así que no pude confirmar que el temporizador esté en marcha."
        ))
        if canVerify {
            var remaining: Int?
            for attempt in 0..<4 {
                if attempt > 0 { try await Task.sleep(for: .milliseconds(600)) }
                remaining = Self.parseDuration(try? await run(.getTimer, context: context))
                if remaining != nil { break }
            }
            guard let remaining, remaining > 0, remaining <= seconds + 5 else {
                throw JarvisError.verificationFailed(LocalizedText(
                    en: "The shortcut ran but Clock does not report a running timer of about that length.",
                    es: "El atajo se ejecutó pero Reloj no indica un temporizador en marcha de esa duración."
                ))
            }
            verification = .verified(language.pick("Clock reports a running timer with about \(Self.describe(remaining, language)) left.", "Reloj indica un temporizador en marcha con unos \(Self.describe(remaining, language)) restantes."))
        }
        var warnings: [String] = []
        if call.string("label") != nil {
            warnings.append(language.pick("Clock's timer action cannot store a label, so the name was not saved.", "La acción de temporizador del Reloj no puede guardar una etiqueta, así que el nombre no se guardó."))
        }
        return .done(ToolOutput(
            message: language.pick("Timer started for \(Self.describe(seconds, language)).", "Temporizador iniciado por \(Self.describe(seconds, language))."),
            data: ["duration_seconds": .int(seconds)], verification: verification, warnings: warnings
        ))
    }

    private func cancelTimer(_ context: ExecutionContext) async throws -> ToolOutcome {
        let language = context.language
        try await require([.cancelTimer], context: context, because: LocalizedText(en: "I can't cancel timers yet.", es: "Todavía no puedo cancelar temporizadores."))
        let canVerify = await isInstalled(.getTimer, context)
        try await run(.cancelTimer, context: context)
        var verification: Verification = .unverified(language.pick("The shortcut ran, but “Jarvis Get Timer” is not installed, so I could not confirm the timer stopped.", "El atajo se ejecutó, pero «Jarvis Get Timer» no está instalado, así que no pude confirmar que el temporizador se detuvo."))
        if canVerify {
            try await Task.sleep(for: .milliseconds(600))
            let remaining = Self.parseDuration(try? await run(.getTimer, context: context))
            guard remaining == nil || remaining == 0 else {
                throw JarvisError.verificationFailed(LocalizedText(en: "The shortcut ran but Clock still reports a running timer.", es: "El atajo se ejecutó pero Reloj sigue indicando un temporizador en marcha."))
            }
            verification = .verified(language.pick("Clock no longer reports a running timer.", "Reloj ya no indica ningún temporizador en marcha."))
        }
        return .done(ToolOutput(message: language.pick("Timer cancelled.", "Temporizador cancelado."), data: ["cancelled": true], verification: verification))
    }

    // MARK: Parsing and formatting

    /// Reads "9.5 min", "9,5 min", "570 sec", "1 hr 5 min", "00:09:30" into seconds. `nil` when nothing parseable.
    static func parseDuration(_ text: String?) -> Int? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if let match = text.range(of: #"^(\d+):(\d{2})(?::(\d{2}))?$"#, options: .regularExpression) {
            let parts = text[match].split(separator: ":").compactMap { Int($0) }
            if parts.count == 3 { return parts[0] * 3600 + parts[1] * 60 + parts[2] }
            if parts.count == 2 { return parts[0] * 60 + parts[1] }
        }
        guard let regex = try? NSRegularExpression(pattern: #"(\d+(?:[.,]\d+)?)\s*([A-Za-zÀ-ÿ]+)"#) else { return nil }
        var total = 0.0
        var found = false
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let numberRange = Range(match.range(at: 1), in: text), let unitRange = Range(match.range(at: 2), in: text),
                  let value = Double(text[numberRange].replacingOccurrences(of: ",", with: ".")) else { continue }
            let unit = TextFolding.fold(String(text[unitRange]))
            if unit.hasPrefix("h") { total += value * 3600; found = true }
            else if unit.hasPrefix("min") || unit == "m" { total += value * 60; found = true }
            else if unit.hasPrefix("s") { total += value; found = true }
        }
        return found ? Int(total.rounded()) : nil
    }

    static func describe(_ seconds: Int, _ language: Language) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        var parts: [String] = []
        if hours > 0 { parts.append(language.pick("\(hours) hour\(hours == 1 ? "" : "s")", "\(hours) hora\(hours == 1 ? "" : "s")")) }
        if minutes > 0 { parts.append(language.pick("\(minutes) minute\(minutes == 1 ? "" : "s")", "\(minutes) minuto\(minutes == 1 ? "" : "s")")) }
        if secs > 0 || parts.isEmpty { parts.append(language.pick("\(secs) second\(secs == 1 ? "" : "s")", "\(secs) segundo\(secs == 1 ? "" : "s")")) }
        return parts.joined(separator: language.pick(" and ", " y "))
    }
}
