import Foundation
import JarvisCore

extension NaturalDateParser {
    /// Combines the detected pieces into concrete dates in the user's calendar and time zone.
    func resolve(_ when: inout ParsedWhen, context: DateContext) {
        let calendar = context.calendar
        let now = context.now
        let today = calendar.startOfDay(for: now)
        let language = context.language

        // 1. Gather the pieces by kind (first occurrence wins).
        var durationValue: DurationValue?
        var relative: DurationValue?
        var clock: ClockTime?
        var clockRange: (start: ClockTime, end: ClockTime)?
        var named: NamedTime?
        var partOfDay: PartOfDay?
        var dayOffset: Int?
        var weekday: (number: Int, modifier: WeekdayModifier, label: String)?
        var absolute: (day: Int, month: Int, year: Int?)?
        var numeric: (first: Int, second: Int, year: Int?)?
        var iso: (year: Int, month: Int, day: Int)?
        var ordinalDay: Int?
        var span: (scope: SpanScope, offset: Int)?
        var upcomingDays: Int?

        for piece in when.pieces {
            switch piece.kind {
            case .duration(let value): if durationValue == nil { durationValue = value }
            case .relative(let value): if relative == nil { relative = value }
            case .clock(let value): if clock == nil { clock = value }
            case .timeRange(let start, let end): if clockRange == nil { clockRange = (start, end) }
            case .named(let value): if named == nil { named = value }
            case .partOfDay(let value): if partOfDay == nil { partOfDay = value }
            case .dayOffset(let value): if dayOffset == nil { dayOffset = value }
            case .weekday(let number, let modifier): if weekday == nil { weekday = (number, modifier, "") }
            case .absolute(let day, let month, let year): if absolute == nil { absolute = (day, month, year) }
            case .numeric(let first, let second, let year): if numeric == nil { numeric = (first, second, year) }
            case .iso(let year, let month, let day): if iso == nil { iso = (year, month, day) }
            case .ordinalDay(let value): if ordinalDay == nil { ordinalDay = value }
            case .span(let scope, let offset): if span == nil { span = (scope, offset) }
            case .upcoming(let days): if upcomingDays == nil { upcomingDays = days }
            }
        }

        if let durationValue, durationValue.isClockOnly { when.duration = durationValue.totalSeconds }

        // 2. "in two hours", "dentro de 30 minutos": an absolute instant, nothing else matters.
        var relativeDay: Date?
        if let relative {
            if relative.isClockOnly, relative.seconds > 0 {
                let target = floorToMinute(now.addingTimeInterval(relative.seconds), calendar: calendar)
                setInstant(&when, target, calendar: calendar, explicitTime: true)
                finishEnd(&when, clockRange: nil, calendar: calendar)
                return
            }
            var day = today
            if relative.years != 0 { day = calendar.date(byAdding: .year, value: relative.years, to: day) ?? day }
            if relative.months != 0 { day = calendar.date(byAdding: .month, value: relative.months, to: day) ?? day }
            if relative.days != 0 { day = calendar.date(byAdding: .day, value: relative.days, to: day) ?? day }
            relativeDay = day
        }

        // 3. The calendar day.
        var day: Date?
        var weekdayWithoutModifier = false

        if let iso {
            day = calendar.date(from: DateComponents(year: iso.year, month: iso.month, day: iso.day)).flatMap { validated($0, year: iso.year, month: iso.month, day: iso.day, calendar: calendar) }
        } else if let absolute {
            day = nextOccurrence(day: absolute.day, month: absolute.month, year: absolute.year, today: today, calendar: calendar)
        } else if let numeric {
            var month = language == .es ? numeric.second : numeric.first
            var dayNumber = language == .es ? numeric.first : numeric.second
            if month > 12, dayNumber <= 12 { swap(&month, &dayNumber) }
            if (1...12).contains(month), (1...31).contains(dayNumber) {
                day = nextOccurrence(day: dayNumber, month: month, year: numeric.year, today: today, calendar: calendar)
            }
        } else if let ordinalDay {
            day = nextDayOfMonth(ordinalDay, today: today, calendar: calendar)
        } else if let weekday {
            let result = resolveWeekday(weekday.number, modifier: weekday.modifier, today: today, calendar: calendar)
            day = result.day
            weekdayWithoutModifier = weekday.modifier == .none || weekday.modifier == .this
            if let note = result.assumption(language: language, calendar: calendar, weekday: weekday.number) { when.assumptions.append(note) }
        } else if let relativeDay {
            day = relativeDay
        } else if let dayOffset {
            day = calendar.date(byAdding: .day, value: dayOffset, to: today)
        } else if let upcomingDays {
            let end = calendar.date(byAdding: .day, value: upcomingDays + 1, to: today) ?? today
            when.span = (now, end)
            day = today
            when.dayCameFromSpan = true
        } else if let span {
            let range = spanRange(span.scope, offset: span.offset, today: today, calendar: calendar)
            when.span = range
            day = calendar.startOfDay(for: range.start)
            when.dayCameFromSpan = true
            if span.offset != 0 || span.scope == .weekend {
                when.assumptions.append(language.pick(
                    "Interpreted the period as starting \(shortDate(day ?? today, language: language, calendar: calendar))",
                    "Interpreté el periodo como iniciando el \(shortDate(day ?? today, language: language, calendar: calendar))"
                ))
            }
        }

        // 4. The time of day.
        var hour: Int?
        var minute = 0
        var explicitTime = false

        func settingsHour(for part: PartOfDay) -> Int {
            switch part {
            case .morning: return context.settings.morningHour
            case .afternoon: return context.settings.afternoonHour
            case .evening: return context.settings.eveningHour
            case .night: return context.settings.nightHour
            }
        }

        if let clockRange {
            let start = resolveClock(clockRange.start, partOfDay: partOfDay, day: day, minuteHint: nil, context: context, when: &when)
            hour = start.hour
            minute = start.minute
            explicitTime = true
            var endClock = clockRange.end
            if endClock.meridiem == nil, !endClock.twentyFourHour, endClock.hour <= 12, endClock.hour != 0 {
                // "from 9 to 5": keep the end after the start by adopting the start's half of the day when possible.
                let candidateAM = endClock.hour % 12
                let candidatePM = candidateAM + 12
                let startMinutes = start.hour * 60 + start.minute
                if candidateAM * 60 + endClock.minute > startMinutes {
                    endClock.meridiem = .am
                } else if candidatePM * 60 + endClock.minute > startMinutes {
                    endClock.meridiem = .pm
                }
            }
            let end = resolveClock(endClock, partOfDay: partOfDay, day: day, minuteHint: nil, context: context, when: &when, recordAssumption: false)
            when.rangeEnd = (end.hour, end.minute)
        } else if let clock {
            let resolved = resolveClock(clock, partOfDay: partOfDay, day: day, minuteHint: nil, context: context, when: &when)
            hour = resolved.hour
            minute = resolved.minute
            explicitTime = true
        } else if let named {
            hour = named == .noon ? 12 : 0
            explicitTime = true
        } else if let partOfDay {
            hour = settingsHour(for: partOfDay)
            when.assumptions.append(language.pick(
                "Used \(formatClock(hour ?? 0, 0)) for “\(partOfDayLabel(partOfDay, .en))”",
                "Usé las \(formatClock(hour ?? 0, 0)) para «\(partOfDayLabel(partOfDay, .es))»"
            ))
        }

        // 5. Combine.
        if let hour {
            when.hour = hour
            when.minute = minute
            when.timeIsExplicit = explicitTime

            if day == nil {
                // Only a time was given: next occurrence of that time.
                var candidate = combine(today, hour: hour, minute: minute, calendar: calendar)
                if candidate <= now {
                    candidate = combine(calendar.date(byAdding: .day, value: 1, to: today) ?? today, hour: hour, minute: minute, calendar: calendar)
                }
                setInstant(&when, candidate, calendar: calendar, explicitTime: explicitTime)
                when.dayWasImplied = true
            } else if let day {
                var candidate = combine(day, hour: hour, minute: minute, calendar: calendar)
                if weekdayWithoutModifier, candidate <= now, calendar.isDate(day, inSameDayAs: today) {
                    // "Friday at 3" said on Friday after 3 pm → next Friday.
                    let nextWeek = calendar.date(byAdding: .day, value: 7, to: day) ?? day
                    candidate = combine(nextWeek, hour: hour, minute: minute, calendar: calendar)
                    when.assumptions.append(language.pick(
                        "That time has already passed today, so I used next week (\(shortDate(nextWeek, language: language, calendar: calendar)))",
                        "Esa hora ya pasó hoy, así que usé la próxima semana (\(shortDate(nextWeek, language: language, calendar: calendar)))"
                    ))
                }
                setInstant(&when, candidate, calendar: calendar, explicitTime: explicitTime)
            }
        } else if let day {
            when.day = day
        }

        finishEnd(&when, clockRange: when.rangeEnd, calendar: calendar)
    }

