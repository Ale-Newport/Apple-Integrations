import CryptoKit
import Foundation
import JarvisCore

enum MessagesScripts {
    private static func make(_ name: String, _ body: String) -> AppleScriptSource {
        AppleScriptSource(name: "messages." + name, text: ScriptPrelude.handlers + "\n" + body)
    }
    static let find = make(
        "find",
        #"""
        on run argv
        set q to item 1 of argv
        set rows to {}
        tell application "Messages"
        set candidates to participants
        set n to count of candidates
        if n > 1000 then set n to 1000
        repeat with i from 1 to n
        set p to item i of candidates
        if q is "" or (name of p contains q) or (handle of p contains q) then
        set end of rows to my joinFields({my oneLine(id of p), my oneLine(name of p), my oneLine(handle of p), my oneLine(id of account of p)})
        end if
        if count of rows >= 50 then exit repeat
        end repeat
        end tell
        return my joinRecords(rows)
        end run
        """#)
    static let chats = make(
        "chats",
        #"""
        on run argv
        set q to item 1 of argv
        set rows to {}
        tell application "Messages"
        set candidates to chats
        set n to count of candidates
        if n > 200 then set n to 200
        repeat with i from 1 to n
        set c to item i of candidates
        set handles to handle of participants of c
        set AppleScript's text item delimiters to ", "
        set recipients to handles as text
        set AppleScript's text item delimiters to ""
        if q is "" or (name of c contains q) or recipients contains q then
        set end of rows to my joinFields({my oneLine(id of c), my oneLine(name of c), my oneLine(recipients), my oneLine(id of account of c)})
        end if
        end repeat
        end tell
        return my joinRecords(rows)
        end run
        """#)
    static let recipient = make(
        "recipient",
        #"""
        on run argv
        tell application "Messages"
        set found to participants whose id is item 1 of argv
        if count of found is not 1 then error "NOT_FOUND|recipient" number 9001
        set p to item 1 of found
        return my joinFields({my oneLine(id of p), my oneLine(name of p), my oneLine(handle of p), my oneLine(id of account of p)})
        end tell
        end run
        """#)
    static let send = make(
        "send",
        #"""
        on run argv
        tell application "Messages"
        set found to participants whose id is item 1 of argv
        if count of found is not 1 then error "NOT_FOUND|recipient" number 9001
        set p to item 1 of found
        if handle of p is not item 2 of argv or id of account of p is not item 3 of argv then error "CHANGED|recipient" number 9003
        send (item 4 of argv) to p
        return "submitted"
        end tell
        end run
        """#)
    static let all = [find, chats, recipient, send]
}

/// Drafts are deliberately kept only in this Jarvis session: Messages has no public native draft API.
actor MessageDraftStore {
    struct Draft: Sendable {
        let id: String
        let recipient: [String]
        let body: String
        let created: Date
        var revision: String {
            SHA256.hash(data: Data((recipient.joined(separator: "\u{001F}") + "\u{001E}" + body).utf8)).map {
                String(format: "%02x", $0)
            }.joined()
        }
        var json: JSONValue {
            [
                "draft_id": .string(id), "recipient_id": .string(recipient[0]), "name": .string(recipient[1]),
                "handle": .string(recipient[2]), "account": .string(recipient[3]), "body": .string(body),
                "revision": .string(revision), "backend": "jarvis_session_draft",
            ]
        }
    }
    private var drafts: [String: Draft] = [:]
    func create(recipient: [String], body: String, now: Date) -> Draft {
        drafts = drafts.filter { now.timeIntervalSince($0.value.created) < 86400 }
        let draft = Draft(id: UUID().uuidString, recipient: recipient, body: body, created: now)
        if drafts.count >= 50, let first = drafts.min(by: { $0.value.created < $1.value.created }) {
            drafts[first.key] = nil
        }
        drafts[draft.id] = draft
        return draft
    }
    func get(_ id: String, now: Date) -> Draft? {
        guard let draft = drafts[id], now.timeIntervalSince(draft.created) < 86400 else { return nil }
        return draft
    }
    // Consume before submission: a timeout must never silently cause a repeated message.
    func take(_ id: String, revision: String) -> Draft? {
        guard let draft = drafts[id], draft.revision == revision else { return nil }
        drafts[id] = nil
        return draft
    }
}

public struct MessagesIntegration: AppIntegration {
    public let id: IntegrationID = "messages"
    public let displayName = LocalizedText(en: "Messages", es: "Mensajes")
    public let summary = LocalizedText(
        en:
            "Find actual recipients/conversations, prepare session drafts and submit only after confirmation. Message history is not exposed by the public scripting API.",
        es:
            "Busca destinatarios y conversaciones reales, prepara borradores de sesión y envía tras confirmar. La API pública no expone el historial de mensajes."
    )
    public let symbolName = "message"
    private let bridge: AutomationBridge
    private let drafts = MessageDraftStore()
    public init() { bridge = AutomationBridge(app: "Messages", bundleID: "com.apple.MobileSMS") }
    init(scripts: any AppleScriptExecuting, access: any AutomationAccess) {
        bridge = AutomationBridge(app: "Messages", bundleID: "com.apple.MobileSMS", scripts: scripts, access: access)
    }
    public var permissionRequirements: [PermissionRequirement] { [bridge.requirement] }
    public var tools: [ToolDescriptor] {
        [
            ToolDescriptor(
                name: "messages.find", integration: id, title: "Find message recipients",
                summary:
                    "Finds actual Messages participants by name or handle. Use stable IDs and never guess recipients.",
                parameters: [.string("query", "Name or exact handle fragment.", required: true, maxLength: 200)],
                safety: .readOnly),
            ToolDescriptor(
                name: "messages.conversations", integration: id, title: "Find conversations",
                summary:
                    "Reads conversation titles, participant handles and stable chat IDs. Public AppleScript provides no message history.",
                parameters: [.string("query", "Title/participant fragment.", maxLength: 200)], safety: .readOnly),
            ToolDescriptor(
                name: "messages.draft", integration: id, title: "Prepare message",
                summary:
                    "Creates a Jarvis session draft for a real recipient ID. This is not a native Messages draft and is discarded on quit or after 24 hours. Does not send.",
                parameters: [
                    .string(
                        "recipient_id", "Exact participant ID returned by messages.find.", required: true,
                        maxLength: 500), .string("body", "Exact message body.", required: true, maxLength: 10000),
                ], safety: .modifying, deduplicate: true),
            ToolDescriptor(
                name: "messages.send", integration: id, title: "Send reviewed message",
                summary:
                    "Requires confirmation showing the actual handle, account and entire body. Rechecks the participant immediately before submission. Success means accepted by Messages, not delivery. Consumes the draft even if submission is uncertain.",
                parameters: [
                    .string("draft_id", "Jarvis draft ID.", required: true, maxLength: 100),
                    .string("revision", "Confirmation revision.", maxLength: 100),
                ], safety: .modifying, deduplicate: true, requiresConfirmation: true),
        ]
    }
    public func status() async -> IntegrationStatus { bridge.status() }
    public func authorization(for tool: ToolDescriptor) async -> AuthorizationState { bridge.authorization() }
    public func requestAuthorization(for tool: ToolDescriptor) async -> AuthorizationState { await bridge.request() }
    public func execute(_ call: ValidatedToolCall, context: ExecutionContext) async throws -> ToolOutcome {
        let name = call.descriptor.name.rawValue
        if name == "messages.find" || name == "messages.conversations" {
            let rows = ScriptRecords.parse(
                try await bridge.run(
                    name == "messages.find" ? MessagesScripts.find : MessagesScripts.chats, [call.string("query") ?? ""]
                ))
            let values: [JSONValue] = rows.filter { $0.count >= 4 }.map {
                ["id": .string($0[0]), "name": .string($0[1]), "handles": .string($0[2]), "account": .string($0[3])]
            }
            return .done(
                ToolOutput(
                    message: context.language.pick(
                        "Found \(values.count) Messages matches.", "Encontré \(values.count) coincidencias en Mensajes."
                    ), data: ["results": .array(values), "history_available": false], verification: .notApplicable))
        }
        if name == "messages.draft" {
            let fields =
                ScriptRecords.parse(
                    try await bridge.run(MessagesScripts.recipient, [call.string("recipient_id") ?? ""])
                ).first ?? []
            guard fields.count == 4, !fields[2].isEmpty else {
                throw integrationFailure(
                    "recipient_unverified", "Messages did not return a unique recipient handle.",
                    "Mensajes no devolvió un destinatario único verificable.")
            }
            let draft = await drafts.create(recipient: fields, body: call.string("body") ?? "", now: context.now)
            return .done(
                ToolOutput(
                    message: context.language.pick(
                        "Jarvis draft prepared for \(fields[1]) (\(fields[2])). Nothing sent.",
                        "Borrador de Jarvis preparado para \(fields[1]) (\(fields[2])). No se ha enviado."),
                    data: draft.json, verification: .verified("Draft stored in this Jarvis session.")))
        }
        guard let draft = await drafts.get(call.string("draft_id") ?? "", now: context.now) else {
            throw integrationFailure(
                "draft_missing",
                "The message draft expired or was already submitted. Prepare a new draft after checking Messages.",
                "El borrador caducó o ya se intentó enviar. Comprueba Mensajes antes de preparar otro.")
        }
        if !context.isConfirmed || call.string("revision") != draft.revision {
            return .confirm(
                ConfirmationRequest(
                    prompt: context.language.pick("Send to", "Enviar a")
                        + " \(draft.recipient[1]) · \(draft.recipient[2])\nAccount: \(draft.recipient[3])\n\n\(draft.body)",
                    call: call.call.adding(["revision": .string(draft.revision)]), destructive: false))
        }
        guard await drafts.take(draft.id, revision: draft.revision) != nil else {
            throw integrationFailure(
                "draft_consumed", "Draft already submitted.", "Ya se intentó enviar este borrador.")
        }
        _ = try await bridge.run(
            MessagesScripts.send, [draft.recipient[0], draft.recipient[2], draft.recipient[3], draft.body])
        return .done(
            ToolOutput(
                message: context.language.pick(
                    "Submitted to Messages. Delivery is unverified.",
                    "Enviado a Mensajes para su tramitación. Entrega sin verificar."),
                data: ["recipient": .string(draft.recipient[2]), "delivery_verified": false],
                verification: .unverified("Messages accepted the request; no delivery receipt API is available.")))
    }
}
