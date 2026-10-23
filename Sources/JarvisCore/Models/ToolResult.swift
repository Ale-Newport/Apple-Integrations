import Foundation

/// Evidence that an action really happened. Integrations must read back the state they changed before
/// claiming success; when that is impossible the result is explicitly marked `unverified`.
public enum Verification: Sendable, Hashable, Codable {
    /// The change was read back from the owning application (the detail says how).
    case verified(String)
    /// The operation reported success but the outcome could not be confirmed (the detail says why).
    case unverified(String)
    /// Nothing to verify (read-only tools).
    case notApplicable

    public var isVerified: Bool { if case .verified = self { return true } else { return false } }

    private enum CodingKeys: String, CodingKey { case state, detail }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let state = try container.decode(String.self, forKey: .state)
        let detail = try container.decodeIfPresent(String.self, forKey: .detail) ?? ""
        switch state {
        case "verified": self = .verified(detail)
        case "unverified": self = .unverified(detail)
        default: self = .notApplicable
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .verified(let detail):
            try container.encode("verified", forKey: .state)
            try container.encode(detail, forKey: .detail)
        case .unverified(let detail):
            try container.encode("unverified", forKey: .state)
            try container.encode(detail, forKey: .detail)
        case .notApplicable:
            try container.encode("not_applicable", forKey: .state)
        }
    }
}

/// What an integration returns when a tool ran successfully.
public struct ToolOutput: Sendable, Hashable {
    public var message: String
    public var data: JSONValue?
    public var verification: Verification
    public var warnings: [String]

    public init(message: String, data: JSONValue? = nil, verification: Verification, warnings: [String] = []) {
        self.message = message
        self.data = data
        self.verification = verification
        self.warnings = warnings
    }
}

/// A single-use question the engine asks before running something risky or ambiguous.
public struct ConfirmationRequest: Sendable, Hashable, Codable {
    public var prompt: String
    /// The exact call that will run if the user confirms (already resolved to concrete identifiers).
    public var call: ToolCall
    public var destructive: Bool
    /// Filled in by the engine; the token is required to confirm or cancel.
    public var token: String?

    public init(prompt: String, call: ToolCall, destructive: Bool, token: String? = nil) {
        self.prompt = prompt
        self.call = call
        self.destructive = destructive
        self.token = token
    }
}

/// One choice offered to the user when a request matched several things.
public struct ClarificationOption: Sendable, Hashable, Codable {
    public var label: String
    public var detail: String?
    /// The fully specified call that resolves the ambiguity.
    public var call: ToolCall

    public init(label: String, detail: String? = nil, call: ToolCall) {
        self.label = label
        self.detail = detail
        self.call = call
    }
}

/// A question for the user, optionally with ready-to-run options.
public struct Clarification: Sendable, Hashable, Codable {
    public var question: String
    public var options: [ClarificationOption]
    public var token: String?

    public init(question: String, options: [ClarificationOption] = [], token: String? = nil) {
        self.question = question
        self.options = options
        self.token = token
    }
}

/// Describes a macOS privacy permission or automation consent an integration depends on.
public struct PermissionRequirement: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var title: LocalizedText
    /// Why Jarvis needs it, shown before the system prompt and in Settings.
    public var rationale: LocalizedText
    /// A `x-apple.systempreferences:` URL that opens the right pane.
    public var settingsURL: String?

    public init(id: String, title: LocalizedText, rationale: LocalizedText, settingsURL: String? = nil) {
        self.id = id
        self.title = title
        self.rationale = rationale
        self.settingsURL = settingsURL
    }
}

/// Step-by-step instructions for one-time manual setup (for example creating the Clock shortcuts).
public struct SetupInstructions: Sendable, Hashable, Codable {
    public var title: String
    public var steps: [String]
    public var documentation: String?

    public init(title: String, steps: [String], documentation: String? = nil) {
        self.title = title
        self.steps = steps
        self.documentation = documentation
    }
}

