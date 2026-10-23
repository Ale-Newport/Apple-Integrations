import Foundation

/// Everything an interpreter needs to turn text into tool calls.
public struct InterpretationRequest: Sendable {
    public var text: String
    public var language: Language
    public var now: Date
    public var calendar: Calendar
    public var settings: JarvisSettings
    /// The tools that currently exist. Deterministic interpreters ignore this; AI interpreters use it to
    /// build their prompt.
    public var tools: [ToolDescriptor]

    public init(text: String, language: Language, now: Date, calendar: Calendar, settings: JarvisSettings, tools: [ToolDescriptor] = []) {
        self.text = text
        self.language = language
        self.now = now
        self.calendar = calendar
        self.settings = settings
        self.tools = tools
    }
}

/// The outcome of interpreting one user command.
public enum Interpretation: Sendable {
    /// One or more tool calls to validate and run.
    case plan(ToolPlan)
    /// The command is understood but needs more information; options may be empty for free-text answers.
    case clarification(Clarification)
    /// A conversational answer that needs no tools (help, greetings, capability questions).
    case reply(String)
    /// The command was not understood. The optional hint tells the user what to try.
    case unrecognized(hint: String?)
}

/// Turns natural language into structured tool calls. Implementations never execute anything.
public protocol CommandInterpreting: Sendable {
    /// Short stable identifier (`deterministic`, `llm.laya`, …) recorded with each plan.
    var identifier: String { get }
    func interpret(_ request: InterpretationRequest) async throws -> Interpretation
}

/// A pluggable AI-backed interpreter.
///
/// Concrete providers (Laya, a local model, any hosted LLM API) implement only ``propose(_:)``. Whatever
/// they return is treated as **untrusted data**: it is parsed into ``ProposedToolCall`` values and then
/// validated against the same tool schemas as every other call. A provider can never cause arbitrary
/// code to run — the worst it can produce is an invalid call, which is rejected.
public protocol AICommandInterpreter: Sendable {
    var identifier: String { get }
    func propose(_ request: InterpretationRequest) async throws -> AIProposal
}

/// A model's answer: tool calls, a question, or a plain reply.
public struct AIProposal: Sendable, Hashable {
    public var calls: [ProposedToolCall]
    public var clarifyingQuestion: String?
    public var reply: String?

    public init(calls: [ProposedToolCall] = [], clarifyingQuestion: String? = nil, reply: String? = nil) {
        self.calls = calls
        self.clarifyingQuestion = clarifyingQuestion
        self.reply = reply
    }
}

public struct ProposedToolCall: Sendable, Hashable {
    public var tool: String
    public var arguments: JSONObject

    public init(tool: String, arguments: JSONObject) {
        self.tool = tool
        self.arguments = arguments
    }
}
