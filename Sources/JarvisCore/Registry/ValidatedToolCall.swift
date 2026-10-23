import Foundation

/// A tool call that passed schema validation. Arguments are normalised: strings trimmed, numbers coerced,
/// enumerations canonicalised, defaults applied and `null`/empty optionals removed.
public struct ValidatedToolCall: Sendable {
    public let call: ToolCall
    public let descriptor: ToolDescriptor
    public let arguments: JSONObject

    public init(call: ToolCall, descriptor: ToolDescriptor, arguments: JSONObject) {
        self.call = call
        self.descriptor = descriptor
        self.arguments = arguments
    }

    public func string(_ key: String) -> String? { arguments[key]?.stringValue }
    public func int(_ key: String) -> Int? { arguments[key]?.intValue }
    public func double(_ key: String) -> Double? { arguments[key]?.doubleValue }
    public func bool(_ key: String) -> Bool? { arguments[key]?.boolValue }
    public func strings(_ key: String) -> [String] { arguments[key]?.arrayValue?.compactMap(\.stringValue) ?? [] }
    public func has(_ key: String) -> Bool { arguments[key] != nil }

    /// Decodes the normalised arguments (snake_case keys) into a typed `Decodable` argument struct.
    public func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        do {
            return try JSONValue.object(arguments).decoded(as: type)
        } catch {
            throw JarvisError.validation([ValidationIssue(.invalidValue, "Could not decode arguments of \(descriptor.name): \(error.localizedDescription)")])
        }
    }
}

/// Everything about "now" and "who is asking" that an integration needs, captured once per command.
public struct ExecutionContext: Sendable {
    public var language: Language
    public var now: Date
    public var calendar: Calendar
    public var settings: JarvisSettings
    public var source: CommandSource
    /// `true` only when this exact call is being re-run after the user confirmed it.
    public var isConfirmed: Bool
    public var callID: UUID

    public var timeZone: TimeZone { calendar.timeZone }

    public init(
        language: Language,
        now: Date,
        calendar: Calendar,
        settings: JarvisSettings,
        source: CommandSource,
        isConfirmed: Bool = false,
        callID: UUID = UUID()
    ) {
        self.language = language
        self.now = now
        self.calendar = calendar
        self.settings = settings
        self.source = source
        self.isConfirmed = isConfirmed
        self.callID = callID
    }

    /// Localised string helper.
    public func t(_ english: @autoclosure () -> String, _ spanish: @autoclosure () -> String) -> String {
        language.pick(english(), spanish())
    }
}

/// Where a command came from. Open-ended so new front-ends (voice, widgets…) can identify themselves.
public struct CommandSource: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }

    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let app: CommandSource = "app"
    public static let menuBar: CommandSource = "menu_bar"
    public static let hotkey: CommandSource = "hotkey"
    public static let ipc: CommandSource = "ipc"
    public static let voice: CommandSource = "voice"
    public static let test: CommandSource = "test"
}
