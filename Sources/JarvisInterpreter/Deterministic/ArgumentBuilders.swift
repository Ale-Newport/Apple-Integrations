import Foundation
import JarvisCore

/// Helpers that turn parsed dates into tool-call arguments.
enum ArgumentBuilders {
    static func dateTime(_ date: Date, calendar: Calendar) -> JSONValue {
        .string(ISODates.string(from: date, timeZone: calendar.timeZone))
    }

    static func day(_ date: Date, calendar: Calendar) -> JSONValue {
        .string(ISODates.dayString(from: date, timeZone: calendar.timeZone))
    }

    /// `due` for reminders: a date-time when a time is known, otherwise a plain date.
    static func dueValue(_ when: ParsedWhen, calendar: Calendar) -> JSONValue? {
        if let instant = when.instant { return dateTime(instant, calendar: calendar) }
        if let day = when.day, !when.dayWasImplied { return Self.day(day, calendar: calendar) }
        return nil
    }

    /// The query window for list-style commands: `[start, end)`.
    static func window(_ when: ParsedWhen, calendar: Calendar) -> (start: Date, end: Date)? {
        if let span = when.span { return (span.start, span.end) }
        if let day = when.day {
            let start = calendar.startOfDay(for: day)
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
            return (start, end)
        }
        return nil
    }

    static func time(hour: Int, minute: Int) -> JSONValue {
        .string(ISODates.timeString(hour: hour, minute: minute))
    }
}

extension FoldedText {
    /// Whole-text match against the folded form.
    func wholeMatch(_ regex: NSRegularExpression, groups: [String] = []) -> MatchedClause? {
        guard let match = firstMatch(regex, groupNames: groups), match.range == 0..<count else { return nil }
        return MatchedClause(text: self, match: match)
    }

    func findMatchInOriginal(_ regex: NSRegularExpression, groups: [String] = []) -> MatchedClause? {
        guard let match = firstMatchInOriginal(regex, groupNames: groups) else { return nil }
        return MatchedClause(text: self, match: match)
    }

    func findMatch(_ regex: NSRegularExpression, groups: [String] = []) -> MatchedClause? {
        guard let match = firstMatch(regex, groupNames: groups) else { return nil }
        return MatchedClause(text: self, match: match)
    }
}
