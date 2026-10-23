import Foundation
import JarvisCore

/// English/Spanish rules for alarms and timers (executed through Shortcuts, see `ClockIntegration`).
struct ClockRules: IntentRuleSet {
    private static let alarmNoun = Rx.make(#"\b(?:alarms?|alarmas?)\b"#)
    private static let timerNoun = Rx.make(#"\b(?:timers?|temporizadors?|temporizador(?:es)?|cuenta atras|cuenta regresiva)\b"#)

    private static let createAlarm = Rx.make(#"^(?:set|create|add|make|schedule|program|start|put|ponme|pon|poner|programa|programar|crea|crear|configura|configurar|agrega|agregar|activa)\s+(?:me\s+|us\s+)?(?:(?:an?|one|una|la|mi|my|the)\s+)?(?:new\s+|nueva\s+)?(?:alarm|alarma)\b(?<rest>.*)$"#)
    /// "alarm at 7 tomorrow" / "alarma a las 7": a bare noun-first request.
    private static let bareAlarm = Rx.make(#"^(?:(?:an?|one|una|new|nueva)\s+)?(?:alarm|alarma)\b(?<rest>.*)$"#)
    /// "for 7" and "de las 7" name a time of day when talking about an alarm ("an alarm for 7", "la alarma de las 7").
    private static let hourPreposition = Rx.make(#"(?<![a-z\d])(?<prep>for|para|de)\s+(?=(?:las?\s+)?\d{1,2}(?::\d{2})?(?:\s*(?:am|pm|a\.m|p\.m)\.?)?(?![\d:]|\s*(?:min|sec|hour|hr|day|week|month|segundo|hora|dia|semana|mes)))"#)
    static func readingHourPrepositions(_ text: FoldedText) -> FoldedText {
        var result = text
        for match in text.matches(hourPreposition, groupNames: ["prep"]) {
            guard let range = match.group("prep") else { continue }
            let replacement: String
            switch text.foldedSlice(range) {
            case "for": replacement = "at "
            case "para": replacement = "at  "
            default: replacement = "a "
            }
            result = result.replacingFolded(range, with: replacement)
        }
        return result
    }
    private static let meridiemWords = Rx.make(#"\b(?:am|pm|a\.m\.?|p\.m\.?|morning|afternoon|evening|night|noon|manana|tarde|noche|madrugada|mediodia)\b"#)
    private static let firstNumber = Rx.make(#"(\d{1,2})"#)
    private static let wakeMe = Rx.make(#"^(?:wake me(?: up)?|wake us(?: up)?|get me up|despiertame|despierta me|levantame|despiertanos)\b(?<rest>.*)$"#)
    private static let listAlarms = Rx.make(#"^(?:(?:list|show|display|what|which|get|see|check|muestra|muestrame|lista|listar|cuales|que|dime|ver|revisa)\s+)(?:(?:are|is|do i have|tengo|son|hay|have i got)\s+)*(?:(?:my|all|the|mis|todas|las)\s+)*(?:alarms|alarmas)(?:\s+(?:do i have|i have|tengo|que tengo|set|puestas|programadas|activas|have i set|tengo puestas))*\s*\??$"#)
    private static let toggleAlarm = Rx.make(#"^(?<verb>turn|switch|disable|enable|deactivate|activate|apaga|apagar|enciende|encender|desactiva|desactivar|activa|activar|deshabilita|deshabilitar|habilita|habilitar)\s+(?<p1>off|on)?\s*(?:(?:my|the|mi|la|el)\s+)?(?<which>.*?)\s*(?:alarm|alarma)(?:\s+(?<p2>off|on))?(?<tail>.*)$"#)
    private static let deleteAlarm = Rx.make(#"^(?:delete|remove|cancel|erase|clear|elimina|eliminar|borra|borrar|cancela|cancelar|quita|quitar)\s+(?:(?:my|the|mi|la|el)\s+)?(?<which>.*?)\s*(?:alarm|alarma)(?<tail>.*)$"#)

    private static let createTimer = Rx.make(#"^(?:set|start|create|begin|make|put|run|launch|ponme|pon|poner|inicia|iniciar|programa|programar|crea|crear|empieza|empezar|arranca|activa|configura|configurar|dame)\s+(?:me\s+)?(?:(?:an?|un|una|the|el)\s+)?(?:new\s+|nuevo\s+)?(?<rest>.*)$"#)
    private static let bareTimer = Rx.make(#"^(?:timer|temporizador|cuenta atras)\b(?<rest>.*)$"#)
    private static let cancelTimer = Rx.make(#"^(?:cancel|stop|delete|clear|kill|turn off|end|cancela|cancelar|deten|detener|elimina|borra|apaga|para|parar|quita)\s+(?:(?:my|the|mi|el)\s+)?(?:\w+\s+)?(?:timer|temporizador)\s*$"#)

    private static let label = Rx.make(#"(?:^|\s)(?:called|named|labeled|labelled|titled|label|llamada|llamado|etiquetada|etiquetado|con la etiqueta|con el nombre|con nombre)\s*:?\s+(?<label>.+)$"#)
    /// `set an alarm “Gym” for 6`, `pon una alarma «Gimnasio» a las 6`: a quoted span with no keyword is the label.
    private static let quotedLabel = Rx.make(#"(?<label>\#(FoldedText.maskCharacter)+)"#)
    private static let labelFor = Rx.make(#"(?:^|\s)(?:to|para)\s+(?<label>(?:go|wake|get|take|take|ir|despertar|levantarme|tomar|salir|hacer|estudiar|study|work|trabajar)\b.+)$"#)

    // Repeat phrases. They are cut out before date parsing so "every Monday" is not read as a one-off date.
    private static let everyDay = Rx.make(#"\b(?:every day|everyday|daily|each day|todos los dias|cada dia|a diario|diariamente|diaria)\b"#)
    private static let weekdays = Rx.make(#"\b(?:every weekday|on weekdays|weekdays|each weekday|de lunes a viernes|entre semana|cada dia laborable|dias laborables|dias laborales)\b"#)
    private static let weekends = Rx.make(#"\b(?:every weekend|on weekends|weekends|each weekend|los fines de semana|cada fin de semana|fines de semana)\b"#)
    private static let everyNamedDay = Rx.make(#"\b(?:every|each|cada|todos los|todas las|los|las)\s+(?<days>(?:(?:sunday|monday|tuesday|wednesday|thursday|friday|saturday|domingo|lunes|martes|miercoles|jueves|viernes|sabado)s?(?:\s*(?:,|and|y|e)\s*)?)+)"#)

    private static let dayCodes: [String: String] = [
        "sunday": "sun", "monday": "mon", "tuesday": "tue", "wednesday": "wed", "thursday": "thu", "friday": "fri", "saturday": "sat",
        "domingo": "sun", "lunes": "mon", "martes": "tue", "miercoles": "wed", "jueves": "thu", "viernes": "fri", "sabado": "sat",
    ]

    func interpret(_ clause: Clause) -> [RuleResult] {
        var results: [RuleResult] = []
        let folded = clause.folded
        guard !folded.isEmpty else { return [] }
        let hasAlarm = clause.find(Self.alarmNoun) != nil
        let hasTimer = clause.find(Self.timerNoun) != nil
        guard hasAlarm || hasTimer || clause.whole(Self.wakeMe, groups: ["rest"]) != nil else { return [] }
        let cal = clause.context.calendar
        // "an alarm for 7", "la alarma de las 7": read the preposition as "at" so the time is found.
        let clause = hasAlarm && !hasTimer ? Clause(text: Self.readingHourPrepositions(clause.text), context: clause.context) : clause

        // --- Listing
        if clause.whole(Self.listAlarms, groups: []) != nil {
            results.append(.calls([ToolCall(tool: .alarmsList)], confidence: 0.93))
        }

        // --- Timers
        if hasTimer {
            if clause.whole(Self.cancelTimer, groups: []) != nil {
                results.append(.calls([ToolCall(tool: .timersCancel)], confidence: 0.92))
            } else if let result = timerCall(clause) {
                results.append(result)
            }
        }

        // --- Alarms
        if hasAlarm || clause.whole(Self.wakeMe, groups: ["rest"]) != nil {
            if let match = clause.whole(Self.toggleAlarm, groups: ["verb", "p1", "p2", "which", "tail"]) {
                let verb = match.folded("verb") ?? ""
                let particle = match.folded("p1") ?? match.folded("p2")
                let off = ["disable", "deactivate", "apaga", "apagar", "desactiva", "desactivar", "deshabilita", "deshabilitar"].contains(verb)
                    || particle == "off"
                let on = ["enable", "activate", "enciende", "encender", "activa", "activar", "habilita", "habilitar"].contains(verb) || particle == "on"
                if off || on, particle != nil || verb != "turn" && verb != "switch" {
                    let selector = alarmSelector(match, context: clause.context, calendar: cal)
                    var arguments = selector
                    arguments["enabled"] = .bool(on && !off)
                    results.append(.calls([ToolCall(tool: .alarmsSetEnabled, arguments: arguments)], confidence: 0.9))
                }
            }
            if let match = clause.whole(Self.deleteAlarm, groups: ["which", "tail"]) {
                let selector = alarmSelector(match, context: clause.context, calendar: cal)
                results.append(.calls([ToolCall(tool: .alarmsDelete, arguments: selector)], confidence: 0.88))
            }
            if let result = createAlarm(clause) { results.append(result) }
        }
        return results
    }

    // MARK: Alarm creation

    private func createAlarm(_ clause: Clause) -> RuleResult? {
        var restRange: Range<Int>?
        if let match = clause.whole(Self.createAlarm, groups: ["rest"]) { restRange = match.range("rest") }
        else if let match = clause.whole(Self.wakeMe, groups: ["rest"]) { restRange = match.range("rest") }
        else if let match = clause.whole(Self.bareAlarm, groups: ["rest"]) { restRange = match.range("rest") }
        guard let restRange else { return nil }
        var rest = clause.text.slice(restRange).collapsedWhitespace()
        let cal = clause.context.calendar

        // Repeat days.
        var repeatDays: [String] = []
        var cut: [Range<Int>] = []
        if let match = rest.findMatch(Self.weekdays) { repeatDays = ["mon", "tue", "wed", "thu", "fri"]; cut.append(match.range) }
        else if let match = rest.findMatch(Self.weekends) { repeatDays = ["sat", "sun"]; cut.append(match.range) }
        else if let match = rest.findMatch(Self.everyDay) { repeatDays = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]; cut.append(match.range) }
        else if let match = rest.findMatch(Self.everyNamedDay, groups: ["days"]), let range = match.range("days") {
            let words = rest.foldedSlice(range).split(whereSeparator: { !$0.isLetter }).map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "s")) }
            for word in words {
                let key = Self.dayCodes.keys.first { $0 == word || $0 == word + "s" || word.hasPrefix($0) }
                if let key, let code = Self.dayCodes[key], !repeatDays.contains(code) { repeatDays.append(code) }
            }
            cut.append(match.range)
        }
        if !cut.isEmpty { rest = rest.removing(cut) }

        var context = clause.context
        context.ambiguousHours = .morningFirst
        let when = NaturalDateParser().parse(rest, context: context)
        let remainder = TextCleanup.trimConnectors(rest.removing(when.consumed))

        // Label ("called Gym", "to go to the gym") – looked up after the time so it cannot swallow it.
        var labelText: String?
        if let found = remainder.findMatch(Self.label, groups: ["label"]), let range = found.range("label") {
            labelText = TextCleanup.title(remainder.original(range))
        } else if let found = remainder.findMatch(Self.labelFor, groups: ["label"]), let range = found.range("label") {
            labelText = TextCleanup.title(remainder.original(range))
        } else if let found = remainder.findMatch(Self.quotedLabel, groups: ["label"]), let range = found.range("label") {
            labelText = TextCleanup.title(remainder.original(range))
        }

        guard when.timeIsExplicit, let hour = when.hour, let minute = when.minute else {
            return .clarify(
                LocalizedText(en: "What time should the alarm ring?", es: "¿A qué hora debe sonar la alarma?"),
                confidence: 0.85
            )
        }
        var arguments: JSONObject = ["time": ArgumentBuilders.time(hour: hour, minute: minute)]
        if when.hasDate, let day = when.day { arguments["date"] = ArgumentBuilders.day(day, calendar: cal) }
        if let labelText, !labelText.isEmpty { arguments["label"] = .string(labelText) }
        if !repeatDays.isEmpty { arguments["repeat_days"] = .array(repeatDays.map(JSONValue.string)) }
        return .calls([ToolCall(tool: .alarmsCreate, arguments: arguments, assumptions: when.assumptions)], confidence: 0.95)
    }

    // MARK: Alarm selectors

    private func alarmSelector(_ match: MatchedClause, context: DateContext, calendar: Calendar) -> JSONObject {
        var arguments: JSONObject = [:]
        let whichText = [match.range("which"), match.range("tail")].compactMap { range -> String? in
            guard let range else { return nil }
            return match.text.original(range)
        }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !whichText.isEmpty else { return arguments }
        let folded = Self.readingHourPrepositions(FoldedText(whichText))
        let when = NaturalDateParser().parse(folded, context: context)
        if when.timeIsExplicit, let hour = when.hour, let minute = when.minute {
            arguments["time"] = ArgumentBuilders.time(hour: hour, minute: minute)
            // The user's own words decide: an AM/PM or part-of-day word, or a 24-hour number (19:00, 0:30), makes the time
            // exact. The resolved hour cannot be used: the parser turns a bare "7" into 19:00 by its own policy.
            let words = Self.meridiemWords.firstMatch(in: folded.folded, range: NSRange(folded.folded.startIndex..., in: folded.folded)) != nil
            let digits = Self.firstNumber.firstMatch(in: folded.folded, range: NSRange(folded.folded.startIndex..., in: folded.folded))
                .flatMap { Range($0.range(at: 1), in: folded.folded) }.flatMap { Int(folded.folded[$0]) }
            let written24Hour = digits.map { $0 > 12 || $0 == 0 } ?? false
            if !words && !written24Hour { arguments["time_is_ambiguous"] = true }
        }
        let leftover = TextCleanup.trimConnectors(folded.removing(when.consumed))
        let label = TextCleanup.name(leftover.original)
        let filler: Set<String> = ["", "the", "my", "mi", "el", "la", "all", "todas", "todo", "of", "de", "at", "a", "las", "alarm", "alarma"]
        if !filler.contains(label.lowercased()) { arguments["label"] = .string(label) }
        return arguments
    }

    // MARK: Timers

    private func timerCall(_ clause: Clause) -> RuleResult? {
        var rest = clause.text
        if let match = clause.whole(Self.createTimer, groups: ["rest"]), let range = match.range("rest") {
            rest = clause.text.slice(range)
        } else if let match = clause.whole(Self.bareTimer, groups: ["rest"]), let range = match.range("rest") {
            rest = clause.text.slice(range)
        } else if clause.find(Self.timerNoun) == nil {
            return nil
        }

        let when = NaturalDateParser().parse(rest, context: clause.context, allowBareDuration: true)
        let remainder = TextCleanup.trimConnectors(rest.removing(when.consumed))
        var label: String?
        if let found = remainder.findMatch(Self.label, groups: ["label"]), let range = found.range("label") {
            label = TextCleanup.title(remainder.original(range))
        } else if let found = remainder.findMatch(Self.quotedLabel, groups: ["label"]), let range = found.range("label") {
            label = TextCleanup.title(remainder.original(range))
        }
        guard let seconds = when.duration, seconds >= 1 else {
            return .clarify(LocalizedText(en: "How long should the timer run?", es: "¿Cuánto tiempo debe durar el temporizador?"), confidence: 0.85)
        }
        var arguments: JSONObject = ["duration_seconds": .int(Int(seconds.rounded()))]
        if let label, !label.isEmpty { arguments["label"] = .string(label) }
        return .calls([ToolCall(tool: .timersCreate, arguments: arguments)], confidence: 0.95)
    }
}
