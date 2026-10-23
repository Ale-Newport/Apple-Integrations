import Foundation
import JarvisCore

/// Everything the date parser needs to turn words into real instants.
struct DateContext: Sendable {
    /// How "at 3" (no AM/PM, no part of the day) is read.
    enum AmbiguousHourPolicy: Sendable {
        /// The soonest future occurrence (reminders, alarms).
        case soonestFuture
        /// Business-hours reading: 7–11 → morning, 12 → noon, 1–6 → afternoon (calendar events).
        case businessHours
        /// Morning first: 1–11 → AM, 12 → noon (alarms and wake-up calls).
        case morningFirst
    }

    var now: Date
    var calendar: Calendar
    var settings: JarvisSettings
    var language: Language
    var ambiguousHours: AmbiguousHourPolicy = .soonestFuture
}

/// Finds and resolves English/Spanish date, time and duration expressions.
///
/// Resolution always uses the *actual* current date and the user's time zone (both injected through
/// ``DateContext``), including DST transitions. Whenever the text leaves something open — "at 6" without
/// AM/PM, "next Friday" — the parser picks the most useful reading and records an *assumption* that is
/// shown to the user, instead of guessing silently.
struct NaturalDateParser: Sendable {
    init() {}

    private struct Candidate {
        var kinds: [DatePiece.Kind]
        var range: Range<Int>
        var priority: Int
    }

    // MARK: Public entry point

    func parse(_ text: FoldedText, context: DateContext, allowBareDuration: Bool = false) -> ParsedWhen {
        let candidates = scan(text, allowBareDuration: allowBareDuration)
        let accepted = accept(candidates)
        var when = ParsedWhen()
        when.pieces = accepted.flatMap { candidate in candidate.kinds.map { DatePiece(kind: $0, range: candidate.range, priority: candidate.priority) } }
        when.consumed = accepted.map(\.range)
        resolve(&when, context: context)
        return when
    }

    func parse(_ string: String, context: DateContext, allowBareDuration: Bool = false) -> ParsedWhen {
        parse(FoldedText(string), context: context, allowBareDuration: allowBareDuration)
    }

    // MARK: Scanning