    // MARK: End of range / duration

    private func finishEnd(_ when: inout ParsedWhen, clockRange: (hour: Int, minute: Int)?, calendar: Calendar) {
        guard let start = when.instant else { return }
        if let clockRange {
            var end = combine(calendar.startOfDay(for: start), hour: clockRange.hour, minute: clockRange.minute, calendar: calendar)
            if end <= start { end = calendar.date(byAdding: .day, value: 1, to: end) ?? end }
            when.endInstant = end
            when.duration = end.timeIntervalSince(start)
        } else if let duration = when.duration {
            when.endInstant = start.addingTimeInterval(duration)
        }
    }

    private func setInstant(_ when: inout ParsedWhen, _ instant: Date, calendar: Calendar, explicitTime: Bool) {
        when.instant = instant
        when.day = calendar.startOfDay(for: instant)
        let components = calendar.dateComponents([.hour, .minute], from: instant)
        when.hour = components.hour
        when.minute = components.minute
        when.timeIsExplicit = explicitTime
    }

    // MARK: Clock resolution

    private struct ResolvedClock { var hour: Int; var minute: Int }

    private func resolveClock(_ clock: ClockTime, partOfDay: PartOfDay?, day: Date?, minuteHint: Int?, context: DateContext, when: inout ParsedWhen, recordAssumption: Bool = true) -> ResolvedClock {
        let calendar = context.calendar
        let language = context.language
        let minute = clock.minute
        let hour = clock.hour

        if let meridiem = clock.meridiem {
            return ResolvedClock(hour: to24(hour, meridiem), minute: minute)
        }
        if clock.twentyFourHour || hour > 12 || hour == 0 {
            return ResolvedClock(hour: hour % 24, minute: minute)
        }
        if let partOfDay {
            let resolved: Int
            switch partOfDay {
            case .morning: resolved = hour == 12 ? 0 : hour
            case .afternoon: resolved = hour == 12 ? 12 : hour + 12
            case .evening: resolved = hour == 12 ? 0 : hour + 12
            case .night:
                if hour == 12 { resolved = 0 } else if hour >= 6 { resolved = hour + 12 } else { resolved = hour }
            }
            return ResolvedClock(hour: resolved, minute: minute)
        }

        // 1…12 with no AM/PM and no part of the day: choose the most plausible reading and say so.
        let am = hour % 12
        let pm = am + 12
        func heuristic() -> Int {
            switch hour {
            case 7...11: return am
            case 12: return 12
            default: return pm
            }
        }
        let chosen: Int
        let today = calendar.startOfDay(for: context.now)
        if context.ambiguousHours == .businessHours {
            chosen = heuristic()
        } else if context.ambiguousHours == .morningFirst {
            chosen = hour == 12 ? 12 : am
        } else if let day, !calendar.isDate(day, inSameDayAs: today) {
            chosen = heuristic()
        } else {
            let base = day ?? today
            let amDate = combine(base, hour: am, minute: minute, calendar: calendar)
            let pmDate = combine(base, hour: pm, minute: minute, calendar: calendar)
            if amDate > context.now { chosen = am }
            else if pmDate > context.now { chosen = pm }
            else if day == nil { chosen = am } // both passed today → tomorrow morning is the soonest
            else { chosen = heuristic() }
        }
        if recordAssumption {
            let text = formatClock(chosen, minute)
            when.assumptions.append(language.pick("No AM/PM given, so I used \(text)", "No indicaste AM/PM, así que usé las \(text)"))
        }
        return ResolvedClock(hour: chosen, minute: minute)
    }

