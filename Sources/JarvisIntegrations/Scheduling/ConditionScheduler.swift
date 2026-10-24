import Darwin
import Foundation
import JarvisCore
import ServiceManagement
import UserNotifications

public enum ConditionService {
    public static let plistName = "com.alejandronewport.JarvisAppleIntegrations.conditions.plist"
    public static let parentBundleID = "com.alejandronewport.JarvisAppleIntegrations"
    public static var enabled: Bool { SMAppService.agent(plistName: plistName).status == .enabled }
    public static var jobsURL: URL {
        JarvisPaths.applicationSupportDirectory().appendingPathComponent("conditions.json")
    }
    public static var statusURL: URL {
        JarvisPaths.applicationSupportDirectory().appendingPathComponent("condition-agent-status.json")
    }
}

public protocol ConditionNotifying: Sendable {
    func allowed(request: Bool) async -> Bool
    func contains(_ id: String) async -> Bool
    func schedule(id: String, title: String, body: String) async throws
    func remove(_ id: String) async
}
public struct SystemConditionNotifications: ConditionNotifying {
    public init() {}
    public func allowed(request: Bool) async -> Bool {
        let center = UNUserNotificationCenter.current()
        let state = await center.notificationSettings().authorizationStatus
        if state == .authorized || state == .provisional { return true }
        return request && state == .notDetermined
            ? (try? await center.requestAuthorization(options: [.alert, .sound])) == true : false
    }
    public func contains(_ id: String) async -> Bool {
        let center = UNUserNotificationCenter.current()
        if await center.pendingNotificationRequests().contains(where: { $0.identifier == id }) { return true }
        return await center.deliveredNotifications().contains { $0.request.identifier == id }
    }
    public func schedule(id: String, title: String, body: String) async throws {
        let content = UNMutableNotificationContent()
        content.title = "Jarvis · " + title
        content.body = body
        content.sound = .default
        try await UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: id, content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)))
        guard await contains(id) else { throw CocoaError(.fileWriteUnknown) }
    }
    public func remove(_ id: String) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }
}

public struct WeatherConditionJob: Codable, Sendable, Identifiable {
    public let id: String
    public let location: String
    public let placeID: Int
    public let forecastDate: String
    public let threshold: Double
    public let title: String
    public let checkAt: Date
    public let expires: Date
    public var status: String = "pending"
    public var lastCheck: Date?
    public var nextAttempt: Date?
    public var rainProbability: Double?
    public var error: String?
    /// nil preserves the original at-least behavior of saved jobs.
    public var comparison: String?
    var notificationID: String { "jarvis.condition." + id }
    func json(zone: TimeZone) -> JSONValue {
        [
            "id": .string(id), "location": .string(location), "place_id": .int(placeID),
            "forecast_date": .string(forecastDate), "threshold_percent": .double(threshold), "title": .string(title),
            "check_at": .string(ISODates.string(from: checkAt, timeZone: zone)),
            "expires_at": .string(ISODates.string(from: expires, timeZone: zone)), "status": .string(status),
            "last_check": lastCheck.map { .string(ISODates.string(from: $0, timeZone: zone)) } ?? .null,
            "rain_probability_percent": rainProbability.map(JSONValue.double) ?? .null,
            "last_error": error.map(JSONValue.string) ?? .null, "backend": "jarvis_condition_agent_notifications",
            "comparison": .string(comparison ?? "at_least"),
        ]
    }
}