    private func scan(_ text: FoldedText, allowBareDuration: Bool) -> [Candidate] {
        var found: [Candidate] = []
        func add(_ kinds: [DatePiece.Kind], _ range: Range<Int>, _ priority: Int) {
            guard !text.isMasked(range) else { return }
            found.append(Candidate(kinds: kinds, range: range, priority: priority))
        }

        // Time ranges first: "from 3 to 4 pm", "de 10 a 12".
        for match in text.matches(DateLexicon.timeRange, groupNames: ["h1", "m1", "mer1", "h2", "m2", "mer2"]) {
            guard let h1 = value(text, match.group("h1")), let h2 = value(text, match.group("h2")) else { continue }
            let m1 = value(text, match.group("m1")) ?? 0
            let m2 = value(text, match.group("m2")) ?? 0
            let mer1 = meridiem(text, match.group("mer1"))
            let mer2 = meridiem(text, match.group("mer2"))
            let hasColon = match.group("m1") != nil || match.group("m2") != nil
            let lead = text.foldedSlice(match.range)
            let hasPreposition = lead.hasPrefix("from") || lead.hasPrefix("de ") || lead.hasPrefix("entre")
            // A bare "3-4" is too ambiguous (a score, a page range…); demand a clue that these are clock times.
            guard mer1 != nil || mer2 != nil || hasColon || hasPreposition else { continue }
            guard (0...24).contains(h1), (0...24).contains(h2), h1 != h2 || m1 != m2 else { continue }
            var startMeridiem = mer1
            if startMeridiem == nil, let endMeridiem = mer2, h1 <= 12, h2 <= 12 {
                // "3 to 4 pm" → both pm; "11 to 1 pm" → starts in the morning; "12 to 2 pm" → noon.
                let wraps = h1 != 12 && h1 > h2
                startMeridiem = wraps ? (endMeridiem == .pm ? .am : .pm) : endMeridiem
            }
            let start = ClockTime(hour: h1 % 24, minute: m1, meridiem: startMeridiem, twentyFourHour: startMeridiem == nil && (h1 > 12 || h1 == 0))
            let end = ClockTime(hour: h2 % 24, minute: m2, meridiem: mer2, twentyFourHour: mer2 == nil && (h2 > 12 || h2 == 0))
            add([.timeRange(start: start, end: end)], match.range, 100)
        }

        // Absolute dates.
        for match in text.matches(DateLexicon.isoDate, groupNames: ["y", "m", "d"]) {
            if let y = value(text, match.group("y")), let m = value(text, match.group("m")), let d = value(text, match.group("d")) {
                add([.iso(year: y, month: m, day: d)], match.range, 95)
            }
        }
        for match in text.matches(DateLexicon.spanishDate, groupNames: ["day", "mon", "year"]) {
            if let piece = absolutePiece(text, match) { add([piece], match.range, 92) }
        }
        for match in text.matches(DateLexicon.monthFirst, groupNames: ["day", "mon", "year"]) {
            if let piece = absolutePiece(text, match) { add([piece], match.range, 90) }
        }
        for match in text.matches(DateLexicon.dayFirst, groupNames: ["day", "mon", "year"]) {
            if let piece = absolutePiece(text, match) { add([piece], match.range, 90) }
        }
        for match in text.matches(DateLexicon.dottedDate, groupNames: ["a", "b", "y"]) {
            if let a = value(text, match.group("a")), let b = value(text, match.group("b")), let y = value(text, match.group("y")) {
                add([.numeric(first: a, second: b, year: y)], match.range, 88)
            }
        }
        for match in text.matches(DateLexicon.numericDate, groupNames: ["a", "b", "y"]) {
            guard let a = value(text, match.group("a")), let b = value(text, match.group("b")) else { continue }
            var year = value(text, match.group("y"))
            if let y = year, y < 100 { year = 2000 + y }
            add([.numeric(first: a, second: b, year: year)], match.range, 87)
        }

        // Relative offsets and durations.
        for match in text.matches(DateLexicon.relativeIn, groupNames: ["dur"]) {
            if let range = match.group("dur"), let duration = duration(text.foldedSlice(range)) {
                add([.relative(duration)], match.range, 85)
            }
        }
        for match in text.matches(DateLexicon.relativeFromNow, groupNames: ["dur"]) {
            if let range = match.group("dur"), let duration = duration(text.foldedSlice(range)) {
                add([.relative(duration)], match.range, 85)
            }
        }
        for match in text.matches(DateLexicon.durationWithPreposition, groupNames: ["dur"]) {
            if let range = match.group("dur"), let duration = duration(text.foldedSlice(range)), duration.isClockOnly {
                add([.duration(duration)], match.range, 80)
            }
        }
        for match in text.matches(DateLexicon.durationLong, groupNames: ["dur"]) {
            if let range = match.group("dur"), let duration = duration(text.foldedSlice(range)), duration.isClockOnly {
                add([.duration(duration)], match.range, 80)
            }
        }
        for match in text.matches(DateLexicon.nextDays, groupNames: ["n", "unit"]) {
            if let n = value(text, match.group("n")), let unitRange = match.group("unit") {
                let unit = text.foldedSlice(unitRange)
                let days = (unit.hasPrefix("week") || unit.hasPrefix("semana")) ? n * 7 : n
                add([.upcoming(days: days)], match.range, 83)
            }
        }

        // Weekdays and spans.
        for match in text.matches(DateLexicon.weekdayEnglish, groupNames: ["mod", "wd"]) {
            if let piece = weekdayPiece(text, match, mod2: nil) { add([piece], match.range, 70) }
        }
        for match in text.matches(DateLexicon.weekdayEnglishAbbreviated, groupNames: ["mod", "wd"]) {
            if let piece = weekdayPiece(text, match, mod2: nil) { add([piece], match.range, 69) }
        }
        for match in text.matches(DateLexicon.weekdaySpanish, groupNames: ["mod", "wd", "mod2"]) {
            if let piece = weekdayPiece(text, match, mod2: match.group("mod2")) { add([piece], match.range, 70) }
        }
        for match in text.matches(DateLexicon.spanEnglish, groupNames: ["mod", "scope"]) {
            if let piece = spanPiece(text, match, spanish: false) { add([piece], match.range, 66) }
        }
        for match in text.matches(DateLexicon.spanSpanish, groupNames: ["art", "mod", "scope", "mod2"]) {
            if let piece = spanPiece(text, match, spanish: true) { add([piece], match.range, 65) }
        }

        // Clock times.
        for match in text.matches(DateLexicon.hourWithPeriod, groupNames: ["h", "pod"]) {
            if let hour = value(text, match.group("h")), let podRange = match.group("pod") {
                let pod = partOfDay(text.foldedSlice(podRange))
                add([.clock(ClockTime(hour: hour, minute: 0, meridiem: nil, twentyFourHour: false)), .partOfDay(pod)], match.range, 63)
            }
        }
        for match in text.matches(DateLexicon.clockColon, groupNames: ["h", "m", "mer"]) {
            guard let hour = value(text, match.group("h")), let minute = value(text, match.group("m")) else { continue }
            let mer = meridiem(text, match.group("mer"))
            let leadingZero = match.group("h").map { text.foldedSlice($0).hasPrefix("0") && text.foldedSlice($0).count == 2 } ?? false
            add([.clock(ClockTime(hour: hour, minute: minute, meridiem: mer, twentyFourHour: mer == nil && (hour > 12 || hour == 0 || leadingZero)))], match.range, 62)
        }
        for match in text.matches(DateLexicon.clockMeridiem, groupNames: ["h", "m", "mer"]) {
            guard let hour = value(text, match.group("h")) else { continue }
            let minute = value(text, match.group("m")) ?? 0
            add([.clock(ClockTime(hour: hour, minute: minute, meridiem: meridiem(text, match.group("mer")), twentyFourHour: false))], match.range, 61)
        }
        for match in text.matches(DateLexicon.clockOClock, groupNames: ["h"]) {
            if let hour = value(text, match.group("h")), (1...12).contains(hour) {
                add([.clock(ClockTime(hour: hour, minute: 0, meridiem: nil, twentyFourHour: false))], match.range, 60)
            }
        }
        for match in text.matches(DateLexicon.clockPast, groupNames: ["mod", "dir", "h"]) {
            guard let hourRange = match.group("h"), let hour = NumberWords.parse(text.foldedSlice(hourRange)), (1...12).contains(hour),
                  let modRange = match.group("mod"), let dirRange = match.group("dir") else { continue }
            let modText = text.foldedSlice(modRange)
            let minutes: Int
            switch modText {
            case "half": minutes = 30
            case "quarter", "a quarter": minutes = 15
            default:
                guard let parsed = NumberWords.parse(modText), (1...59).contains(parsed) else { continue }
                minutes = parsed
            }
            let direction = text.foldedSlice(dirRange)
            // "quarter of 7" (US usage) means "quarter to 7".
            let isBefore = ["to", "till", "before", "of"].contains(direction)
            let hour24Base = isBefore ? (hour == 1 ? 12 : hour - 1) : hour
            let minute = isBefore ? 60 - minutes : minutes
            add([.clock(ClockTime(hour: hour24Base, minute: minute, meridiem: nil, twentyFourHour: false))], match.range, 64)
        }
        for match in text.matches(DateLexicon.clockSpanish, groupNames: ["h", "mod", "less"]) {
            if let piece = spanishClock(text, match) { add([piece], match.range, 64) }
        }
        for match in text.matches(DateLexicon.clockSpanishBare, groupNames: ["h", "mod", "less"]) {
            if let piece = spanishClock(text, match) { add([piece], match.range, 63) }
        }
        for match in text.matches(DateLexicon.clockAt, groupNames: ["h"]) {
            if let hour = value(text, match.group("h")), (0...24).contains(hour) {
                add([.clock(ClockTime(hour: hour % 24, minute: 0, meridiem: nil, twentyFourHour: hour > 12 || hour == 0))], match.range, 55)
            }
        }
        for match in text.matches(DateLexicon.namedTime, groupNames: ["name"]) {
            if let range = match.group("name") {
                let name = text.foldedSlice(range)
                add([.named(name.hasPrefix("mid") && (name == "midnight" || name == "medianoche") ? .midnight : .noon)], match.range, 56)
            }
        }

        // Days.
        for match in text.matches(DateLexicon.ordinalEnglish, groupNames: ["day"]) {
            if let day = value(text, match.group("day")), (1...31).contains(day) { add([.ordinalDay(day)], match.range, 50) }
        }
        for match in text.matches(DateLexicon.ordinalSpanish, groupNames: ["day"]) {
            if let day = value(text, match.group("day")), (1...31).contains(day) { add([.ordinalDay(day)], match.range, 49) }
        }
        for match in text.matches(DateLexicon.dayAfterTomorrow) { add([.dayOffset(2)], match.range, 41) }
        for match in text.matches(DateLexicon.tomorrow) { add([.dayOffset(1)], match.range, 40) }
        for match in text.matches(DateLexicon.spanishTomorrow) { add([.dayOffset(1)], match.range, 40) }
        for match in text.matches(DateLexicon.today) { add([.dayOffset(0)], match.range, 40) }
        for match in text.matches(DateLexicon.dayBeforeYesterday) { add([.dayOffset(-2)], match.range, 41) }
        for match in text.matches(DateLexicon.yesterday) { add([.dayOffset(-1)], match.range, 40) }
        for match in text.matches(DateLexicon.tonight) { add([.dayOffset(0), .partOfDay(.night)], match.range, 44) }
        for match in text.matches(DateLexicon.lastNight) { add([.dayOffset(-1), .partOfDay(.night)], match.range, 44) }
        for match in text.matches(DateLexicon.partOfDaySpanish, groupNames: ["pod"]) {
            if let range = match.group("pod") { add([.partOfDay(partOfDay(text.foldedSlice(range)))], match.range, 45) }
        }
        for match in text.matches(DateLexicon.partOfDayEnglish, groupNames: ["pod"]) {
            if let range = match.group("pod") { add([.partOfDay(partOfDay(text.foldedSlice(range)))], match.range, 45) }
        }

        if allowBareDuration {
            for match in text.matches(DateLexicon.bareDuration, groupNames: ["dur"]) {
                if let range = match.group("dur"), let duration = duration(text.foldedSlice(range)) {
                    add([.duration(duration)], match.range, 30)
                }
            }
        }
        return found
    }

