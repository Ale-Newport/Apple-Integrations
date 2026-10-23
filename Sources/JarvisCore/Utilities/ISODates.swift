import Foundation

/// Parsing and formatting of the three date representations used in tool arguments:
///
/// * date-time: `2026-10-18T18:00:00-04:00` (offset optional → interpreted in the user's time zone)
/// * date: `2026-10-18`
/// * time: `18:30`
///
/// Everything is implemented on top of an explicit Gregorian `Calendar` so results never depend on the
/// user's calendar preferences or on global formatter state.
public enum ISODates {
    public struct DateParts: Sendable, Hashable {
        public var year: Int
        public var month: Int
        public var day: Int
    }

    public struct TimeParts: Sendable, Hashable {
        public var hour: Int
        public var minute: Int
        public var second: Int = 0
    }

    public enum Value: Sendable, Hashable {
        case dateTime(Date)
        case date(DateParts)
    }

    private static let dateTimePattern = try! NSRegularExpression(
        pattern: #"^(\d{4})-(\d{2})-(\d{2})(?:[Tt ](\d{2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?\s*(Z|z|[+-]\d{2}(?::?\d{2})?)?)?$"#
    )
    private static let timePattern = try! NSRegularExpression(pattern: #"^(\d{1,2}):(\d{2})(?::(\d{2}))?$"#)

    // MARK: Syntax checks (no time zone needed)

    public static func isDate(_ text: String) -> Bool { parseDateParts(text) != nil }

    public static func isDateTime(_ text: String) -> Bool { parse(text, timeZone: .gmt).flatMap { if case .dateTime = $0 { return true } else { return nil } } ?? false }

    public static func isDateOrDateTime(_ text: String) -> Bool { parse(text, timeZone: .gmt) != nil }

    // MARK: Parsing

    public static func parseDateParts(_ text: String) -> DateParts? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = parse(trimmed, timeZone: .gmt), case .date(let parts) = value else { return nil }
        return parts
    }

    public static func parseTime(_ text: String) -> TimeParts? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = timePattern.firstMatch(in: trimmed, range: range),
              let hour = int(match, 1, in: trimmed), let minute = int(match, 2, in: trimmed) else { return nil }
        let second = int(match, 3, in: trimmed) ?? 0
        guard (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else { return nil }
        return TimeParts(hour: hour, minute: minute, second: second)
    }

    /// Parses a date or date-time. When a date-time has no UTC offset it is interpreted in `timeZone`.
    public static func parse(_ text: String, timeZone: TimeZone) -> Value? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = dateTimePattern.firstMatch(in: trimmed, range: range),
              let year = int(match, 1, in: trimmed), let month = int(match, 2, in: trimmed), let day = int(match, 3, in: trimmed),
              (1...12).contains(month), (1...31).contains(day), year >= 1900, year <= 2200 else { return nil }

        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = .gmt
        // Reject impossible days such as 2026-02-31.
        guard let probe = gregorian.date(from: DateComponents(year: year, month: month, day: day)),
              gregorian.dateComponents([.year, .month, .day], from: probe) == DateComponents(year: year, month: month, day: day) else { return nil }

        guard let hour = int(match, 4, in: trimmed), let minute = int(match, 5, in: trimmed) else {
            return .date(DateParts(year: year, month: month, day: day))
        }
        let second = int(match, 6, in: trimmed) ?? 0
        guard (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else { return nil }

        var zone = timeZone
        if let offsetRange = Range(match.range(at: 7), in: trimmed) {
            let token = String(trimmed[offsetRange])
            guard let parsed = offsetZone(from: token) else { return nil }
            zone = parsed
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        var components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        components.timeZone = zone
        guard let date = calendar.date(from: components) else { return nil }
        return .dateTime(date)
    }

    /// Parses a date-time or returns the start of a plain date in `timeZone`.
    public static func date(from text: String, timeZone: TimeZone) -> Date? {
        guard let value = parse(text, timeZone: timeZone) else { return nil }
        switch value {
        case .dateTime(let date):
            return date
        case .date(let parts):
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            return calendar.date(from: DateComponents(year: parts.year, month: parts.month, day: parts.day))
        }
    }

    // MARK: Formatting

    /// `2026-10-18T18:00:00-04:00`
    public static func string(from date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let offset = timeZone.secondsFromGMT(for: date)
        let sign = offset < 0 ? "-" : "+"
        let absolute = abs(offset)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d%@%02d:%02d",
            c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0,
            sign, absolute / 3600, (absolute % 3600) / 60
        )
    }

    /// `2026-10-18`
    public static func dayString(from date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// `HH:mm`
    public static func timeString(hour: Int, minute: Int) -> String {
        String(format: "%02d:%02d", hour, minute)
    }

    // MARK: Helpers

    private static func int(_ match: NSTextCheckingResult, _ group: Int, in text: String) -> Int? {
        guard group < match.numberOfRanges, let range = Range(match.range(at: group), in: text) else { return nil }
        return Int(text[range])
    }

    private static func offsetZone(from token: String) -> TimeZone? {
        if token.uppercased() == "Z" { return TimeZone(secondsFromGMT: 0) }
        let sign = token.hasPrefix("-") ? -1 : 1
        let digits = token.dropFirst().replacingOccurrences(of: ":", with: "")
        guard digits.count == 2 || digits.count == 4, let value = Int(digits) else { return nil }
        let hours = digits.count == 2 ? value : value / 100
        let minutes = digits.count == 2 ? 0 : value % 100
        guard hours <= 18, minutes < 60 else { return nil }
        return TimeZone(secondsFromGMT: sign * (hours * 3600 + minutes * 60))
    }
}
