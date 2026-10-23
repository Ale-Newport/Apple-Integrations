import Foundation

/// Supplies "now" and the user's calendar/time zone. Injected so date handling is deterministic in tests.
public protocol DateProviding: Sendable {
    func now() -> Date
    /// A Gregorian calendar in the user's *current* time zone and locale (first weekday, etc.).
    func calendar() -> Calendar
}

public struct SystemDateProvider: DateProviding {
    public init() {}

    public func now() -> Date { Date() }

    public func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.autoupdatingCurrent
        calendar.locale = Locale.autoupdatingCurrent
        calendar.firstWeekday = Calendar.autoupdatingCurrent.firstWeekday
        return calendar
    }
}

/// A fixed clock for tests and previews.
public struct FixedDateProvider: DateProviding {
    public var fixedNow: Date
    public var timeZone: TimeZone
    public var firstWeekday: Int

    public init(now: Date, timeZone: TimeZone, firstWeekday: Int = 2) {
        self.fixedNow = now
        self.timeZone = timeZone
        self.firstWeekday = firstWeekday
    }

    public func now() -> Date { fixedNow }

    public func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = Locale(identifier: "en_US")
        calendar.firstWeekday = firstWeekday
        return calendar
    }
}
