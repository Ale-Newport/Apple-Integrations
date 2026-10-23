import Foundation
import JarvisCore

/// English/Spanish rules for Apple Calendar (events).
struct CalendarRules: IntentRuleSet {
    private static let eventNouns = Rx.make(#"\b(?:meetings?|appointments?|events?|calls?|class(?:es)?|lectures?|lessons?|sessions?|dinner|lunch|breakfast|interviews?|dentist|doctor|flights?|trips?|parties|party|birthday|conference|presentation|visit|reunion(?:es)?|citas?|eventos?|clases?|llamadas?|cena|almuerzo|desayuno|entrevistas?|dentista|medico|conferencia|presentacion|visita|vuelo|viaje|fiesta|cumpleanos|junta|juntas|examen|exam|standup|sync|review)\b"#)
    private static let calendarNouns = Rx.make(#"\b(?:calendar|calendars|schedule|scheduled|agenda|calendario|calendarios|agendado|agendados|programado|programados|planned|planeado)\b"#)
    private static let otherDomain = Rx.make(#"\b(?:reminders?|recordatorios?|notes?|notas?|alarms?|alarmas?|timers?|temporizadors?|temporizador|playlist|playlists|song|music|musica|cancion)\b"#)

    private static let queryStarter = Rx.make(#"^(?:show|list|display|what|which|see|get|check|tell me|give me|do i have|have i|whats|what's|are there|is there|how many|how's|hows|muestra|muestrame|mostrar|lista|listar|dime|cuales|que|ver|revisa|consulta|tengo|tienes|hay|cuantos|cuantas|mi agenda|my schedule|my calendar|mi calendario)\b"#)
    private static let listCalendars = Rx.make(#"^(?:(?:list|show|display|what|which|get|see|muestra|muestrame|lista|listar|cuales|que|dime|ver)\s+)(?:(?:are|is|do i have|tengo|son|hay)\s+)*(?:(?:my|all|the|mis|todos|los)\s+)*(?:calendars|calendarios)(?:\s+(?:do i have|i have|tengo|que tengo))?\s*\??$"#)
    private static let createVerb = Rx.make(#"^(?:schedule|create|add|book|set up|put|make|new|plan|arrange|organize|organise|agenda|agendar|crea|crear|agrega|agregar|anade|anadir|programa|programar|reserva|reservar|pon|poner|nuevo|nueva|organiza|apunta)\s+(?:me\s+|nos\s+)?(?<rest>.+)$"#)
    private static let toCalendarTail = Rx.make(#"\s+(?:to|on|in|into|onto|a|en|al)\s+(?:my\s+|the\s+|mi\s+|el\s+)?(?:(?<cal>[^\s]+(?:\s+[^\s]+){0,2}?)\s+)?(?:calendar|calendario)(?:\s+(?:called|named|llamado)\s+(?<cal2>\S+(?:\s+\S+){0,2}))?$"#)
    private static let calendarPrefix = Rx.make(#"\s+(?:to|on|in|into|onto|a|en|al)\s+(?:my\s+|the\s+|mi\s+|el\s+)?(?:calendar|calendario)\s+(?:called\s+|named\s+|llamado\s+)?(?<cal>\S+(?:\s+\S+){0,2})$"#)
    private static let leadingDeterminer = Rx.make(#"^(?:(?:a|an|the|my|our|some|un|una|el|la|mi|mis|unos|unas|another|otra|otro)\s+)+"#)
    private static let locationPhrase = Rx.make(#"\s+(?:at|in|@|en)\s+(?<loc>(?:the\s+|la\s+|el\s+)?\p{Lu}[^,]*)$"#)
    private static let withPeople = Rx.make(#"\b(?:with|con)\s+(?<who>(?:the\s+|el\s+|la\s+)?\p{Lu}[\p{L}'-]*(?:\s+(?:and\s+|y\s+)?\p{Lu}[\p{L}'-]*)*)"#)
    private static let allDayWords = Rx.make(#"\b(?:all[- ]day|todo el dia|dia completo)\b"#)

    private static let freeBusy = Rx.make(#"^(?:am i|are we|will i be|estoy|estare|estamos)\s+(?:free|busy|available|libre|ocupado|disponible|ocupada)\b"#)
    private static let conflicts = Rx.make(#"\b(?:conflicts?|overlaps?|clash(?:es)?|double[- ]booked?|conflictos?|solapamientos?|choques?)\b"#)

    private static let updateVerb = Rx.make(#"^(?<verb>move|reschedule|change|shift|postpone|push|delay|update|set|make|reprograma|reprogramar|mueve|mover|cambia|cambiar|pospon|posponer|pasa|pasar|actualiza|actualizar|adelanta|atrasa|retrasa)\s+(?<body>.+)$"#)
    private static let renameEvent = Rx.make(#"^(?:rename|retitle|renombra|renombrar|cambia el nombre de)\s+(?<target>.+?)\s+(?:to|as|a|como)\s+(?<new>.+)$"#)
    private static let changeLocation = Rx.make(#"^(?:change|set|update|move|cambia|cambiar|actualiza|pon|poner)\s+(?:the\s+|la\s+|el\s+)?(?:location|place|venue|ubicacion|lugar)\s+(?:of|for|de|del)\s+(?<target>.+?)\s+(?:to|as|a|en)\s+(?<loc>.+)$"#)
    private static let makeLong = Rx.make(#"^(?:make|set|change|haz|pon|cambia)\s+(?<target>.+?)\s+(?:to be\s+|a\s+|de\s+|con duracion de\s+)?(?<dur>.+?)\s*(?:long|de duracion)?$"#)
    /// "cancel tomorrow's meeting": once the date is cut out, a possessive 's is left at the front.
    private static let leadingPossessive = Rx.make(#"^'s\b\s*"#)
    /// Words that name the *kind* of event; with a date they select by date instead of by title.
    private static let structuralNouns: Set<String> = ["meeting", "meetings", "appointment", "appointments", "reunion", "reuniones", "cita", "citas", "call", "llamada"]
    /// "when is my next meeting", "cuál es mi próxima reunión"
    private static let nextEvent = Rx.make(#"^(?:(?:when|what|which|show me|tell me|cuando|cual|muestrame|dime)(?:'s| is| es| sera)?\s+)?(?:(?:is|are|es|sera)\s+)?(?:(?:my|the|mi|la|el)\s+)?(?:next|upcoming|proxim[ao]|siguiente)\s+(?:calendar\s+)?(?:meeting|event|appointment|reunion|evento|cita)\s*\??$"#)
    /// "is Friday afternoon free", "está libre el viernes por la tarde"
    private static let freeBusyTail = Rx.make(#"^(?:is|are|esta|estan|estoy)\s+(?<when>.+?)\s+(?:free|busy|available|libre|ocupad[oa]|disponible)\s*\??$"#)
    /// "an event called Project Review", "una reunión llamada Revisión": the name after the marker is the title.
    private static let namedEvent = Rx.make(#"^(?:(?:an?|the|my|un|una|el|la|mi)\s+)?(?:new\s+|nuevo\s+|nueva\s+)?(?<noun>[\p{L}'-]+)\s+(?:called|named|titled|llamad[oa]|titulad[oa])\s+(?<title>.+)$"#)
    private static let connector = Rx.make(#"\s+(?:to|for|until|till|a|al|para|hasta|at|by)\s+"#)
    private static let deleteVerb = Rx.make(#"^(?:delete|remove|cancel|erase|drop|elimina|eliminar|borra|borrar|cancela|cancelar|quita|quitar)\s+(?<target>.+)$"#)

    func interpret(_ clause: Clause) -> [RuleResult] {
        var results: [RuleResult] = []
        let folded = clause.folded
        guard !folded.isEmpty else { return [] }
        var context = clause.context
        context.ambiguousHours = .businessHours
        let calendarClause = Clause(text: clause.text, context: context)
        let cal = context.calendar
        let hasEventNoun = clause.find(Self.eventNouns) != nil
        let hasCalendarNoun = clause.find(Self.calendarNouns) != nil
        let mentionsOther = clause.find(Self.otherDomain) != nil

        if clause.whole(Self.listCalendars, groups: []) != nil {
            results.append(.calls([ToolCall(tool: .calendarListCalendars)], confidence: 0.92))
        }

        let parsed = calendarClause.parseDates()
        let when = parsed.when
        let rest = TextCleanup.trimConnectors(parsed.remainder)

        // --- Next event
        if clause.whole(Self.nextEvent, groups: []) != nil {
            let start = context.now
            let end = cal.date(byAdding: .day, value: 90, to: start) ?? start
            results.append(.calls([ToolCall(tool: .calendarListEvents, arguments: [
                "start": ArgumentBuilders.dateTime(start, calendar: cal), "end": ArgumentBuilders.dateTime(end, calendar: cal), "limit": 1,
            ])], confidence: 0.9))
        }

        // --- Free / busy and conflicts
        if clause.find(Self.freeBusy) != nil || clause.whole(Self.freeBusyTail, groups: ["when"]) != nil || (clause.find(Self.conflicts) != nil && !mentionsOther) {
            if let window = conflictWindow(when, context: context) {
                results.append(.calls([ToolCall(tool: .calendarCheckConflicts, arguments: window, assumptions: when.assumptions)], confidence: 0.88))
            } else {
                results.append(.clarify(LocalizedText(en: "For which day and time should I check?", es: "¿Para qué día y hora debo revisar?"), confidence: 0.8))
            }
        }

        // --- Update (reschedule, rename, relocate)
        if let call = updateCall(clause: clause, calendarClause: calendarClause, context: context) { results.append(call) }

        // --- Delete / cancel
        if let match = Rx.matchWhole(Self.deleteVerb, clause.text, groups: ["target"]), let target = match.range("target") {
            let targetText = clause.text.slice(target)
            let hasSignal = clause.find(Self.eventNouns) != nil || clause.find(Self.calendarNouns) != nil || !parsed.when.isEmpty
            if hasSignal && !(mentionsOther && !hasEventNoun && !hasCalendarNoun) {
                let selector = selectorArguments(from: targetText, context: context)
                if !selector.arguments.isEmpty {
                    let confidence = hasEventNoun || hasCalendarNoun ? 0.88 : 0.6
                    results.append(.calls([ToolCall(tool: .calendarDeleteEvent, arguments: selector.arguments, assumptions: selector.assumptions)], confidence: confidence))
                }
            }
        }

        // --- List events
        let startsAsQuery = clause.find(Self.queryStarter).map { $0.range.lowerBound == 0 } ?? false
        let isToDoQuestion = folded.contains("have to do") || folded.contains("need to do") || folded.contains("tengo que hacer") || folded.contains("hay que hacer")
        if startsAsQuery, !isToDoQuestion, (hasCalendarNoun || hasEventNoun || !when.isEmpty || folded.hasPrefix("my schedule") || folded.hasPrefix("mi agenda")),
           clause.find(Self.freeBusy) == nil, clause.whole(Self.listCalendars, groups: []) == nil, !(mentionsOther && !hasCalendarNoun && !hasEventNoun) {
            var arguments: JSONObject = [:]
            if let window = ArgumentBuilders.window(when, calendar: cal) {
                arguments["start"] = ArgumentBuilders.dateTime(window.start, calendar: cal)
                arguments["end"] = ArgumentBuilders.dateTime(window.end, calendar: cal)
            } else {
                arguments["start"] = ArgumentBuilders.dateTime(context.now, calendar: cal)
                arguments["end"] = ArgumentBuilders.dateTime(cal.date(byAdding: .day, value: 7, to: context.now) ?? context.now, calendar: cal)
            }
            if when.instant != nil, when.timeIsExplicit, when.span == nil {
                // "what do I have tomorrow at 3?" → events overlapping that day (not just that hour).
                let day = cal.startOfDay(for: when.instant ?? context.now)
                arguments["start"] = ArgumentBuilders.dateTime(day, calendar: cal)
                arguments["end"] = ArgumentBuilders.dateTime(cal.date(byAdding: .day, value: 1, to: day) ?? day, calendar: cal)
            }
            if let name = Self.calendarName(in: rest) { arguments["calendar"] = .string(name) }
            results.append(.calls([ToolCall(tool: .calendarListEvents, arguments: arguments, assumptions: when.assumptions)], confidence: hasCalendarNoun || hasEventNoun ? 0.88 : 0.72))
        }

        // --- Create
        if let call = createCall(rest: rest, when: when, clause: clause, context: context, hasEventNoun: hasEventNoun, hasCalendarNoun: hasCalendarNoun, mentionsOther: mentionsOther) {
            results.append(call)
        }
        return results
    }

    // MARK: Create

    private func createCall(rest: FoldedText, when: ParsedWhen, clause: Clause, context: DateContext, hasEventNoun: Bool, hasCalendarNoun: Bool, mentionsOther: Bool) -> RuleResult? {
        guard let match = Rx.matchWhole(Self.createVerb, rest, groups: ["rest"]), let restRange = match.range("rest") else { return nil }
        let verb = rest.foldedSlice(0..<restRange.lowerBound)
        let strongVerb = ["schedule", "agenda", "agendar", "book", "reserva", "reservar", "programa", "programar"].contains { verb.hasPrefix($0) }
        // "add dentist to my notes" / "remind me to schedule…": an explicit other destination wins over an event noun.
        if mentionsOther && !hasCalendarNoun && !strongVerb { return nil }
        guard hasEventNoun || hasCalendarNoun || strongVerb else { return nil }

        var body = rest.slice(restRange).collapsedWhitespace()
        let cal = context.calendar

        // Destination calendar ("… to my Work calendar").
        var calendarName: String?
        for regex in [Self.toCalendarTail, Self.calendarPrefix] {
            if let found = body.findMatch(regex, groups: ["cal", "cal2"]), found.range.upperBound == body.count {
                calendarName = (found.original("cal2") ?? found.original("cal")).map(TextCleanup.name)
                if calendarName?.lowercased() == "my" || calendarName?.lowercased() == "mi" { calendarName = nil }
                body = body.removing([found.range]).collapsedWhitespace()
                break
            }
        }

        // Location ("… at Starbucks"): only capitalised places, so "at noon" or "at home" stay in the title.
        var location: String?
        if let found = body.findMatchInOriginal(Self.locationPhrase, groups: ["loc"]), found.range.upperBound == body.count {
            location = found.original("loc").map(TextCleanup.name)
            let beforeLocation = body.slice(0..<found.range.lowerBound)
            if !beforeLocation.isEmpty { body = beforeLocation.collapsedWhitespace() } else { location = nil }
        }

        // Attendees ("with Daniel").
        var attendees: [String] = []
        if let found = body.findMatchInOriginal(Self.withPeople, groups: ["who"]), let who = found.original("who") {
            attendees = who.replacingOccurrences(of: " and ", with: ",").replacingOccurrences(of: " y ", with: ",")
                .split(separator: ",").map { TextCleanup.name(String($0)) }.filter { !$0.isEmpty }
        }

        // Title: leading determiners removed ("a meeting with Daniel" → "Meeting with Daniel").
        var titleText = body
        if let named = Rx.matchWhole(Self.namedEvent, body, groups: ["noun", "title"]), let nounRange = named.range("noun"), let nameRange = named.range("title"),
           body.slice(nounRange).firstMatch(Self.eventNouns) != nil {
            titleText = body.slice(nameRange)
        } else if let found = titleText.firstMatch(Self.leadingDeterminer), found.range.lowerBound == 0, found.range.upperBound < titleText.count {
            titleText = titleText.slice(found.range.upperBound..<titleText.count)
        }
        let title = TextCleanup.title(titleText.original)
        guard !title.isEmpty else {
            return .clarify(LocalizedText(en: "What should the event be called?", es: "¿Cómo se llama el evento?"), confidence: 0.8)
        }
        guard when.instant != nil || when.day != nil else {
            return .clarify(LocalizedText(en: "When should “\(title)” take place?", es: "¿Cuándo es «\(title)»?"), confidence: 0.82)
        }

        var arguments: JSONObject = ["title": .string(title)]
        let allDay = clause.find(Self.allDayWords) != nil || (when.instant == nil && !when.dayCameFromSpan)
        if let instant = when.instant, !allDay {
            arguments["start"] = ArgumentBuilders.dateTime(instant, calendar: cal)
            if when.rangeEnd != nil, let end = when.endInstant {
                arguments["end"] = ArgumentBuilders.dateTime(end, calendar: cal)
            } else if let duration = when.duration {
                arguments["duration_minutes"] = .int(max(1, Int((duration / 60).rounded())))
            }
        } else if let day = when.day {
            arguments["start"] = ArgumentBuilders.day(day, calendar: cal)
            arguments["all_day"] = true
        }
        if let calendarName, !calendarName.isEmpty { arguments["calendar"] = .string(calendarName) }
        if let location, !location.isEmpty { arguments["location"] = .string(location) }
        if !attendees.isEmpty { arguments["attendees"] = .array(attendees.map(JSONValue.string)) }
        let confidence = hasCalendarNoun ? 0.93 : (hasEventNoun ? 0.9 : 0.66)
        return .calls([ToolCall(tool: .calendarCreateEvent, arguments: arguments, assumptions: when.assumptions)], confidence: confidence)
    }

    // MARK: Update

    private func updateCall(clause: Clause, calendarClause: Clause, context: DateContext) -> RuleResult? {
        let cal = context.calendar
        let text = clause.text
        let hasSignal = clause.find(Self.eventNouns) != nil || clause.find(Self.calendarNouns) != nil
        let mentionsOther = clause.find(Self.otherDomain) != nil

        if let match = Rx.matchWhole(Self.renameEvent, text, groups: ["target", "new"]), hasSignal,
           let targetRange = match.range("target"), let newTitle = match.original("new").map(TextCleanup.title), !newTitle.isEmpty {
            let selector = selectorArguments(from: text.slice(targetRange), context: context)
            guard !selector.arguments.isEmpty else { return nil }
            var arguments = selector.arguments
            arguments["new_title"] = .string(newTitle)
            return .calls([ToolCall(tool: .calendarUpdateEvent, arguments: arguments, assumptions: selector.assumptions)], confidence: 0.9)
        }
        if let match = Rx.matchWhole(Self.changeLocation, text, groups: ["target", "loc"]), hasSignal,
           let targetRange = match.range("target"), let location = match.original("loc").map(TextCleanup.name), !location.isEmpty {
            let selector = selectorArguments(from: text.slice(targetRange), context: context)
            guard !selector.arguments.isEmpty else { return nil }
            var arguments = selector.arguments
            arguments["new_location"] = .string(location)
            return .calls([ToolCall(tool: .calendarUpdateEvent, arguments: arguments, assumptions: selector.assumptions)], confidence: 0.9)
        }

        guard let verbMatch = Rx.matchWhole(Self.updateVerb, text, groups: ["verb", "body"]), let bodyRange = verbMatch.range("body") else { return nil }
        let body = text.slice(bodyRange)
        if mentionsOther && !hasSignal { return nil }

        // Split "<target> to <new time/date>" at the first connector whose right side holds a date or time.
        for connector in body.matches(Self.connector) {
            let left = body.slice(0..<connector.range.lowerBound)
            let right = body.slice(connector.range.upperBound..<body.count)
            guard !left.isEmpty, !right.isEmpty else { continue }
            var newWhen = NaturalDateParser().parse(right, context: calendarClause.context)
            if newWhen.isEmpty, Rx.bareHour.firstMatch(in: right.folded, range: NSRange(right.folded.startIndex..., in: right.folded)) != nil {
                // "move my meeting to 4": a bare hour is a time of day.
                let preposition = right.folded.hasPrefix("la") ? "a " : "at "
                newWhen = NaturalDateParser().parse(FoldedText(preposition + right.original), context: calendarClause.context)
            }
            guard !newWhen.isEmpty else { continue }
            // The right side must be (almost) entirely a date/time expression.
            let leftover = TextCleanup.trimConnectors(right.removing(newWhen.consumed))
            guard leftover.count <= 3 else { continue }

            let selector = selectorArguments(from: left, context: context)
            guard !selector.arguments.isEmpty else { continue }
            var arguments = selector.arguments
            var assumptions = selector.assumptions + newWhen.assumptions
            if newWhen.span != nil && newWhen.instant == nil && !newWhen.dayCameFromSpan { assumptions = assumptions + [] }
            if let day = newWhen.day, !newWhen.dayWasImplied { arguments["new_date"] = ArgumentBuilders.day(day, calendar: cal) }
            if newWhen.hasTime, let hour = newWhen.hour, let minute = newWhen.minute { arguments["new_time"] = ArgumentBuilders.time(hour: hour, minute: minute) }
            if let duration = newWhen.duration, newWhen.endInstant != nil || newWhen.instant == nil {
                arguments["new_duration_minutes"] = .int(max(1, Int((duration / 60).rounded())))
            }
            guard arguments["new_date"] != nil || arguments["new_time"] != nil || arguments["new_duration_minutes"] != nil else { continue }
            let confidence = hasSignal ? 0.9 : 0.62
            return .calls([ToolCall(tool: .calendarUpdateEvent, arguments: arguments, assumptions: assumptions)], confidence: confidence)
        }

        // "make my meeting 2 hours long"
        if hasSignal, let match = Rx.matchWhole(Self.makeLong, body, groups: ["target", "dur"]), let targetRange = match.range("target"), let durRange = match.range("dur") {
            let durationClause = body.slice(durRange)
            let durationWhen = NaturalDateParser().parse(durationClause, context: calendarClause.context, allowBareDuration: true)
            if let duration = durationWhen.duration {
                let selector = selectorArguments(from: body.slice(targetRange), context: context)
                if !selector.arguments.isEmpty {
                    var arguments = selector.arguments
                    arguments["new_duration_minutes"] = .int(max(1, Int((duration / 60).rounded())))
                    return .calls([ToolCall(tool: .calendarUpdateEvent, arguments: arguments, assumptions: selector.assumptions)], confidence: 0.85)
                }
            }
        }
        return nil
    }

    // MARK: Selectors

    /// Turns "my Friday meeting with Daniel at 3 pm" into `{title, on_date, at_time}` selector arguments.
    private func selectorArguments(from target: FoldedText, context: DateContext) -> (arguments: JSONObject, assumptions: [String]) {
        var dateContext = context
        dateContext.ambiguousHours = .businessHours
        let cal = context.calendar
        let when = NaturalDateParser().parse(target, context: dateContext)
        var rest = TextCleanup.trimConnectors(target.removing(when.consumed))

        var calendarName: String?
        for regex in [Self.toCalendarTail, Self.calendarPrefix] {
            if let found = rest.findMatch(regex, groups: ["cal", "cal2"]), found.range.upperBound == rest.count {
                calendarName = (found.original("cal2") ?? found.original("cal")).map(TextCleanup.name)
                if calendarName?.lowercased() == "my" || calendarName?.lowercased() == "mi" { calendarName = nil }
                rest = rest.removing([found.range]).collapsedWhitespace()
                break
            }
        }
        if let found = rest.firstMatch(Self.leadingDeterminer), found.range.lowerBound == 0, found.range.upperBound < rest.count {
            rest = rest.slice(found.range.upperBound..<rest.count)
        }
        if let found = rest.firstMatch(Self.leadingPossessive), found.range.lowerBound == 0 { rest = rest.slice(found.range.upperBound..<rest.count) }
        var query = TextCleanup.name(rest.original)
        let generic: Set<String> = ["event", "events", "evento", "eventos", "calendar event", "evento del calendario", "it", "that", "this", "eso", "esto"]
        if generic.contains(query.lowercased()) { query = "" }
        // "the meeting tomorrow" names a date, not a title: let the date pick the event (and ask if there are several).
        if when.day != nil, !when.dayWasImplied, Self.structuralNouns.contains(TextFolding.fold(query)) { query = "" }

        var arguments: JSONObject = [:]
        if !query.isEmpty { arguments["title"] = .string(query) }
        if let day = when.day, !when.dayWasImplied { arguments["on_date"] = ArgumentBuilders.day(day, calendar: cal) }
        if when.timeIsExplicit, let hour = when.hour, let minute = when.minute { arguments["at_time"] = ArgumentBuilders.time(hour: hour, minute: minute) }
        if let calendarName, !calendarName.isEmpty { arguments["calendar"] = .string(calendarName) }
        return (arguments, [])
    }

    private static func calendarName(in text: FoldedText) -> String? {
        for regex in [toCalendarTail, calendarPrefix] {
            if let found = text.findMatch(regex, groups: ["cal", "cal2"]), found.range.upperBound == text.count,
               let name = (found.original("cal2") ?? found.original("cal")).map(TextCleanup.name), !name.isEmpty,
               !["my", "mi", "the", "el"].contains(name.lowercased()) {
                return name
            }
        }
        return nil
    }

    private func conflictWindow(_ when: ParsedWhen, context: DateContext) -> JSONObject? {
        let cal = context.calendar
        if let instant = when.instant {
            let end = when.endInstant ?? instant.addingTimeInterval(TimeInterval(context.settings.defaultEventDurationMinutes) * 60)
            return ["start": ArgumentBuilders.dateTime(instant, calendar: cal), "end": ArgumentBuilders.dateTime(end, calendar: cal)]
        }
        if let window = ArgumentBuilders.window(when, calendar: cal) {
            return ["start": ArgumentBuilders.dateTime(window.start, calendar: cal), "end": ArgumentBuilders.dateTime(window.end, calendar: cal)]
        }
        return nil
    }
}

extension Rx {
    /// Whole-string match on a `FoldedText` (convenience used by rule sets that work on slices).
    static func matchWhole(_ regex: NSRegularExpression, _ text: FoldedText, groups: [String]) -> MatchedClause? {
        text.wholeMatch(regex, groups: groups)
    }
}