    private func to24(_ hour: Int, _ meridiem: Meridiem) -> Int {
        switch meridiem {
        case .am: return hour == 12 ? 0 : hour % 12
        case .pm: return hour == 12 ? 12 : (hour % 12) + 12
        }
    }

    // MARK: Day resolution

    private struct WeekdayResolution {
        var day: Date
        var wasNextWeek: Bool
        var plainWouldHaveBeen: Date?
        var modifier: WeekdayModifier

        func assumption(language: Language, calendar: Calendar, weekday: Int) -> String? {
            // Only "next <weekday>" is genuinely ambiguous: it can mean the coming one or the one after.
            guard modifier == .next, wasNextWeek, let plain = plainWouldHaveBeen, plain != day else { return nil }
            let formatted = NaturalDateParser.shortDateString(day, language: language, calendar: calendar)
            return language.pick("Interpreted “next” as the following week: \(formatted)", "Interpreté «próximo» como la semana siguiente: \(formatted)")
        }
    }

    private func resolveWeekday(_ weekday: Int, modifier: WeekdayModifier, today: Date, calendar: Calendar) -> WeekdayResolution {
        let todayWeekday = calendar.component(.weekday, from: today)
        let ahead = (weekday - todayWeekday + 7) % 7
        let upcoming = calendar.date(byAdding: .day, value: ahead, to: today) ?? today
        switch modifier {
        case .none, .this:
            return WeekdayResolution(day: upcoming, wasNextWeek: false, plainWouldHaveBeen: upcoming, modifier: modifier)
        case .next:
            let weekStart = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
            let nextWeekStart = calendar.date(byAdding: .weekOfYear, value: 1, to: weekStart) ?? weekStart
            let offsetInWeek = (weekday - calendar.firstWeekday + 7) % 7
            let day = calendar.date(byAdding: .day, value: offsetInWeek, to: nextWeekStart) ?? upcoming
            return WeekdayResolution(day: day, wasNextWeek: true, plainWouldHaveBeen: upcoming, modifier: modifier)
        case .last:
            var back = (todayWeekday - weekday + 7) % 7
            if back == 0 { back = 7 }
            let day = calendar.date(byAdding: .day, value: -back, to: today) ?? today
            return WeekdayResolution(day: day, wasNextWeek: false, plainWouldHaveBeen: nil, modifier: modifier)
        }
    }