    /// Greedy, priority-ordered selection of non-overlapping candidates.
    private func accept(_ candidates: [Candidate]) -> [Candidate] {
        let ordered = candidates.sorted { left, right in
            if left.priority != right.priority { return left.priority > right.priority }
            if left.range.count != right.range.count { return left.range.count > right.range.count }
            return left.range.lowerBound < right.range.lowerBound
        }
        var accepted: [Candidate] = []
        for candidate in ordered where !accepted.contains(where: { $0.range.overlaps(candidate.range) }) {
            accepted.append(candidate)
        }
        return accepted.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    // MARK: Piece builders

    private func value(_ text: FoldedText, _ range: Range<Int>?) -> Int? {
        guard let range else { return nil }
        return NumberWords.parse(text.foldedSlice(range))
    }

    private func meridiem(_ text: FoldedText, _ range: Range<Int>?) -> Meridiem? {
        guard let range else { return nil }
        let value = text.foldedSlice(range).replacingOccurrences(of: ".", with: "").replacingOccurrences(of: " ", with: "")
        if value.hasPrefix("a") { return .am }
        if value.hasPrefix("p") { return .pm }
        return nil
    }

    private func partOfDay(_ word: String) -> PartOfDay {
        switch word {
        case "morning", "manana", "madrugada": return .morning
        case "afternoon", "tarde": return .afternoon
        case "evening": return .evening
        default: return .night
        }
    }

    private func absolutePiece(_ text: FoldedText, _ match: FoldedText.Match) -> DatePiece.Kind? {
        guard let day = value(text, match.group("day")), (1...31).contains(day),
              let monthRange = match.group("mon"), let month = DateLexicon.monthNumbers[text.foldedSlice(monthRange)] else { return nil }
        return .absolute(day: day, month: month, year: value(text, match.group("year")))
    }

    private func weekdayPiece(_ text: FoldedText, _ match: FoldedText.Match, mod2: Range<Int>?) -> DatePiece.Kind? {
        guard let wdRange = match.group("wd"), let weekday = DateLexicon.weekdayNumbers[text.foldedSlice(wdRange).trimmingCharacters(in: CharacterSet(charactersIn: "."))] else { return nil }
        var modifier = WeekdayModifier.none
        func map(_ word: String) -> WeekdayModifier? {
            switch word {
            case "this", "este": return .this
            case "next", "coming", "upcoming", "following", "proximo", "que viene", "siguiente": return .next
            case "last", "pasado", "ultimo": return .last
            default: return nil
            }
        }
        if let range = match.group("mod"), let mapped = map(text.foldedSlice(range)) { modifier = mapped }
        if let range = mod2, let mapped = map(text.foldedSlice(range).replacingOccurrences(of: "  ", with: " ")) { modifier = mapped }
        return .weekday(weekday, modifier)
    }

    private func spanPiece(_ text: FoldedText, _ match: FoldedText.Match, spanish: Bool) -> DatePiece.Kind? {
        guard let scopeRange = match.group("scope") else { return nil }
        let scopeWord = text.foldedSlice(scopeRange).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let scope: SpanScope
        switch scopeWord {
        case "week", "semana": scope = .week
        case "weekend", "fin de semana": scope = .weekend
        case "month", "mes": scope = .month
        default: scope = .year
        }
        var offset = 0
        func map(_ word: String) -> Int? {
            switch word.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression) {
            case "this", "esta", "este": return 0
            case "next", "coming", "upcoming", "following", "proxima", "proximo", "siguiente", "que viene": return 1
            case "last", "pasada", "pasado": return -1
            default: return nil
            }
        }
        var hasModifier = false
        if let range = match.group("mod"), let mapped = map(text.foldedSlice(range)) { offset = mapped; hasModifier = true }
        if spanish, let range = match.group("mod2"), let mapped = map(text.foldedSlice(range)) { offset = mapped; hasModifier = true }
        if spanish, !hasModifier {
            // "esta semana" → this; a bare "la semana" / "el mes" without modifier is not a date expression.
            if let range = match.group("art"), ["esta", "este"].contains(text.foldedSlice(range)) { offset = 0 } else { return nil }
        }
        return .span(scope, offset: offset)
    }

