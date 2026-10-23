import Foundation
import JarvisCore
import UserNotifications

public protocol TimerNotifying: Sendable {
    func authorized(request: Bool) async -> Bool
    func schedule(id: String, title: String, seconds: TimeInterval) async throws
    func remove(id: String) async
    func contains(id: String) async -> Bool
}

public struct SystemTimerNotifications: TimerNotifying {
    public init() {}
    public func authorized(request: Bool) async -> Bool {
        let center = UNUserNotificationCenter.current()
        let state = await center.notificationSettings().authorizationStatus
        if state == .authorized || state == .provisional { return true }
        guard request, state == .notDetermined else { return false }
        return (try? await center.requestAuthorization(options: [.alert, .sound])) == true
    }
    public func schedule(id: String, title: String, seconds: TimeInterval) async throws {
        let content = UNMutableNotificationContent()
        content.title = "Jarvis · " + title
        content.body = "Timer finished · Temporizador terminado"
        content.sound = .default
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, seconds), repeats: false)))
    }
    public func remove(id: String) async { UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id]) }
    public func contains(id: String) async -> Bool { await UNUserNotificationCenter.current().pendingNotificationRequests().contains { $0.identifier == id } }
}

struct ManagedTimer: Codable, Sendable {
    var id: String
    var label: String
    var end: Date?
    var remaining: TimeInterval
    func json(now: Date) -> JSONValue {
        .object(["id": .string(id), "label": .string(label), "remaining_seconds": .int(Int(max(0, end?.timeIntervalSince(now) ?? remaining).rounded(.up))), "paused": .bool(end == nil), "backend": "jarvis_notifications"])
    }
}

