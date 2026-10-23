import Foundation
import JarvisCore

/// The only thing a language-model provider has to implement: turn a system prompt and a user message into text.
///
/// Laya, a locally installed model (llama.cpp / MLX / Ollama…) or any hosted LLM API can sit behind this protocol
/// without the execution engine knowing anything about it. Providers must **never** be given the power to run
/// code: their output is parsed as data and validated against the tool schemas like any other request.
public protocol LLMTextProvider: Sendable {
    /// Short stable identifier recorded in plans and history (`laya`, `local-llama`, …).
    var identifier: String { get }
    func complete(system: String, user: String) async throws -> String
}

/// Builds the prompt that makes a model answer with structured tool calls instead of prose.
public enum LLMPromptBuilder {
    public static func systemPrompt(for request: InterpretationRequest) -> String {
        let tools = request.tools.filter(\.isSupported)
        let schema = schemaJSON(tools)
        var examples: [String] = []
        for tool in tools {
            for example in tool.examples.prefix(1) {
                let arguments = (try? String(data: JSONEncoder().encode(JSONValue.object(example.arguments)), encoding: .utf8)) ?? "{}"
                examples.append("User: \(example.phrase)\nAnswer: {\"calls\":[{\"tool\":\"\(tool.name.rawValue)\",\"arguments\":\(arguments)}]}")
            }
        }
        let now = ISODates.string(from: request.now, timeZone: request.calendar.timeZone)
        return """
        You are the command interpreter of a macOS assistant that controls Apple Music, Reminders, Notes, Calendar and Clock.
        Convert the user's message into tool calls. Reply with ONE JSON object and nothing else:
        {"calls":[{"tool":"<tool name>","arguments":{…}}],"question":"<only when information is missing>","reply":"<only for small talk>"}

        Rules:
        - Use only the tools below, with only the parameters they declare. Never invent tools or parameters.
        - Never output code, shell commands, AppleScript or URLs to run. Output data only.
        - Resolve relative dates yourself. Right now it is \(now) (time zone \(request.calendar.timeZone.identifier); weeks start on \(request.calendar.firstWeekday == 2 ? "Monday" : "the locale's first weekday")).
        - Date-times must be ISO-8601 with a UTC offset; plain days are yyyy-MM-dd; times of day are HH:mm (24 h).
        - A command may need several calls ("play X and remind me to Y").
        - If a required detail is missing, ask for it in "question" and return no calls.
        - Keep titles, names and text in the user's own language and spelling.

        Tools (JSON):
        \(schema)

        Examples:
        \(examples.prefix(14).joined(separator: "\n"))
        """
    }

    private static func schemaJSON(_ tools: [ToolDescriptor]) -> String {
        let registry = ToolRegistry(integrations: [SchemaOnlyIntegration(tools: tools)])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? String(data: encoder.encode(registry.schemaDescription()), encoding: .utf8)) ?? "[]"
    }
}

/// A throw-away integration used only to render descriptors as JSON.
private struct SchemaOnlyIntegration: AppIntegration {
    let id: IntegrationID = "schema"
    let displayName = LocalizedText("schema")
    let summary = LocalizedText("schema")
    let symbolName = "doc"
    let permissionRequirements: [PermissionRequirement] = []
    let tools: [ToolDescriptor]
    func status() async -> IntegrationStatus { IntegrationStatus(state: .ready) }
    func authorization(for tool: ToolDescriptor) async -> AuthorizationState { .authorized }
    func requestAuthorization(for tool: ToolDescriptor) async -> AuthorizationState { .authorized }
    func execute(_ call: ValidatedToolCall, context: ExecutionContext) async throws -> ToolOutcome {
        throw JarvisError.cancelled
    }
}

/// Turns raw model text into an ``AIProposal``. The model is untrusted: this accepts only plain JSON data.
public enum AIProposalParser {
    public enum ParseError: Error, Equatable { case noJSON, malformed, tooManyCalls }

    public static let maxCalls = 10

    public static func parse(_ raw: String) throws -> AIProposal {
        guard let json = extractJSON(raw), let data = json.data(using: .utf8) else { throw ParseError.noJSON }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { throw ParseError.malformed }

        var callValues: [JSONValue] = []
        var question: String?
        var reply: String?
        switch value {
        case .array(let items):
            callValues = items
        case .object(let object):
            if let calls = object["calls"]?.arrayValue ?? object["tool_calls"]?.arrayValue { callValues = calls }
            else if object["tool"] != nil || object["name"] != nil { callValues = [value] }
            question = object["question"]?.stringValue ?? object["clarifying_question"]?.stringValue
            reply = object["reply"]?.stringValue
        default:
            throw ParseError.malformed
        }
        guard callValues.count <= maxCalls else { throw ParseError.tooManyCalls }

        var calls: [ProposedToolCall] = []
        for item in callValues {
            guard let object = item.objectValue, let name = (object["tool"] ?? object["name"])?.stringValue else { continue }
            let arguments = (object["arguments"] ?? object["args"] ?? object["parameters"])?.objectValue ?? [:]
            calls.append(ProposedToolCall(tool: name, arguments: arguments))
        }
        return AIProposal(calls: calls, clarifyingQuestion: question?.nilIfBlank, reply: reply?.nilIfBlank)
    }

