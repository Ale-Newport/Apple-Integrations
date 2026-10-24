import Foundation

/// A user command arriving at the engine from any front-end (SwiftUI window, menu bar, hotkey, IPC, voice…).
public struct CommandRequest: Sendable, Hashable {
    public var text: String
    /// Forces the response language; otherwise the user's preference or automatic detection is used.
    public var language: Language?
    public var source: CommandSource
    /// Scopes "yes / no / option 2" replies. Each front-end (or IPC client) uses its own session id.
    public var session: String
    /// Bypasses duplicate suppression (explicit "run again").
    public var allowDuplicate: Bool

    public init(
        text: String, language: Language? = nil, source: CommandSource = .app, session: String = "default",
        allowDuplicate: Bool = false
    ) {
        self.text = text
        self.language = language
        self.source = source
        self.session = session
        self.allowDuplicate = allowDuplicate
    }
}

/// The complete answer to one command: what was understood, what ran, and what really happened.
public struct EngineResponse: Sendable, Hashable, Codable, Identifiable {
    public enum Status: String, Codable, Sendable, Hashable {
        /// Every step completed.
        case completed
        /// Some steps completed, others did not.
        case partial
        case failed
        case permissionRequired = "permission_required"
        case needsConfirmation = "needs_confirmation"
        case needsClarification = "needs_clarification"
        case setupRequired = "setup_required"
        case unavailable
        case unsupported
        case duplicate
        case cancelled
        /// The command was understood as conversation and answered without running tools.
        case reply
        case unrecognized
    }

    public var id: UUID
    public var input: String
    public var language: Language
    public var status: Status
    public var message: String
    public var results: [ToolResult]
    public var interpreter: String
    public var startedAt: Date
    public var durationMs: Int

    public var success: Bool { status == .completed || status == .reply }

    public init(
        id: UUID = UUID(),
        input: String,
        language: Language,
        status: Status,
        message: String,
        results: [ToolResult] = [],
        interpreter: String = "none",
        startedAt: Date = Date(),
        durationMs: Int = 0
    ) {
        self.id = id
        self.input = input
        self.language = language
        self.status = status
        self.message = message
        self.results = results
        self.interpreter = interpreter
        self.startedAt = startedAt
        self.durationMs = durationMs
    }

    /// The tool of the only step, or `nil` for conversational responses and multi-step plans.
    public var primaryTool: ToolName? { results.count == 1 ? results[0].tool : nil }

    private enum CodingKeys: String, CodingKey {
        case id, input, language, status, success, message, results, interpreter
        case startedAt = "started_at"
        case durationMs = "duration_ms"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        input = try c.decode(String.self, forKey: .input)
        language = try c.decode(Language.self, forKey: .language)
        status = try c.decode(Status.self, forKey: .status)
        message = try c.decode(String.self, forKey: .message)
        results = try c.decodeIfPresent([ToolResult].self, forKey: .results) ?? []
        interpreter = try c.decodeIfPresent(String.self, forKey: .interpreter) ?? "none"
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date()
        durationMs = try c.decodeIfPresent(Int.self, forKey: .durationMs) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(input, forKey: .input)
        try c.encode(language, forKey: .language)
        try c.encode(status, forKey: .status)
        try c.encode(success, forKey: .success)
        try c.encode(message, forKey: .message)
        try c.encode(results, forKey: .results)
        try c.encode(interpreter, forKey: .interpreter)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encode(durationMs, forKey: .durationMs)
    }
}

/// Progress notifications emitted while a command runs, so front-ends can show live state.
public enum EngineEvent: Sendable {
    /// The command was understood; these steps will run (in this order).
    case planned(commandID: UUID, steps: [PlannedStep])
    case responseText(commandID: UUID, text: String)
    case stepStarted(commandID: UUID, callID: UUID)
    case stepFinished(commandID: UUID, result: ToolResult)
}

public struct PlannedStep: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var tool: ToolName
    public var integration: IntegrationID?

    public init(id: UUID, tool: ToolName, integration: IntegrationID?) {
        self.id = id
        self.tool = tool
        self.integration = integration
    }
}

public typealias EngineEventHandler = @Sendable (EngineEvent) -> Void

/// What the user decided about a pending confirmation or clarification.
public enum PendingDecision: Sendable, Hashable {
    case confirm
    case cancel
    /// Zero-based index into the clarification options.
    case choose(Int)
}
