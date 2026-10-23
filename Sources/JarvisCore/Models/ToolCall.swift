import Foundation

/// A request to run one tool with JSON arguments. This is the *only* thing that crosses the boundary
/// between interpretation (deterministic parser, LLM, IPC client) and execution.
public struct ToolCall: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var tool: ToolName
    public var arguments: JSONObject
    /// Human-readable decisions the interpreter made on the user's behalf ("Assumed 6:00 PM").
    /// They are echoed back in the result so the user can correct them.
    public var assumptions: [String]
    /// The fragment of the user's text this call was derived from (for diagnostics and history).
    public var sourceText: String?

    public init(
        id: UUID = UUID(),
        tool: ToolName,
        arguments: JSONObject = [:],
        assumptions: [String] = [],
        sourceText: String? = nil
    ) {
        self.id = id
        self.tool = tool
        self.arguments = arguments
        self.assumptions = assumptions
        self.sourceText = sourceText
    }

    private enum CodingKeys: String, CodingKey {
        case id, tool, arguments, assumptions
        case sourceText = "source_text"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        tool = try container.decode(ToolName.self, forKey: .tool)
        arguments = try container.decodeIfPresent(JSONObject.self, forKey: .arguments) ?? [:]
        assumptions = try container.decodeIfPresent([String].self, forKey: .assumptions) ?? []
        sourceText = try container.decodeIfPresent(String.self, forKey: .sourceText)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(tool, forKey: .tool)
        try container.encode(arguments, forKey: .arguments)
        if !assumptions.isEmpty { try container.encode(assumptions, forKey: .assumptions) }
        try container.encodeIfPresent(sourceText, forKey: .sourceText)
    }

    /// Returns a copy with arguments merged on top of the current ones.
    public func adding(_ extra: JSONObject) -> ToolCall {
        var copy = self
        for (key, value) in extra { copy.arguments[key] = value }
        return copy
    }
}

/// An ordered list of tool calls produced from one user command.
public struct ToolPlan: Sendable, Hashable {
    public var steps: [ToolCall]
    public var language: Language
    /// Identifier of the interpreter that produced the plan (`deterministic`, an AI provider id…).
    public var interpreter: String
    /// Parts of the command that were not understood or need more information; shown after the results.
    public var notes: [String]

    public init(steps: [ToolCall], language: Language, interpreter: String, notes: [String] = []) {
        self.steps = steps
        self.language = language
        self.interpreter = interpreter
        self.notes = notes
    }
}