/// The final, structured outcome of one tool call.
public struct ToolResult: Sendable, Hashable, Codable, Identifiable {
    public enum Status: String, Codable, Sendable, Hashable {
        case completed
        case failed
        case permissionRequired = "permission_required"
        case needsConfirmation = "needs_confirmation"
        case needsClarification = "needs_clarification"
        case setupRequired = "setup_required"
        case unavailable
        case unsupported
        case skipped
        case cancelled
        case duplicate
    }

    public var id: UUID { callID }
    public var callID: UUID
    public var tool: ToolName
    public var status: Status
    public var message: String
    public var data: JSONValue?
    public var verification: Verification
    /// Stable machine-readable error code when the status is not `completed`.
    public var errorCode: String?
    public var confirmation: ConfirmationRequest?
    public var clarification: Clarification?
    public var permission: PermissionRequirement?
    public var setup: SetupInstructions?
    public var assumptions: [String]
    public var warnings: [String]
    public var durationMs: Int

    public var success: Bool { status == .completed }

    public init(
        callID: UUID,
        tool: ToolName,
        status: Status,
        message: String,
        data: JSONValue? = nil,
        verification: Verification = .notApplicable,
        errorCode: String? = nil,
        confirmation: ConfirmationRequest? = nil,
        clarification: Clarification? = nil,
        permission: PermissionRequirement? = nil,
        setup: SetupInstructions? = nil,
        assumptions: [String] = [],
        warnings: [String] = [],
        durationMs: Int = 0
    ) {
        self.callID = callID
        self.tool = tool
        self.status = status
        self.message = message
        self.data = data
        self.verification = verification
        self.errorCode = errorCode
        self.confirmation = confirmation
        self.clarification = clarification
        self.permission = permission
        self.setup = setup
        self.assumptions = assumptions
        self.warnings = warnings
        self.durationMs = durationMs
    }

    private enum CodingKeys: String, CodingKey {
        case callID = "call_id"
        case tool, status, message, data, verification
        case errorCode = "error_code"
        case confirmation, clarification, permission, setup, assumptions, warnings
        case durationMs = "duration_ms"
        case success
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        callID = try c.decode(UUID.self, forKey: .callID)
        tool = try c.decode(ToolName.self, forKey: .tool)
        status = try c.decode(Status.self, forKey: .status)
        message = try c.decode(String.self, forKey: .message)
        data = try c.decodeIfPresent(JSONValue.self, forKey: .data)
        verification = try c.decodeIfPresent(Verification.self, forKey: .verification) ?? .notApplicable
        errorCode = try c.decodeIfPresent(String.self, forKey: .errorCode)
        confirmation = try c.decodeIfPresent(ConfirmationRequest.self, forKey: .confirmation)
        clarification = try c.decodeIfPresent(Clarification.self, forKey: .clarification)
        permission = try c.decodeIfPresent(PermissionRequirement.self, forKey: .permission)
        setup = try c.decodeIfPresent(SetupInstructions.self, forKey: .setup)
        assumptions = try c.decodeIfPresent([String].self, forKey: .assumptions) ?? []
        warnings = try c.decodeIfPresent([String].self, forKey: .warnings) ?? []
        durationMs = try c.decodeIfPresent(Int.self, forKey: .durationMs) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(callID, forKey: .callID)
        try c.encode(tool, forKey: .tool)
        try c.encode(status, forKey: .status)
        try c.encode(success, forKey: .success)
        try c.encode(message, forKey: .message)
        try c.encodeIfPresent(data, forKey: .data)
        try c.encode(verification, forKey: .verification)
        try c.encodeIfPresent(errorCode, forKey: .errorCode)
        try c.encodeIfPresent(confirmation, forKey: .confirmation)
        try c.encodeIfPresent(clarification, forKey: .clarification)
        try c.encodeIfPresent(permission, forKey: .permission)
        try c.encodeIfPresent(setup, forKey: .setup)
        if !assumptions.isEmpty { try c.encode(assumptions, forKey: .assumptions) }
        if !warnings.isEmpty { try c.encode(warnings, forKey: .warnings) }
        try c.encode(durationMs, forKey: .durationMs)
    }
}