    /// Finds the first balanced JSON object/array in `text`, ignoring Markdown fences and chatter around it.
    static func extractJSON(_ text: String) -> String? {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            cleaned = cleaned.drop(while: { $0 != "\n" }).dropFirst().description
            if let fence = cleaned.range(of: "```", options: .backwards) { cleaned = String(cleaned[..<fence.lowerBound]) }
        }
        let characters = Array(cleaned)
        guard let start = characters.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return nil }
        let open = characters[start]
        let close: Character = open == "{" ? "}" : "]"
        var depth = 0
        var inString = false
        var escaped = false
        for index in start..<characters.count {
            let character = characters[index]
            if inString {
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
                continue
            }
            if character == "\"" { inString = true }
            else if character == open { depth += 1 }
            else if character == close {
                depth -= 1
                if depth == 0 { return String(characters[start...index]) }
            }
        }
        return nil
    }
}

private extension String {
    var nilIfBlank: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}

/// An ``AICommandInterpreter`` backed by any ``LLMTextProvider``.
public struct LLMToolCallInterpreter: AICommandInterpreter {
    private let provider: any LLMTextProvider
    public var identifier: String { "llm." + provider.identifier }

    public init(provider: any LLMTextProvider) { self.provider = provider }

    public func propose(_ request: InterpretationRequest) async throws -> AIProposal {
        let system = LLMPromptBuilder.systemPrompt(for: request)
        let raw = try await provider.complete(system: system, user: request.text)
        return try AIProposalParser.parse(raw)
    }
}

/// Wraps an ``AICommandInterpreter`` as a ``CommandInterpreting``: proposals become plans, questions become
/// clarifications. Unknown tool names are rejected here; argument validation happens in the engine like for any call.
public struct AIInterpreterAdapter: CommandInterpreting {
    private let ai: any AICommandInterpreter
    public var identifier: String { ai.identifier }

    public init(_ ai: any AICommandInterpreter) { self.ai = ai }

    public func interpret(_ request: InterpretationRequest) async throws -> Interpretation {
        let proposal: AIProposal
        do {
            proposal = try await ai.propose(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            JarvisLog.interpreter.error("AI interpreter failed: \(String(describing: type(of: error)), privacy: .public)")
            return .unrecognized(hint: nil)
        }
        let known = Set(request.tools.map(\.name.rawValue))
        let calls = proposal.calls.filter { known.contains($0.tool) }.map {
            ToolCall(tool: ToolName($0.tool), arguments: $0.arguments, sourceText: request.text)
        }
        if !calls.isEmpty { return .plan(ToolPlan(steps: calls, language: request.language, interpreter: ai.identifier)) }
        if let question = proposal.clarifyingQuestion { return .clarification(Clarification(question: question)) }
        if let reply = proposal.reply { return .reply(reply) }
        return .unrecognized(hint: nil)
    }
}

/// Deterministic parser first; the AI interpreter only sees what the rules could not understand.
/// Everything the AI proposes is validated and permission-checked by the same engine as any other call.
public struct HybridCommandInterpreter: CommandInterpreting {
    public enum Policy: Sendable {
        /// Rules first, AI as a fallback for unrecognised text (default; works offline and without AI).
        case deterministicFirst
        /// Ask the AI first, fall back to the rules if it fails or understands nothing.
        case aiFirst
    }

    public let identifier = "hybrid"
    private let deterministic: any CommandInterpreting
    private let ai: (any CommandInterpreting)?
    private let policy: Policy

    public init(deterministic: any CommandInterpreting = DeterministicInterpreter(), ai: (any AICommandInterpreter)? = nil, policy: Policy = .deterministicFirst) {
        self.deterministic = deterministic
        self.ai = ai.map { AIInterpreterAdapter($0) }
        self.policy = policy
    }

    public func interpret(_ request: InterpretationRequest) async throws -> Interpretation {
        guard let ai else { return try await deterministic.interpret(request) }
        switch policy {
        case .deterministicFirst:
            let first = try await deterministic.interpret(request)
            if case .unrecognized = first {
                let second = try await ai.interpret(request)
                if case .unrecognized = second { return first }
                return second
            }
            return first
        case .aiFirst:
            let first = try await ai.interpret(request)
            if case .unrecognized = first { return try await deterministic.interpret(request) }
            return first
        }
    }
}
