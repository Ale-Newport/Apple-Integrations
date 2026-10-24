import Foundation

/// How dangerous a tool is. Drives confirmation and duplicate-protection behaviour in the engine.
public enum ToolSafety: String, Codable, Sendable, Hashable {
    /// Never changes anything (list, search, read, status).
    case readOnly = "read_only"
    /// Creates or changes data, but nothing is lost permanently.
    case modifying
    /// Deletes data. The engine never executes these without an explicit, single-use confirmation.
    case destructive
}

/// Whether the installed macOS actually offers the capability behind a tool.
public enum ToolAvailability: Sendable, Hashable {
    case supported
    /// The capability does not exist in public Apple interfaces. The tool is still registered so the
    /// interpreter can recognise the request and the user receives an honest explanation.
    case unsupported(reason: LocalizedText, alternative: LocalizedText?)
}

/// The type of a tool parameter, used by the validator, the LLM prompt builder and the documentation.
public enum ParameterKind: Sendable, Hashable {
    case string(maxLength: Int)
    case integer(min: Int?, max: Int?)
    case number(min: Double?, max: Double?)
    case boolean
    /// ISO-8601 date-time with a UTC offset (`2026-10-18T18:00:00-04:00`); a local date-time without offset is
    /// interpreted in the user's time zone.
    case dateTime
    /// Calendar day without time, `yyyy-MM-dd`.
    case date
    /// Either of the two above.
    case dateOrDateTime
    /// Wall-clock time of day, `HH:mm` (24 h).
    case time
    case enumeration([String])
    case stringList(maxItems: Int, maxLength: Int)

    public var typeName: String {
        switch self {
        case .string: return "string"
        case .integer: return "integer"
        case .number: return "number"
        case .boolean: return "boolean"
        case .dateTime: return "datetime"
        case .date: return "date"
        case .dateOrDateTime: return "date|datetime"
        case .time: return "time"
        case .enumeration(let values): return "enum(" + values.joined(separator: "|") + ")"
        case .stringList: return "string[]"
        }
    }
}

/// A single declared parameter of a tool.
public struct ToolParameter: Sendable, Hashable {
    public let name: String
    public let kind: ParameterKind
    public let required: Bool
    public let summary: String
    public let defaultValue: JSONValue?

    public init(
        name: String, kind: ParameterKind, required: Bool = false, summary: String, defaultValue: JSONValue? = nil
    ) {
        self.name = name
        self.kind = kind
        self.required = required
        self.summary = summary
        self.defaultValue = defaultValue
    }

    // Terse factories used by the integrations' tool tables.

    public static func string(_ name: String, _ summary: String, required: Bool = false, maxLength: Int = 2_000)
        -> ToolParameter
    {
        ToolParameter(name: name, kind: .string(maxLength: maxLength), required: required, summary: summary)
    }

    public static func integer(
        _ name: String, _ summary: String, required: Bool = false, min: Int? = nil, max: Int? = nil,
        default value: Int? = nil
    ) -> ToolParameter {
        ToolParameter(
            name: name, kind: .integer(min: min, max: max), required: required, summary: summary,
            defaultValue: value.map(JSONValue.int))
    }

    public static func number(
        _ name: String, _ summary: String, required: Bool = false, min: Double? = nil, max: Double? = nil,
        default value: Double? = nil
    ) -> ToolParameter {
        ToolParameter(
            name: name, kind: .number(min: min, max: max), required: required, summary: summary,
            defaultValue: value.map(JSONValue.double))
    }

    public static func boolean(_ name: String, _ summary: String, required: Bool = false, default value: Bool? = nil)
        -> ToolParameter
    {
        ToolParameter(
            name: name, kind: .boolean, required: required, summary: summary, defaultValue: value.map(JSONValue.bool))
    }

    public static func dateTime(_ name: String, _ summary: String, required: Bool = false) -> ToolParameter {
        ToolParameter(name: name, kind: .dateTime, required: required, summary: summary)
    }

    public static func date(_ name: String, _ summary: String, required: Bool = false) -> ToolParameter {
        ToolParameter(name: name, kind: .date, required: required, summary: summary)
    }

    public static func dateOrDateTime(_ name: String, _ summary: String, required: Bool = false) -> ToolParameter {
        ToolParameter(name: name, kind: .dateOrDateTime, required: required, summary: summary)
    }

    public static func time(_ name: String, _ summary: String, required: Bool = false) -> ToolParameter {
        ToolParameter(name: name, kind: .time, required: required, summary: summary)
    }

    public static func choice(
        _ name: String, _ values: [String], _ summary: String, required: Bool = false, default value: String? = nil
    ) -> ToolParameter {
        ToolParameter(
            name: name, kind: .enumeration(values), required: required, summary: summary,
            defaultValue: value.map(JSONValue.string))
    }