    private func spanishClock(_ text: FoldedText, _ match: FoldedText.Match) -> DatePiece.Kind? {
        guard let hourRange = match.group("h"), let hour = NumberWords.parse(text.foldedSlice(hourRange)), (0...24).contains(hour) else { return nil }
        var minute = 0
        var effectiveHour = hour
        if let modRange = match.group("mod") {
            let word = text.foldedSlice(modRange)
            switch word {
            case "media": minute = 30
            case "cuarto": minute = 15
            default:
                guard let parsed = NumberWords.parse(word), (0...59).contains(parsed) else { return nil }
                minute = parsed
            }
        } else if let lessRange = match.group("less") {
            let word = text.foldedSlice(lessRange)
            let less: Int
            if word == "cuarto" { less = 15 } else if let parsed = NumberWords.parse(word), (1...59).contains(parsed) { less = parsed } else { return nil }
            minute = 60 - less
            effectiveHour = hour == 1 ? 12 : hour - 1
        }
        return .clock(ClockTime(hour: effectiveHour % 24, minute: minute, meridiem: nil, twentyFourHour: effectiveHour > 12 || effectiveHour == 0))
    }

    // MARK: Durations

    /// Evaluates text such as "1 hour and 30 minutes", "an hour and a half", "dos horas", "90 min".
    func duration(_ text: String) -> DurationValue? {
        let folded = TextFolding.fold(text)
        var value = DurationValue()
        var matchedAny = false
        var lastUnitSeconds: Double = 0
        var lastUnit: String?

        let nsFolded = folded as NSString
        let range = NSRange(location: 0, length: nsFolded.length)

        // "1h30", "2h 15m": hours immediately followed by minutes.
        if let compact = try? NSRegularExpression(pattern: #"(\d+)\s*h\s*(\d{1,2})(?:\s*m(?:in)?)?(?![a-z\d])"#),
           let result = compact.firstMatch(in: folded, range: range),
           let hoursRange = Range(result.range(at: 1), in: folded), let minutesRange = Range(result.range(at: 2), in: folded),
           let hours = Double(folded[hoursRange]), let minutes = Double(folded[minutesRange]) {
            value.seconds = hours * 3_600 + minutes * 60
            return value.isZero ? nil : value
        }

        DateLexicon.durationComponent.enumerateMatches(in: folded, range: range) { result, _, _ in
            guard let result,
                  let qtyRange = Range(result.range(withName: "qty"), in: folded),
                  let unitRange = Range(result.range(withName: "unit"), in: folded) else { return }
            let qtyText = String(folded[qtyRange])
            let unit = String(folded[unitRange])
            let quantity: Double
            if let parsed = Double(qtyText.replacingOccurrences(of: ",", with: ".")) {
                quantity = parsed
            } else if ["half", "media", "medio"].contains(qtyText) {
                quantity = 0.5
            } else if ["a", "an", "one", "un", "una"].contains(qtyText) {
                quantity = 1
            } else if let parsed = NumberWords.parse(qtyText) {
                quantity = Double(parsed)
            } else {
                return
            }
            matchedAny = true
            lastUnit = unit
            switch unit {
            case _ where unit.hasPrefix("h"): value.seconds += quantity * 3_600; lastUnitSeconds = 3_600
            case _ where unit.hasPrefix("min") || unit == "m": value.seconds += quantity * 60; lastUnitSeconds = 60
            case _ where unit.hasPrefix("sec") || unit.hasPrefix("seg"): value.seconds += quantity; lastUnitSeconds = 1
            case _ where unit.hasPrefix("d"): value.days += Int(quantity.rounded()); lastUnitSeconds = 0
            case _ where unit.hasPrefix("w") || unit.hasPrefix("sem"): value.days += Int((quantity * 7).rounded()); lastUnitSeconds = 0
            case _ where unit.hasPrefix("mo") || unit.hasPrefix("mes"): value.months += Int(quantity.rounded()); lastUnitSeconds = 0
            case _ where unit.hasPrefix("y") || unit.hasPrefix("ano"): value.years += Int(quantity.rounded()); lastUnitSeconds = 0
            default: break
            }
        }

        if !matchedAny, folded.range(of: DateLexicon.halfHour, options: .regularExpression) != nil {
            value.seconds += 1_800
            matchedAny = true
        } else if matchedAny, folded.range(of: DateLexicon.andHalf, options: .regularExpression) != nil, lastUnitSeconds > 0 {
            value.seconds += lastUnitSeconds / 2
        } else if matchedAny, folded.range(of: DateLexicon.andHalf, options: .regularExpression) != nil, lastUnit?.hasPrefix("d") == true {
            value.seconds += 43_200
        }
        return matchedAny && !value.isZero ? value : nil
    }
}
