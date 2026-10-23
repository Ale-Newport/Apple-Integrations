import Foundation
import JarvisCore

enum Meridiem: Sendable, Hashable { case am, pm }

enum PartOfDay: Sendable, Hashable { case morning, afternoon, evening, night }

enum NamedTime: Sendable, Hashable { case noon, midnight }

enum WeekdayModifier: Sendable, Hashable {
    case none, this, next, last
}

enum SpanScope: Sendable, Hashable { case week, weekend, month, year }

/// A quantity expressed in calendar-aware units ("1 hour 30 minutes", "2 weeks").
struct DurationValue: Sendable, Hashable {
    var seconds: Double = 0
    var days: Int = 0
    var months: Int = 0
    var years: Int = 0

    var isZero: Bool { seconds == 0 && days == 0 && months == 0 && years == 0 }
    /// Only clock units (hours/minutes/seconds), suitable for timers and event durations.
    var isClockOnly: Bool { days == 0 && months == 0 && years == 0 }
    /// Total seconds, treating a day as 24 h (only meaningful for durations, not calendar arithmetic).
    var totalSeconds: Double { seconds + Double(days) * 86_400 + Double(months) * 30 * 86_400 + Double(years) * 365 * 86_400 }
}

struct ClockTime: Sendable, Hashable {
    var hour: Int
    var minute: Int
    var meridiem: Meridiem?
    /// `true` when the notation itself proves the 24-hour clock (`18:30`, `0:15`).
    var twentyFourHour: Bool
}

/// One date/time expression found in a clause.
struct DatePiece: Sendable, Hashable {
    enum Kind: Sendable, Hashable {
        case dayOffset(Int)
        case weekday(Int, WeekdayModifier)
        case span(SpanScope, offset: Int)
        /// "the next 7 days": from now through the end of the day N days ahead.
        case upcoming(days: Int)
        case absolute(day: Int, month: Int, year: Int?)
        case numeric(first: Int, second: Int, year: Int?)
        case iso(year: Int, month: Int, day: Int)
        case ordinalDay(Int)
        case relative(DurationValue)
        case clock(ClockTime)
        case named(NamedTime)
        case partOfDay(PartOfDay)
        case duration(DurationValue)
        case timeRange(start: ClockTime, end: ClockTime)
    }

    var kind: Kind
    var range: Range<Int>
    var priority: Int
}

/// The resolved meaning of all date/time expressions in a clause.
struct ParsedWhen: Sendable {
    var pieces: [DatePiece] = []
    /// Character ranges to cut out of the clause so that the remaining text is the "what".
    var consumed: [Range<Int>] = []

    /// Start of the resolved calendar day, when a date was given or implied by a time.
    var day: Date?
    var hour: Int?
    var minute: Int?
    var timeIsExplicit = false
    /// The resolved start instant (date and time known).
    var instant: Date?
    var endInstant: Date?
    /// End of an explicit clock range ("from 3 to 4 pm"), as wall-clock hour and minute.
    var rangeEnd: (hour: Int, minute: Int)?
    var duration: TimeInterval?
    /// "this week", "next month" …
    var span: (start: Date, end: Date)?
    var dayCameFromSpan = false
    var assumptions: [String] = []

    var isEmpty: Bool { pieces.isEmpty }
    var hasDate: Bool { day != nil && !dayWasImplied }
    var hasTime: Bool { hour != nil }
    var dayWasImplied = false
}