    private func nextOccurrence(day: Int, month: Int, year: Int?, today: Date, calendar: Calendar) -> Date? {
        if let year {
            return calendar.date(from: DateComponents(year: year, month: month, day: day)).flatMap { validated($0, year: year, month: month, day: day, calendar: calendar) }
        }
        let currentYear = calendar.component(.year, from: today)
        for candidateYear in currentYear...(currentYear + 4) {
            if let date = calendar.date(from: DateComponents(year: candidateYear, month: month, day: day)),
               let valid = validated(date, year: candidateYear, month: month, day: day, calendar: calendar), valid >= today {
                return valid
            }
        }
        return nil
    }

    private func nextDayOfMonth(_ dayNumber: Int, today: Date, calendar: Calendar) -> Date? {
        let components = calendar.dateComponents([.year, .month], from: today)
        guard var year = components.year, var month = components.month else { return nil }
        for _ in 0..<14 {
            if let date = calendar.date(from: DateComponents(year: year, month: month, day: dayNumber)),
               let valid = validated(date, year: year, month: month, day: dayNumber, calendar: calendar), valid >= today {
                return valid
            }
            month += 1
            if month > 12 { month = 1; year += 1 }
        }
        return nil
    }

    private func validated(_ date: Date, year: Int, month: Int, day: Int, calendar: Calendar) -> Date? {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return parts.year == year && parts.month == month && parts.day == day ? date : nil
    }