/// One-shot future evaluations, not an LLM polling loop. launchd runs the signed agent every 15 minutes.
/// A private flock file coordinates the foreground app and background process; no lock crosses an await.
public actor ConditionJobStore {
    private let url: URL
    private let weather: WeatherIntegration
    private let notifier: any ConditionNotifying
    public init(
        url: URL = ConditionService.jobsURL, weather: WeatherIntegration = WeatherIntegration(),
        notifier: any ConditionNotifying = SystemConditionNotifications()
    ) {
        self.url = url
        self.weather = weather
        self.notifier = notifier
    }
    private func access<T>(_ body: (inout [WeatherConditionJob]) throws -> T) throws -> T {
        guard JarvisPaths.ensurePrivateDirectory(url.deletingLastPathComponent()) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let lockURL = url.appendingPathExtension("lock")
        let fd = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }
        defer {
            flock(fd, LOCK_UN)
            close(fd)
        }
        guard flock(fd, LOCK_EX) == 0 else { throw CocoaError(.fileReadUnknown) }
        var values: [WeatherConditionJob]
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            guard data.count < 1_000_000 else { throw CocoaError(.fileReadTooLarge) }
            values = try JSONDecoder().decode([WeatherConditionJob].self, from: data)
        } else {
            values = []
        }
        let result = try body(&values)
        try JSONEncoder().encode(values).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return result
    }
    public func all() throws -> [WeatherConditionJob] { try access { $0 } }
    func insert(_ job: WeatherConditionJob) throws {
        try access { jobs in
            guard jobs.filter({ ["pending", "checking", "delivery_pending"].contains($0.status) }).count < 20 else {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            jobs.insert(job, at: 0)
            jobs = Array(jobs.prefix(100))
        }
    }
    func cancel(_ id: String) async throws {
        let notificationID = try access { jobs -> String in
            guard let index = jobs.firstIndex(where: { $0.id == id }) else { throw CocoaError(.fileNoSuchFile) }
            jobs[index].status = "cancelled"
            return jobs[index].notificationID
        }
        await notifier.remove(notificationID)
    }
    public func evaluate(now: Date = Date(), isEnabled: @Sendable () -> Bool = { true }) async {
        guard isEnabled() else { return }
        guard await notifier.allowed(request: false) else {
            try? access { jobs in
                for index in jobs.indices
                where ["pending", "checking", "delivery_pending"].contains(jobs[index].status) {
                    jobs[index].error = "Notifications are disabled; authorize the condition agent's notifications."
                    if jobs[index].expires < now { jobs[index].status = "expired" }
                }
            }
            return
        }
        let claimed: [WeatherConditionJob]
        do {
            claimed = try access { jobs in
                var claimed: [WeatherConditionJob] = []
                for index in jobs.indices
                where ["pending", "checking", "delivery_pending"].contains(jobs[index].status) {
                    if jobs[index].expires < now {
                        jobs[index].status = "expired"
                        continue
                    }
                    if jobs[index].checkAt <= now && (jobs[index].nextAttempt ?? .distantPast) <= now {
                        jobs[index].status = "checking"
                        jobs[index].lastCheck = now
                        jobs[index].nextAttempt = now.addingTimeInterval(180)
                        claimed.append(jobs[index])
                    }
                    if claimed.count == 4 { break }
                }
                return claimed
            }
        } catch { return }
        for job in claimed {
            do {
                guard isEnabled() else { return }
                if await notifier.contains(job.notificationID) {
                    try update(job.id) { $0.status = "notified" }
                    continue
                }
                let registry = ToolRegistry(integrations: [weather])
                let call = try registry.validate(
                    ToolCall(
                        tool: "weather.forecast",
                        arguments: [
                            "location": .string(job.location), "place_id": .int(job.placeID),
                            "date": .string(job.forecastDate), "include_hourly": false,
                        ]))
                let context = ExecutionContext(
                    language: .en, now: now, calendar: .current, settings: JarvisSettings(), source: .app,
                    isConfirmed: false)
                guard case .done(let output) = try await weather.execute(call, context: context),
                    let probability = output.data?["days"]?[0]?["rain_probability_percent"]?.doubleValue
                else { throw URLError(.cannotParseResponse) }
                let notify = try access { jobs -> Bool in
                    guard let index = jobs.firstIndex(where: { $0.id == job.id }), jobs[index].status == "checking"
                    else { return false }
                    jobs[index].rainProbability = probability
                    jobs[index].error = nil
                    let matches = job.comparison == "above" ? probability > job.threshold : probability >= job.threshold
                    jobs[index].status = matches ? "delivery_pending" : "condition_not_met"
                    return matches
                }
                if notify {
                    guard isEnabled(), await notifier.allowed(request: false) else { throw CocoaError(.userCancelled) }
                    try await notifier.schedule(
                        id: job.notificationID, title: job.title,
                        body: "\(job.location) · \(job.forecastDate) · Rain / Lluvia \(probability)% · Open-Meteo")
                    let cancelled = try access { jobs -> Bool in
                        guard let index = jobs.firstIndex(where: { $0.id == job.id }),
                            jobs[index].status == "delivery_pending"
                        else { return true }
                        jobs[index].status = "notified"
                        return false
                    }
                    if cancelled || !isEnabled() { await notifier.remove(job.notificationID) }
                }
            } catch {
                try? update(job.id) { value in
                    if value.status != "cancelled" {
                        value.status = "pending"
                        value.nextAttempt = now.addingTimeInterval(900)
                        value.error = "Weather or notification request failed; retry after 15 minutes until expiry."
                    }
                }
            }
        }
    }
    private func update(_ id: String, _ change: (inout WeatherConditionJob) -> Void) throws {
        try access { jobs in
            guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].status != "cancelled" else { return }
            change(&jobs[index])
        }
    }
}