/// No ticking loop: deadlines are persisted and macOS delivers notifications even when Jarvis is closed.
public actor ManagedTimerStore {
    private let url: URL
    private let notifier: any TimerNotifying
    private var timers: [ManagedTimer]?
    private var tail: Task<ToolOutcome, any Error>?
    public init(url: URL = JarvisPaths.applicationSupportDirectory().appendingPathComponent("timers.json"), notifier: any TimerNotifying = SystemTimerNotifications()) { self.url = url; self.notifier = notifier }

    private func load() throws -> [ManagedTimer] {
        if let timers { return timers }
        guard FileManager.default.fileExists(atPath: url.path) else { timers = []; return [] }
        let value = try JSONDecoder().decode([ManagedTimer].self, from: Data(contentsOf: url))
        timers = value
        return value
    }
    private func save(_ value: [ManagedTimer]) throws {
        guard JarvisPaths.ensurePrivateDirectory(url.deletingLastPathComponent()) else { throw CocoaError(.fileWriteNoPermission) }
        try JSONEncoder().encode(value).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        timers = value
    }

    func run(_ call: ValidatedToolCall, now: Date, language: Language) async throws -> ToolOutcome {
        let previous = tail
        let task = Task {
            _ = try? await previous?.value
            try Task.checkCancellation()
            return try await self.perform(call, now: now, language: language)
        }
        tail = task
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func perform(_ call: ValidatedToolCall, now: Date, language: Language) async throws -> ToolOutcome {
        var values = try load()
        if call.descriptor.name.rawValue == "jarvis_timers.list" {
            let rows = values.map { $0.json(now: now) }
            let lines = rows.map { "\($0["label"]?.stringValue ?? "Timer"): \($0["remaining_seconds"]?.intValue ?? 0) s" + ($0["paused"]?.boolValue == true ? " · paused / en pausa" : "") }
            return .done(ToolOutput(message: language.pick("Jarvis timers", "Temporizadores de Jarvis") + ":\n" + lines.joined(separator: "\n"), data: ["timers": .array(rows), "backend": "jarvis_notifications"], verification: .notApplicable))
        }
        var timer: ManagedTimer
        var original: ManagedTimer?
        let name = call.descriptor.name.rawValue
        if name == "jarvis_timers.create" {
            guard values.count < 32 else { throw JarvisError.failed("timer_limit", en: "Remove a timer before adding another (limit: 32).", es: "Elimina un temporizador antes de añadir otro (límite: 32).") }
            let seconds = TimeInterval(call.int("duration_seconds") ?? 0)
            timer = ManagedTimer(id: "jarvis.timer." + UUID().uuidString, label: call.string("label") ?? "Timer", end: now.addingTimeInterval(seconds), remaining: seconds)
        } else {
            let selected = values.filter { call.string("id") != nil ? $0.id == call.string("id") : TextFolding.fold($0.label) == TextFolding.fold(call.string("label") ?? "") }
            guard let found = selected.first else { throw JarvisError.notFound("timer_not_found", en: "No matching Jarvis timer.", es: "No se encontró ese temporizador de Jarvis.") }
            guard selected.count == 1 else {
                return .clarify(Clarification(question: language.pick("Which Jarvis timer?", "¿Qué temporizador de Jarvis?"), options: selected.map { ClarificationOption(label: $0.label, detail: $0.id, call: call.call.adding(["id": .string($0.id)])) }))
            }
            timer = found
            original = found
            switch name {
            case "jarvis_timers.pause": timer.remaining = max(0, timer.end?.timeIntervalSince(now) ?? timer.remaining); timer.end = nil
            case "jarvis_timers.resume":
                guard timer.end == nil, timer.remaining > 0 else { throw JarvisError.failed("timer_state", en: "The timer is running or already finished.", es: "El temporizador está en marcha o ya terminó.") }
                timer.end = now.addingTimeInterval(timer.remaining)
            case "jarvis_timers.extend":
                timer.remaining = max(0, timer.end?.timeIntervalSince(now) ?? timer.remaining) + TimeInterval(call.int("seconds") ?? 0)
                guard timer.remaining <= 604800 else { throw JarvisError.failed("timer_limit", en: "A Jarvis timer can span at most seven days.", es: "Un temporizador de Jarvis puede durar como máximo siete días.") }
                if timer.end != nil { timer.end = now.addingTimeInterval(timer.remaining) }
            case "jarvis_timers.cancel": break
            default: throw Calculator.Failure.invalidExpression
            }
        }
        // Schedule before saving; a failed scheduler must never produce a success-looking timer.
        if let end = timer.end, name != "jarvis_timers.cancel" {
            try await notifier.schedule(id: timer.id, title: timer.label, seconds: end.timeIntervalSince(now))
            guard await notifier.contains(id: timer.id) else { throw JarvisError.verificationFailed(LocalizedText(en: "macOS did not retain the timer notification.", es: "macOS no conservó la notificación del temporizador.")) }
        } else { await notifier.remove(id: timer.id) }
        values.removeAll { $0.id == timer.id }
        if name != "jarvis_timers.cancel" { values.append(timer) }
        do { try save(values) }
        catch {
            await notifier.remove(id: timer.id)
            if let original, let end = original.end, end > now { try? await notifier.schedule(id: original.id, title: original.label, seconds: end.timeIntervalSince(now)) }
            throw error
        }
        return .done(ToolOutput(message: language.pick("Jarvis timer updated: \(timer.label). This is a Jarvis notification, not a Clock alarm.", "Temporizador de Jarvis actualizado: \(timer.label). Es una notificación de Jarvis, no una alarma de Reloj."), data: timer.json(now: now), verification: .verified(language.pick("Deadline saved; macOS notification checked.", "Plazo guardado; notificación de macOS comprobada."))))
    }
}

public struct ManagedTimersIntegration: AppIntegration {
    public let id: IntegrationID = "jarvis_timers"
    public let displayName = LocalizedText(en: "Jarvis timers", es: "Temporizadores de Jarvis")
    public let summary = LocalizedText(en: "Multiple persistent timers delivered as Jarvis notifications; separate from native Clock alarms.", es: "Varios temporizadores persistentes con notificaciones de Jarvis; separados de las alarmas nativas de Reloj.")
    public let symbolName = "timer"
    private let store: ManagedTimerStore
    private let notifier: any TimerNotifying
    public init(store: ManagedTimerStore = ManagedTimerStore(), notifier: any TimerNotifying = SystemTimerNotifications()) { self.store = store; self.notifier = notifier }
    private let requirement = PermissionRequirement(id: "jarvis.notifications", title: LocalizedText(en: "Jarvis notifications", es: "Notificaciones de Jarvis"), rationale: LocalizedText(en: "Timers need permission to notify when finished.", es: "Los temporizadores necesitan permiso para avisar al terminar."), settingsURL: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
    public var permissionRequirements: [PermissionRequirement] { [requirement] }
    public var tools: [ToolDescriptor] {
        let selector: [ToolParameter] = [.string("id", "Stable Jarvis timer ID.", maxLength: 100), .string("label", "Exact timer label; duplicate labels require clarification.", maxLength: 200)]
        var tools = [ToolDescriptor(name: "jarvis_timers.create", integration: id, title: "Start Jarvis timer", summary: "Creates a Jarvis notification timer (not native Clock). Persists through app restarts; macOS may silence notifications under Focus or while asleep.", parameters: [.integer("duration_seconds", "Duration in seconds.", required: true, min: 1, max: 604800), .string("label", "Timer label.", maxLength: 200)], safety: .modifying, deduplicate: true),
            ToolDescriptor(name: "jarvis_timers.list", integration: id, title: "List Jarvis timers", summary: "Lists active, paused and elapsed Jarvis timers and remaining seconds.", safety: .readOnly)]
        for action in ["pause", "resume", "cancel", "extend"] {
            let parameters = selector + (action == "extend" ? [.integer("seconds", "Seconds to add.", required: true, min: 1, max: 604800)] : [])
            tools.append(ToolDescriptor(name: ToolName("jarvis_timers." + action), integration: id, title: action.capitalized + " Jarvis timer", summary: "\(action) a Jarvis timer by stable ID or exact label.", parameters: parameters, constraints: [.atLeastOne(["id", "label"])], safety: .modifying))
        }
        return tools
    }
    public func status() async -> IntegrationStatus { IntegrationStatus(state: .ready, detail: LocalizedText(en: "Notification permission is requested on first timer creation.", es: "Se pide permiso de notificaciones al crear el primer temporizador.")) }
    public func authorization(for tool: ToolDescriptor) async -> AuthorizationState {
        if tool.name.rawValue != "jarvis_timers.create" && tool.name.rawValue != "jarvis_timers.resume" && tool.name.rawValue != "jarvis_timers.extend" { return .authorized }
        return await notifier.authorized(request: false) ? .authorized : .notDetermined(requirement)
    }
    public func requestAuthorization(for tool: ToolDescriptor) async -> AuthorizationState { await notifier.authorized(request: true) ? .authorized : .denied(requirement) }
    public func execute(_ call: ValidatedToolCall, context: ExecutionContext) async throws -> ToolOutcome { try await store.run(call, now: context.now, language: context.language) }
}