    private func spanRange(_ scope: SpanScope, offset: Int, today: Date, calendar: Calendar) -> (start: Date, end: Date) {
        switch scope {
        case .week:
            let interval = calendar.dateInterval(of: .weekOfYear, for: today)
            let weekStart = interval?.start ?? today
            let start = calendar.date(byAdding: .weekOfYear, value: offset, to: weekStart) ?? weekStart
            let end = calendar.date(byAdding: .weekOfYear, value: 1, to: start) ?? start
            return (offset == 0 ? today : start, end)
        case .weekend:
            let weekStart = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
            let shifted = calendar.date(byAdding: .weekOfYear, value: offset, to: weekStart) ?? weekStart
            let saturdayOffset = (7 - calendar.firstWeekday + 7) % 7
            let saturday = calendar.date(byAdding: .day, value: saturdayOffset, to: shifted) ?? shifted
            let end = calendar.date(byAdding: .day, value: 2, to: saturday) ?? saturday
            let start = (offset == 0 && today > saturday) ? today : saturday
            return (start, end)
        case .month:
            let interval = calendar.dateInterval(of: .month, for: today)
            let monthStart = interval?.start ?? today
            let start = calendar.date(byAdding: .month, value: offset, to: monthStart) ?? monthStart
            let end = calendar.date(byAdding: .month, value: 1, to: start) ?? start
            return (offset == 0 ? today : start, end)
        case .year:
            let interval = calendar.dateInterval(of: .year, for: today)
            let yearStart = interval?.start ?? today
            let start = calendar.date(byAdding: .year, value: offset, to: yearStart) ?? yearStart
            let end = calendar.date(byAdding: .year, value: 1, to: start) ?? start
            return (offset == 0 ? today : start, end)
        }
    }

    // MARK: Helpers

    func combine(_ day: Date, hour: Int, minute: Int, calendar: Calendar) -> Date {
        let start = calendar.startOfDay(for: day)
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        components.second = 0
        if let found = calendar.nextDate(after: start.addingTimeInterval(-1), matching: components, matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward) {
            return found
        }
        return calendar.date(byAdding: DateComponents(hour: hour, minute: minute), to: start) ?? start
    }

    private func floorToMinute(_ date: Date, calendar: Calendar) -> Date {
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return calendar.date(from: components) ?? date
    }

    func formatClock(_ hour: Int, _ minute: Int) -> String {
        let suffix = hour >= 12 ? "PM" : "AM"
        let twelve = hour % 12 == 0 ? 12 : hour % 12
        return String(format: "%d:%02d %@", twelve, minute, suffix)
    }

    private func partOfDayLabel(_ part: PartOfDay, _ language: Language) -> String {
        switch (part, language) {
        case (.morning, .en): return "morning"
        case (.afternoon, .en): return "afternoon"
        case (.evening, .en): return "evening"
        case (.night, .en): return "night"
        case (.morning, .es): return "mañana"
        case (.afternoon, .es): return "tarde"
        case (.evening, .es): return "tarde-noche"
        case (.night, .es): return "noche"
        }
    }

    private func shortDate(_ date: Date, language: Language, calendar: Calendar) -> String {
        Self.shortDateString(date, language: language, calendar: calendar)
    }

    static func shortDateString(_ date: Date, language: Language, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = language.locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEEMMMd")
        return formatter.string(from: date)
    }
}
