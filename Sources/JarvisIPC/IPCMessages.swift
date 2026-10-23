import Foundation
import JarvisCore

/// A request from another local program (the wider Jarvis assistant, a script, a future voice module…).
///
/// The wire format is **one JSON object per line** over a Unix domain socket:
///
/// ```json
/// {"command": "Add buy milk to my Shopping reminders list", "language": "en"}
/// ```
///
/// `type` defaults to `command`. Other types: `tool` (run a structured tool call without interpretation),
/// `resolve` (confirm / cancel / choose for a pending question), `tools` (the tool schemas), `status`, `ping`.
public struct IPCRequest: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case command, tool, resolve, tools, status, ping
    }

    public var id: String?
    public var type: Kind
    /// Natural-language command (`type == command`).
    public var command: String?
    public var language: String?
    /// Scopes "yes / cancel / 2" replies. Defaults to one session per connection.
    public var session: String?
    public var allowDuplicate: Bool?
    /// Structured call (`type == tool`).
    public var tool: String?
    public var arguments: JSONObject?
    /// Pending question (`type == resolve`).
    public var token: String?
    public var decision: String?
    public var index: Int?

    public init(
        id: String? = nil, type: Kind = .command, command: String? = nil, language: String? = nil, session: String? = nil,
        allowDuplicate: Bool? = nil, tool: String? = nil, arguments: JSONObject? = nil, token: String? = nil,
        decision: String? = nil, index: Int? = nil
    ) {
        self.id = id
        self.type = type
        self.command = command
        self.language = language
        self.session = session
        self.allowDuplicate = allowDuplicate
        self.tool = tool
        self.arguments = arguments
        self.token = token
        self.decision = decision
        self.index = index
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, command, language, session, tool, arguments, token, decision, index
        case allowDuplicate = "allow_duplicate"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        command = try c.decodeIfPresent(String.self, forKey: .command)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        session = try c.decodeIfPresent(String.self, forKey: .session)
        allowDuplicate = try c.decodeIfPresent(Bool.self, forKey: .allowDuplicate)
        tool = try c.decodeIfPresent(String.self, forKey: .tool)
        arguments = try c.decodeIfPresent(JSONObject.self, forKey: .arguments)
        token = try c.decodeIfPresent(String.self, forKey: .token)
        decision = try c.decodeIfPresent(String.self, forKey: .decision)
        index = try c.decodeIfPresent(Int.self, forKey: .index)
        if let explicit = try c.decodeIfPresent(Kind.self, forKey: .type) {
            type = explicit
        } else if tool != nil {
            type = .tool
        } else if token != nil {
            type = .resolve
        } else {
            type = .command
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(command, forKey: .command)
        try c.encodeIfPresent(language, forKey: .language)
        try c.encodeIfPresent(session, forKey: .session)
        try c.encodeIfPresent(allowDuplicate, forKey: .allowDuplicate)
        try c.encodeIfPresent(tool, forKey: .tool)
        try c.encodeIfPresent(arguments, forKey: .arguments)
        try c.encodeIfPresent(token, forKey: .token)
        try c.encodeIfPresent(decision, forKey: .decision)
        try c.encodeIfPresent(index, forKey: .index)
    }
}

/// The answer to an ``IPCRequest``. Every field is derived from real execution results — a response never claims
/// success the engine did not verify.
///
/// ```json
/// {"success": true, "status": "completed", "tool": "reminders.create", "message": "Reminder created: …",
///  "data": {"title": "Buy milk", "list": "Shopping", …}, "results": [ … ]}
/// ```
///
/// For a single-step command `tool` and `data` mirror the only result; for multi-step commands they are `null` and
/// `results` holds one entry per step.
public struct IPCResponse: Codable, Sendable, Equatable {
    public var id: String?
    public var success: Bool
    public var status: String
    public var tool: String?
    public var message: String
    public var data: JSONValue?
    public var results: [ToolResult]
    public var language: String?
    public var interpreter: String?
    public var durationMs: Int?

    public init(
        id: String? = nil, success: Bool, status: String, tool: String? = nil, message: String, data: JSONValue? = nil,
        results: [ToolResult] = [], language: String? = nil, interpreter: String? = nil, durationMs: Int? = nil
    ) {
        self.id = id
        self.success = success
        self.status = status
        self.tool = tool
        self.message = message
        self.data = data
        self.results = results
        self.language = language
        self.interpreter = interpreter
        self.durationMs = durationMs
    }

    private enum CodingKeys: String, CodingKey {
        case id, success, status, tool, message, data, results, language, interpreter
        case durationMs = "duration_ms"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        success = try c.decode(Bool.self, forKey: .success)
        status = try c.decode(String.self, forKey: .status)
        tool = try c.decodeIfPresent(String.self, forKey: .tool)
        message = try c.decode(String.self, forKey: .message)
        data = try c.decodeIfPresent(JSONValue.self, forKey: .data)
        results = try c.decodeIfPresent([ToolResult].self, forKey: .results) ?? []
        language = try c.decodeIfPresent(String.self, forKey: .language)
        interpreter = try c.decodeIfPresent(String.self, forKey: .interpreter)
        durationMs = try c.decodeIfPresent(Int.self, forKey: .durationMs)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encode(success, forKey: .success)
        try c.encode(status, forKey: .status)
        // Explicit nulls keep the shape stable for clients written in other languages.
        if let tool { try c.encode(tool, forKey: .tool) } else { try c.encodeNil(forKey: .tool) }
        try c.encode(message, forKey: .message)
        if let data { try c.encode(data, forKey: .data) } else { try c.encodeNil(forKey: .data) }
        try c.encode(results, forKey: .results)
        try c.encodeIfPresent(language, forKey: .language)
        try c.encodeIfPresent(interpreter, forKey: .interpreter)
        try c.encodeIfPresent(durationMs, forKey: .durationMs)
    }

    /// Builds the response for an engine result.
    public init(engine response: EngineResponse, id: String?) {
        let single = response.results.count == 1 ? response.results[0] : nil
        self.init(
            id: id, success: response.success, status: response.status.rawValue, tool: single?.tool.rawValue, message: response.message,
            data: single?.data, results: response.results, language: response.language.rawValue, interpreter: response.interpreter,
            durationMs: response.durationMs
        )
    }

    /// A protocol-level failure (malformed JSON, unknown request type…).
    public static func failure(_ status: String, _ message: String, id: String? = nil) -> IPCResponse {
        IPCResponse(id: id, success: false, status: status, message: message)
    }
}

/// Encoding helpers shared by the server and the client.
public enum IPCCodec {
    public static let maxLineBytes = 1_048_576

    public static func decodeRequest(_ line: Data) throws -> IPCRequest {
        try JSONDecoder().decode(IPCRequest.self, from: line)
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    public static func decodeResponse(_ line: Data) throws -> IPCResponse {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(IPCResponse.self, from: line)
    }
}

/// What the server calls for each request.
public protocol IPCRequestHandling: Sendable {
    func handle(_ request: IPCRequest, connectionID: String) async -> IPCResponse
}
