import Foundation
import JarvisCore
@testable import JarvisIntegrations

/// Scripted AppleScript executor: returns canned output per script name and records every call.
final class FakeScripts: AppleScriptExecuting, @unchecked Sendable {
    struct Call: Equatable {
        var name: String
        var arguments: [String]
    }

    typealias Responder = @Sendable (_ arguments: [String], _ callIndex: Int) throws -> String

    private let lock = NSLock()
    private var responders: [String: Responder] = [:]
    private var _calls: [Call] = []
    private var counts: [String: Int] = [:]

    func on(_ script: AppleScriptSource, _ responder: @escaping Responder) {
        lock.withLock { responders[script.name] = responder }
    }

    func on(_ script: AppleScriptSource, returns output: String) {
        on(script) { _, _ in output }
    }

    func on(_ script: AppleScriptSource, failsWith failure: AppleScriptFailure) {
        on(script) { _, _ in throw failure }
    }

    var calls: [Call] { lock.withLock { _calls } }

    func calls(to script: AppleScriptSource) -> [Call] { calls.filter { $0.name == script.name } }

    func run(_ script: AppleScriptSource, arguments: [String], timeout: TimeInterval) async throws -> String {
        let (responder, index): (Responder?, Int) = lock.withLock {
            _calls.append(Call(name: script.name, arguments: arguments))
            let index = counts[script.name, default: 0]
            counts[script.name] = index + 1
            return (responders[script.name], index)
        }
        guard let responder else { throw AppleScriptFailure(kind: .scriptError, code: nil, message: "No fake response for \(script.name)") }
        return try responder(arguments, index)
    }
}

struct FakeAutomation: AutomationAccess {
    var state: AutomationPermission.Status = .granted
    var afterRequest: AutomationPermission.Status = .granted
    var running = true
    var installed = true

    func status() -> AutomationPermission.Status { state }
    func request() async -> AutomationPermission.Status { afterRequest }
    var isRunning: Bool { running }
    var isInstalled: Bool { installed }
}

enum Rec {
    static let us = String(ScriptRecords.fieldSeparator)
    static let rs = String(ScriptRecords.recordSeparator)

    static func fields(_ values: String...) -> String { values.joined(separator: us) }
    static func records(_ rows: [String]) -> String { rows.joined(separator: rs) }
}

func executionContext(language: Language = .en, confirmed: Bool = false, settings: JarvisSettings = JarvisSettings(), now: Date = Date(timeIntervalSince1970: 1_792_238_880), zone: TimeZone = TimeZone(identifier: "Europe/London")!) -> ExecutionContext {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    calendar.firstWeekday = 2
    return ExecutionContext(language: language, now: now, calendar: calendar, settings: settings, source: .test, isConfirmed: confirmed)
}

extension ToolRegistry {
    /// Validates and runs `tool` on a single integration the way the engine would.
    func run(_ tool: ToolName, _ arguments: JSONObject, context: ExecutionContext = executionContext()) async throws -> ToolOutcome {
        let validated = try validate(ToolCall(tool: tool, arguments: arguments))
        guard let integration = integration(for: tool) else { throw JarvisError.failed("none", en: "none", es: "ninguna") }
        return try await integration.execute(validated, context: context)
    }
}

extension ToolOutcome {
    var output: ToolOutput? { if case .done(let output) = self { return output } else { return nil } }
    var clarification: Clarification? { if case .clarify(let value) = self { return value } else { return nil } }
    var confirmation: ConfirmationRequest? { if case .confirm(let value) = self { return value } else { return nil } }
}
