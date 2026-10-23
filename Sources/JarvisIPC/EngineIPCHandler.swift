import Foundation
import JarvisCore

/// Connects the socket server to the Action Engine. This is the single entry point other local programs use.
public struct EngineIPCHandler: IPCRequestHandling {
    public static let protocolVersion = 1

    private let engine: ActionEngine
    private let appVersion: String
    private let statusProvider: @Sendable () async -> JSONValue

    /// - Parameter statusProvider: returns the integrations' availability and permission state for `status` requests.
    public init(engine: ActionEngine, appVersion: String = "1.0", statusProvider: @escaping @Sendable () async -> JSONValue = { .null }) {
        self.engine = engine
        self.appVersion = appVersion
        self.statusProvider = statusProvider
    }

    public func handle(_ request: IPCRequest, connectionID: String) async -> IPCResponse {
        let id = request.id
        let session = request.session ?? connectionID
        let language = Language(hint: request.language)

        switch request.type {
        case .ping:
            return IPCResponse(id: id, success: true, status: "ok", message: "pong", data: ["app": "Jarvis Apple Integrations", "version": .string(appVersion), "protocol": .int(Self.protocolVersion)])

        case .tools:
            return IPCResponse(id: id, success: true, status: "ok", message: "Available tools", data: engine.registry.schemaDescription(includeUnsupported: true))

        case .status:
            return IPCResponse(id: id, success: true, status: "ok", message: "Integration status", data: await statusProvider())

        case .command:
            guard let text = request.command?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                return .failure("invalid_request", "A command request needs a non-empty “command”.", id: id)
            }
            let response = await engine.process(CommandRequest(text: text, language: language, source: .ipc, session: session, allowDuplicate: request.allowDuplicate ?? false))
            return IPCResponse(engine: response, id: id)

        case .tool:
            guard let name = request.tool, !name.isEmpty else {
                return .failure("invalid_request", "A tool request needs a “tool” name.", id: id)
            }
            let call = ToolCall(tool: ToolName(name), arguments: request.arguments ?? [:])
            let response = await engine.execute(call, language: language, source: .ipc, session: session, allowDuplicate: request.allowDuplicate ?? false)
            return IPCResponse(engine: response, id: id)

        case .resolve:
            guard let token = request.token, !token.isEmpty, let decisionName = request.decision?.lowercased() else {
                return .failure("invalid_request", "A resolve request needs a “token” and a “decision” (confirm, cancel or choose).", id: id)
            }
            let decision: PendingDecision
            switch decisionName {
            case "confirm": decision = .confirm
            case "cancel": decision = .cancel
            case "choose":
                guard let index = request.index else {
                    return .failure("invalid_request", "A choose decision needs an “index” (0-based).", id: id)
                }
                decision = .choose(index)
            default:
                return .failure("invalid_request", "Unknown decision “\(decisionName)”. Use confirm, cancel or choose.", id: id)
            }
            let response = await engine.resolve(token: token, decision: decision, language: language, source: .ipc)
            return IPCResponse(engine: response, id: id)
        }
    }
}