    public static func strings(
        _ name: String, _ summary: String, required: Bool = false, maxItems: Int = 20, maxLength: Int = 200
    ) -> ToolParameter {
        ToolParameter(
            name: name, kind: .stringList(maxItems: maxItems, maxLength: maxLength), required: required,
            summary: summary)
    }
}

/// Cross-parameter rules that cannot be expressed per parameter.
public enum ToolConstraint: Sendable, Hashable {
    /// At least one of the listed parameters must be present.
    case atLeastOne([String])
    /// Exactly one of the listed parameters must be present.
    case exactlyOne([String])
    /// At most one of the listed parameters may be present.
    case atMostOne([String])

    public var parameterNames: [String] {
        switch self {
        case .atLeastOne(let names), .exactlyOne(let names), .atMostOne(let names): return names
        }
    }
}

/// A natural-language phrase together with the exact call it must produce. Examples double as
/// documentation, few-shot material for LLM interpreters and regression tests.
public struct ToolExample: Sendable, Hashable {
    public let phrase: String
    public let language: Language
    public let arguments: JSONObject

    public init(_ phrase: String, language: Language = .en, arguments: JSONObject) {
        self.phrase = phrase
        self.language = language
        self.arguments = arguments
    }
}

/// The complete, strongly typed contract of one tool.
public struct ToolDescriptor: Sendable, Hashable {
    public let name: ToolName
    public let integration: IntegrationID
    public let title: String
    public let summary: String
    public let parameters: [ToolParameter]
    public let constraints: [ToolConstraint]
    public let safety: ToolSafety
    public let availability: ToolAvailability
    /// Hard execution deadline enforced by the engine.
    public let timeout: TimeInterval
    /// Creation-style tools (create reminder/note/event/alarm, append text) where an accidental repeat would
    /// duplicate data. The engine suppresses an identical call seen within the duplicate window.
    public let deduplicate: Bool
    public let examples: [ToolExample]
    public let requiresConfirmation: Bool

    public init(
        name: ToolName,
        integration: IntegrationID,
        title: String,
        summary: String,
        parameters: [ToolParameter] = [],
        constraints: [ToolConstraint] = [],
        safety: ToolSafety,
        availability: ToolAvailability = .supported,
        timeout: TimeInterval = 30,
        deduplicate: Bool = false,
        examples: [ToolExample] = [],
        requiresConfirmation: Bool = false
    ) {
        self.name = name
        self.integration = integration
        self.title = title
        self.summary = summary
        self.parameters = parameters
        self.constraints = constraints
        self.safety = safety
        self.availability = availability
        self.timeout = timeout
        self.deduplicate = deduplicate
        self.examples = examples
        self.requiresConfirmation = requiresConfirmation
    }

    public func parameter(named name: String) -> ToolParameter? { parameters.first { $0.name == name } }

    public var isSupported: Bool {
        if case .supported = availability { return true }
        return false
    }

    /// Whether the tool changes state (used for duplicate protection).
    public var isMutating: Bool { safety != .readOnly }
}

extension ToolParameter {
    /// Standard JSON Schema, alongside the compact human-readable schema used by older interpreters.
    public var jsonSchema: JSONValue {
        var schema: JSONObject = ["description": .string(summary)]
        switch kind {
        case .string(let max):
            schema["type"] = "string"
            schema["maxLength"] = .int(max)
        case .integer(let min, let max):
            schema["type"] = "integer"
            if let min { schema["minimum"] = .int(min) }
            if let max { schema["maximum"] = .int(max) }
        case .number(let min, let max):
            schema["type"] = "number"
            if let min { schema["minimum"] = .double(min) }
            if let max { schema["maximum"] = .double(max) }
        case .boolean: schema["type"] = "boolean"
        case .enumeration(let options):
            schema["type"] = "string"
            schema["enum"] = .array(options.map(JSONValue.string))
        case .stringList(let maxItems, let maxLength):
            schema["type"] = "array"
            schema["maxItems"] = .int(maxItems)
            schema["items"] = ["type": "string", "maxLength": .int(maxLength)]
        case .dateTime:
            schema["type"] = "string"
            schema["format"] = "date-time"
        case .date:
            schema["type"] = "string"
            schema["format"] = "date"
        case .dateOrDateTime:
            schema["type"] = "string"
            schema["anyOf"] = [["format": "date"], ["format": "date-time"]]
        case .time:
            schema["type"] = "string"
            schema["pattern"] = #"^([01][0-9]|2[0-3]):[0-5][0-9]$"#
        }
        if let defaultValue { schema["default"] = defaultValue }
        return .object(schema)
    }
}