public struct ConditionsIntegration: AppIntegration {
    public let id: IntegrationID = "conditions"
    public let displayName = LocalizedText(en: "Future conditions", es: "Condiciones futuras")
    public let summary = LocalizedText(
        en:
            "Persisted future weather checks through an optional signed launch agent. Conditions create Jarvis notifications, not Clock alarms or Reminders items.",
        es:
            "Comprobaciones futuras del tiempo mediante un agente opcional firmado. Generan notificaciones de Jarvis, no alarmas de Reloj ni elementos de Recordatorios."
    )
    public let symbolName = "calendar.badge.clock"
    public let permissionRequirements: [PermissionRequirement] = []
    private let store: ConditionJobStore
    private let weather: WeatherIntegration
    private let enabled: @Sendable () -> Bool
    private let notificationsAuthorized: @Sendable () -> Bool
    public init(
        store: ConditionJobStore = ConditionJobStore(), weather: WeatherIntegration = WeatherIntegration(),
        enabled: @escaping @Sendable () -> Bool = { ConditionService.enabled },
        notificationsAuthorized: @escaping @Sendable () -> Bool = {
            (try? JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: ConditionService.statusURL)))?[
                "notifications_authorized"]?.boolValue == true
        }
    ) {
        self.store = store
        self.weather = weather
        self.enabled = enabled
        self.notificationsAuthorized = notificationsAuthorized
    }
    public var tools: [ToolDescriptor] {
        [
            ToolDescriptor(
                name: "conditions.schedule_rain", integration: id, title: "Schedule a future rain check",
                summary:
                    "Saves a genuine one-shot FUTURE weather check. Requires the optional background agent enabled by the user, agent notification authorization and explicit confirmation. Checks may run up to 15 minutes late; sleep/offline can delay them, and an expired job never fires. If forecast rain probability meets the threshold, schedules a Jarvis notification. Does not create a native Reminders item or continuously monitor conditions.",
                parameters: [
                    .string("location", "City name.", required: true, maxLength: 200),
                    .integer("place_id", "Actual place ID from weather.forecast.", required: true, min: 1),
                    .date("forecast_date", "Forecast day to evaluate.", required: true),
                    .dateTime("check_at", "Future check time, up to seven days ahead.", required: true),
                    .number("threshold_percent", "Rain probability threshold.", min: 0, max: 100, default: 50),
                    .choice(
                        "comparison", ["above", "at_least"],
                        "Strictly greater than, or greater than/equal to, the threshold.", default: "above"),
                    .string("title", "Notification text.", required: true, maxLength: 500),
                    .integer(
                        "expiry_minutes", "Expiry after check time; delayed expired jobs do not notify.", min: 15,
                        max: 1440, default: 360),
                ], safety: .modifying, timeout: 45, deduplicate: true, requiresConfirmation: true),
            ToolDescriptor(
                name: "conditions.list", integration: id, title: "List future conditions",
                summary:
                    "Reads persisted jobs and real status/last check/error. Does not imply that a disabled background agent is monitoring.",
                safety: .readOnly),
            ToolDescriptor(
                name: "conditions.cancel", integration: id, title: "Cancel future condition",
                summary: "Cancels one actual saved condition and removes its pending Jarvis notification.",
                parameters: [.string("id", "Actual saved job ID.", required: true, maxLength: 100)], safety: .modifying),
        ]
    }
    public func status() async -> IntegrationStatus {
        IntegrationStatus(
            state: enabled() ? .ready : .needsSetup,
            detail: LocalizedText(
                en: "Enable the optional condition agent in Settings > Integrations and authorize its notifications.",
                es: "Activa el agente opcional en Ajustes > Integraciones y autoriza sus notificaciones."))
    }
    public func authorization(for tool: ToolDescriptor) async -> AuthorizationState { .authorized }
    public func requestAuthorization(for tool: ToolDescriptor) async -> AuthorizationState { .authorized }
    public func execute(_ call: ValidatedToolCall, context: ExecutionContext) async throws -> ToolOutcome {
        if call.descriptor.name.rawValue == "conditions.list" {
            return .done(
                ToolOutput(
                    message: context.language.pick("Saved conditions retrieved.", "Condiciones guardadas consultadas."),
                    data: [
                        "jobs": .array(try await store.all().map { $0.json(zone: context.timeZone) }),
                        "background_agent_enabled": .bool(enabled()),
                    ], verification: .notApplicable))
        }
        if call.descriptor.name.rawValue == "conditions.cancel" {
            try await store.cancel(call.string("id") ?? "")
            return .done(
                ToolOutput(
                    message: context.language.pick("Condition cancelled.", "Condición cancelada."),
                    verification: .verified("Persisted cancelled state and removed pending notification.")))
        }
        guard context.settings.capabilities.backgroundConditionsEnabled, enabled() else {
            throw integrationFailure(
                "condition_agent_disabled",
                "Enable the signed condition agent in Settings > Integrations first. No future monitoring is active.",
                "Activa primero el agente firmado en Ajustes > Integraciones. No hay seguimiento futuro activo.")
        }
        guard notificationsAuthorized() else {
            throw integrationFailure(
                "condition_notifications",
                "Authorize notifications for Jarvis Condition Agent from Settings > Integrations first.",
                "Autoriza las notificaciones de Jarvis Condition Agent desde Ajustes > Integraciones primero.")
        }
        guard let at = call.string("check_at").flatMap({ ISODates.date(from: $0, timeZone: context.timeZone) }),
            at > context.now, at.timeIntervalSince(context.now) <= 7 * 86400
        else { throw Calculator.Failure.invalidExpression }
        let registry = ToolRegistry(integrations: [weather])
        let forecast = try registry.validate(
            ToolCall(
                tool: "weather.forecast",
                arguments: [
                    "location": call.arguments["location"]!, "place_id": call.arguments["place_id"]!,
                    "date": call.arguments["forecast_date"]!, "include_hourly": false,
                ]))
        guard case .done = try await weather.execute(forecast, context: context) else {
            throw integrationFailure(
                "condition_location", "Resolve an actual city with weather.forecast before scheduling.",
                "Resuelve una ciudad real con weather.forecast antes de programar.")
        }
        if !context.isConfirmed {
            return .confirm(
                ConfirmationRequest(
                    prompt: context.language.pick(
                        "Save this future weather check?", "¿Guardar esta comprobación futura del tiempo?")
                        + "\n\(call.string("location") ?? "") · \(call.string("forecast_date") ?? "")\nRain \(call.string("comparison") == "above" ? ">" : "≥") \(call.arguments["threshold_percent"]?.doubleValue ?? 50)%\n\(call.string("check_at") ?? "")\n\(call.string("title") ?? "")\nJarvis notification; may be delayed by sleep/offline.",
                    call: call.call, destructive: false))
        }
        var job = WeatherConditionJob(
            id: UUID().uuidString, location: call.string("location")!, placeID: call.int("place_id")!,
            forecastDate: call.string("forecast_date")!,
            threshold: call.arguments["threshold_percent"]?.doubleValue ?? 50, title: call.string("title")!,
            checkAt: at, expires: at.addingTimeInterval(Double(call.int("expiry_minutes") ?? 360) * 60))
        job.comparison = call.string("comparison") ?? "above"
        try await store.insert(job)
        return .done(
            ToolOutput(
                message: context.language.pick(
                    "Future rain check saved for the background agent.",
                    "Comprobación futura de lluvia guardada para el agente."), data: job.json(zone: context.timeZone),
                verification: .verified(
                    "Saved a typed condition job; background service currently reports enabled. Future execution is not yet completed."
                )))
    }
}
