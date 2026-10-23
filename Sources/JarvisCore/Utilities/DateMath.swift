import Foundation

/// Calendar arithmetic shared by the interpreter and the integrations. Everything is done in the supplied
/// `Calendar` (and therefore the user's time zone), including daylight-saving transitions.
public enum DateMath {
    /// The moment `hour:minute` on the calendar day of `day`. A local time that does not exist (the hour skipped by a
    /// spring-forward change) moves forward to the next valid time; an ambiguous time (fall-back) takes the first one.
    public static func combine(day: Date, hour: Int, minute: Int, calendar: Calendar) -> Date {
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

    /// Hour and minute of `date` in `calendar`.
    public static func clock(of date: Date, calendar: Calendar) -> (hour: Int, minute: Int) {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0, parts.minute ?? 0)
    }

    /// Moves `date` to another calendar day and/or time of day, leaving the rest unchanged.
    public static func moving(_ date: Date, toDay day: Date?, time: (hour: Int, minute: Int)?, calendar: Calendar) -> Date {
        let currentClock = clock(of: date, calendar: calendar)
        let targetDay = day ?? date
        let target = time ?? currentClock
        return combine(day: targetDay, hour: target.hour, minute: target.minute, calendar: calendar)
    }

    /// Whether two dates fall on the same calendar day.
    public static func sameDay(_ a: Date, _ b: Date, calendar: Calendar) -> Bool { calendar.isDate(a, inSameDayAs: b) }
}
