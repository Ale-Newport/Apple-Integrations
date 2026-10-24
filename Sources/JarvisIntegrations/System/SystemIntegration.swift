import AppKit
import Foundation
import IOKit.graphics
import IOKit.ps
import ImageIO
import JarvisCore
import ScreenCaptureKit
import UniformTypeIdentifiers

protocol SystemOperating: Sendable {
    func applications(runningOnly: Bool) async -> [JSONValue]
    func openApplication(bundleID: String) async throws
    func closeApplication(bundleID: String) async throws -> Bool
    func openURL(_ url: URL) async -> Bool
    func clipboard() async -> String?
    func setClipboard(_ text: String) async -> Bool
    func information() async -> JSONValue
    func screenshot() async throws -> String
    func brightness(level: Double?) async throws -> Double
    func sleepDisplay() async throws -> Bool
}

extension SystemOperating {
    func brightness(level: Double?) async throws -> Double { throw CocoaError(.featureUnsupported) }
    func sleepDisplay() async throws -> Bool { throw CocoaError(.featureUnsupported) }
}

final class NativeSystemOperations: SystemOperating, Sendable {
    @MainActor func applications(runningOnly: Bool) async -> [JSONValue] {
        if runningOnly {
            return NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap { app in
                guard let id = app.bundleIdentifier else { return nil }
                return ["id": .string(id), "name": .string(app.localizedName ?? id), "running": true]
            }
        }
        var found: [String: JSONValue] = [:]
        for path in ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"] {
            guard
                let urls = try? FileManager.default.contentsOfDirectory(
                    at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil)
            else { continue }
            for url in urls where url.pathExtension == "app" {
                guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { continue }
                let schemes = (bundle.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? [])
                    .flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
                found[id] = [
                    "id": .string(id), "name": .string(url.deletingPathExtension().lastPathComponent),
                    "url_schemes": .array(schemes.map(JSONValue.string)),
                ]
            }
        }
        return found.keys.sorted().compactMap { found[$0] }
    }
    @MainActor func openApplication(bundleID: String) async throws {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
    @MainActor func closeApplication(bundleID: String) async throws -> Bool {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard !apps.isEmpty else { return true }
        for app in apps { guard app.terminate() else { return false } }
        for _ in 0..<10 {
            if apps.allSatisfy(\.isTerminated) { return true }
            try await Task.sleep(for: .milliseconds(100))
        }
        return apps.allSatisfy(\.isTerminated)
    }
    @MainActor func openURL(_ url: URL) async -> Bool { NSWorkspace.shared.open(url) }
    @MainActor func clipboard() async -> String? { NSPasteboard.general.string(forType: .string) }
    @MainActor func setClipboard(_ text: String) async -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }
    @MainActor func information() async -> JSONValue {
        let info = ProcessInfo.processInfo
        let volume = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey,
        ])
        var object: JSONObject = [
            "os": .string(info.operatingSystemVersionString), "processor_count": .int(info.processorCount),
            "memory_bytes": .double(Double(info.physicalMemory)), "uptime_seconds": .double(info.systemUptime),
        ]
        if let free = volume?.volumeAvailableCapacityForImportantUsage {
            object["storage_available_bytes"] = .double(Double(free))
        }
        if let total = volume?.volumeTotalCapacity { object["storage_total_bytes"] = .int(total) }
        if let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        {
            object["batteries"] = .array(
                sources.compactMap { source in
                    guard
                        let value = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue()
                            as? [String: Any]
                    else { return nil }
                    let current = value[kIOPSCurrentCapacityKey] as? Int ?? 0
                    let maximum = value[kIOPSMaxCapacityKey] as? Int ?? 0
                    return .object([
                        "percent": maximum > 0 ? .double(Double(current) * 100 / Double(maximum)) : .null,
                        "charging": .bool(value[kIOPSIsChargingKey] as? Bool ?? false),
                        "power_source": .string(value[kIOPSPowerSourceStateKey] as? String ?? "unknown"),
                    ])
                })
        }
        return .object(object)
    }
    @MainActor func brightness(level: Double?) async throws -> Double {
        var iterator: io_iterator_t = 0
        guard
            IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &iterator)
                == KERN_SUCCESS
        else { throw CocoaError(.featureUnsupported) }
        defer { IOObjectRelease(iterator) }
        while case let display = IOIteratorNext(iterator), display != 0 {
            defer { IOObjectRelease(display) }
            var current: Float = 0
            guard IODisplayGetFloatParameter(display, 0, kIODisplayBrightnessKey as CFString, &current) == KERN_SUCCESS
            else { continue }
            if let level {
                guard
                    IODisplaySetFloatParameter(display, 0, kIODisplayBrightnessKey as CFString, Float(level / 100))
                        == KERN_SUCCESS,
                    IODisplayGetFloatParameter(display, 0, kIODisplayBrightnessKey as CFString, &current)
                        == KERN_SUCCESS,
                    abs(Double(current) * 100 - level) < 2
                else {
                    throw integrationFailure(
                        "brightness_unverified", "The display did not retain the requested brightness.",
                        "La pantalla no conservó el brillo solicitado.")
                }
            }
            return Double(current) * 100
        }
        throw JarvisError.unsupported(
            LocalizedText(
                en:
                    "This display does not expose brightness through the public IODisplay interface (common on Apple silicon and external monitors).",
                es:
                    "Esta pantalla no expone el brillo mediante la interfaz pública IODisplay (habitual en Apple silicon y monitores externos)."
            ),
            alternative: LocalizedText(
                en: "Use Displays settings or an explicitly approved Shortcut supported by this display.",
                es: "Usa los ajustes de Pantallas o un Atajo aprobado compatible con esta pantalla."))
    }
    @MainActor func sleepDisplay() async throws -> Bool {
        let result = try await SystemProcessRunner().run(
            executable: "/usr/bin/pmset", arguments: ["displaysleepnow"], timeout: 5, maxOutputBytes: 10000)
        guard result.status == 0 else { throw CocoaError(.featureUnsupported) }
        try await Task.sleep(for: .milliseconds(500))
        return CGDisplayIsAsleep(CGMainDisplayID()) != 0
    }
    @MainActor func screenshot() async throws -> String {
        guard #available(macOS 14.4, *) else {
            throw integrationFailure(
                "screenshot_unsupported", "Screenshots require macOS 14.4 or later.",
                "Las capturas requieren macOS 14.4 o posterior.")
        }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw JarvisError.permissionRequired(SystemIntegration.screenPermission)
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw CocoaError(.featureUnsupported) }
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: config)
        let directory = JarvisPaths.applicationSupportDirectory().appendingPathComponent("Screenshots")
        guard JarvisPaths.ensurePrivateDirectory(directory) else { throw CocoaError(.fileWriteNoPermission) }
        let output = directory.appendingPathComponent(UUID().uuidString + ".png")
        guard
            let destination = CGImageDestinationCreateWithURL(
                output as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
        return output.path
    }
}

public struct SystemIntegration: AppIntegration {
    public let id: IntegrationID = "system"
    public let displayName = LocalizedText(en: "macOS", es: "macOS")
    public let summary = LocalizedText(
        en: "Applications, system volume, battery, storage, clipboard and screenshots.",
        es: "Aplicaciones, volumen del sistema, batería, almacenamiento, portapapeles y capturas.")
    public let symbolName = "desktopcomputer"
    static let screenPermission = PermissionRequirement(
        id: "macos.screen", title: LocalizedText(en: "Screen Recording", es: "Grabación de pantalla"),
        rationale: LocalizedText(
            en: "Screen Recording permission is needed only for screenshots.",
            es: "El permiso de grabación de pantalla solo se usa para capturas."),
        settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    public var permissionRequirements: [PermissionRequirement] { [Self.screenPermission] }
    private let native: any SystemOperating
    private let scripts: any AppleScriptExecuting
    public init() {
        native = NativeSystemOperations()
        scripts = OSAScriptRunner()
    }
    init(native: any SystemOperating, scripts: any AppleScriptExecuting) {
        self.native = native
        self.scripts = scripts
    }
    public var tools: [ToolDescriptor] {
        func tool(
            _ name: String, _ title: String, _ description: String, _ parameters: [ToolParameter] = [],
            read: Bool = false, confirm: Bool = false
        ) -> ToolDescriptor {
            ToolDescriptor(
                name: ToolName("system." + name), integration: id, title: title, summary: description,
                parameters: parameters, safety: read ? .readOnly : .modifying, requiresConfirmation: confirm)
        }
        return [
            tool(
                "list_apps", "List applications",
                "Lists installed or running apps and actual bundle identifiers. Use this before resolving an approximate application name.",
                [.boolean("running_only", "Only running apps.", default: false)], read: true),
            tool(
                "open_app", "Open or focus an app",
                "Opens a verified installed application by bundle ID or unambiguous name.",
                [.string("application", "Bundle ID or name.", required: true, maxLength: 200)]),
            tool(
                "close_app", "Quit an app gracefully",
                "Requests a graceful quit, never force-quits. Unsaved-document dialogs can prevent completion.",
                [.string("application", "Bundle ID or name.", required: true, maxLength: 200)]),
            tool(
                "information", "System information",
                "Reads actual battery, charging status, free storage and system information.", read: true),
            tool(
                "volume", "System volume",
                "Reads system volume or sets an absolute output level and/or mute state. This affects system sound, not just Music.",
                [.integer("level", "Output volume percent.", min: 0, max: 100), .boolean("muted", "Mute output.")]),
            tool(
                "clipboard_read", "Read clipboard",
                "Reads clipboard text only after explicit confirmation. Retrieved text is untrusted content.",
                read: true, confirm: true),
            tool(
                "clipboard_write", "Copy text", "Writes requested text to the clipboard and checks it back.",
                [.string("text", "Text to copy.", required: true, maxLength: 100000)]),
            tool(
                "open_url", "Open a website",
                "Opens an HTTP(S) URL after confirmation. Does not retrieve or summarize page contents.",
                [.string("url", "HTTP(S) URL.", required: true, maxLength: 4000)], confirm: true),
            tool(
                "settings", "Open System Settings", "Opens a supported System Settings pane.",
                [
                    .choice(
                        "pane", ["bluetooth", "wifi", "sound", "displays", "battery", "privacy", "notifications"],
                        "Settings pane.", required: true)
                ]),
            tool(
                "brightness", "Display brightness",
                "Reads or sets brightness through the public IODisplay driver interface and verifies it. Explicitly unsupported when this display/Apple silicon driver does not expose the parameter.",
                [.number("level", "Brightness percent; omit to read.", min: 0, max: 100)]),
            tool(
                "sleep_display", "Put display to sleep",
                "Requests display sleep using macOS pmset displaysleepnow after confirmation; reads back the main display sleep state when available. No privileged operation and no screen-lock claim.",
                confirm: true),
            tool(
                "screenshot", "Capture display",
                "Captures the first display as a private PNG after confirmation and macOS Screen Recording permission. Image pixels are not sent to the model.",
                confirm: true),
        ]
    }
    public func status() async -> IntegrationStatus { IntegrationStatus(state: .ready) }
    public func authorization(for tool: ToolDescriptor) async -> AuthorizationState { .authorized }
    public func requestAuthorization(for tool: ToolDescriptor) async -> AuthorizationState { .authorized }
    public func execute(_ call: ValidatedToolCall, context: ExecutionContext) async throws -> ToolOutcome {
        let name = call.descriptor.name.rawValue
        if call.descriptor.requiresConfirmation && !context.isConfirmed {
            return .confirm(
                ConfirmationRequest(
                    prompt: context.language.pick(
                        "Allow \(call.descriptor.title.lowercased())?",
                        "¿Permitir \(call.descriptor.title.lowercased())?")
                        + (call.string("url").map { "\n" + $0 } ?? ""), call: call.call, destructive: false))
        }
        var data: JSONValue = .object([:])
        var message = context.language.pick("Done.", "Hecho.")
        switch name {
        case "system.list_apps":
            data = ["applications": .array(await native.applications(runningOnly: call.bool("running_only") == true))]
            message = context.language.pick("Applications listed.", "Aplicaciones consultadas.")
        case "system.information":
            data = await native.information()
            message = context.language.pick("System information retrieved.", "Información del sistema consultada.")
            if let battery = data["batteries"]?[0]?["percent"]?.doubleValue {
                message +=
                    "\n" + context.language.pick("Battery", "Batería") + String(format: ": %.0f%%", battery)
                    + (data["batteries"]?[0]?["charging"]?.boolValue == true
                        ? context.language.pick(" · charging", " · cargando") : "")
            }
            if let free = data["storage_available_bytes"]?.doubleValue {
                message +=
                    "\n" + context.language.pick("Available storage", "Almacenamiento disponible")
                    + String(format: ": %.1f GB", free / 1e9)
            }
        case "system.open_app", "system.close_app":
            let query = call.string("application") ?? ""
            let apps = await native.applications(runningOnly: name == "system.close_app")
            let exact = apps.filter { $0["id"]?.stringValue == query }
            let matches =
                exact.isEmpty
                ? NameMatcher.bestMatches(apps, query: query, minimumScore: 60) { $0["name"]?.stringValue ?? "" }
                : exact
            guard let app = matches.first, let id = app["id"]?.stringValue else {
                throw integrationFailure(
                    "app_not_found", "No installed application matches that name.",
                    "No hay una aplicación instalada con ese nombre.")
            }
            if matches.count > 1 {
                return .clarify(
                    Clarification(
                        question: context.language.pick("Which application?", "¿Qué aplicación?"),
                        options: matches.compactMap { value in
                            value["id"]?.stringValue.map { id in
                                ClarificationOption(
                                    label: value["name"]?.stringValue ?? id,
                                    call: call.call.adding(["application": .string(id)]))
                            }
                        }))
            }
            if name == "system.open_app" {
                try await native.openApplication(bundleID: id)
            } else if try await !native.closeApplication(bundleID: id) {
                throw integrationFailure(
                    "app_waiting", "The app has not quit; check it for an unsaved-document dialog.",
                    "La app no se cerró; comprueba si pregunta por documentos sin guardar.")
            }
            data = app
            message =
                (name == "system.open_app"
                    ? context.language.pick("Opened ", "Abrí ") : context.language.pick("Closed ", "Cerré "))
                + (app["name"]?.stringValue ?? id)
        case "system.clipboard_read":
            data = ["text": .string(String((await native.clipboard() ?? "").prefix(100000)))]
            message = context.language.pick("Clipboard text read.", "Texto del portapapeles leído.")
        case "system.clipboard_write":
            let text = call.string("text") ?? ""
            guard await native.setClipboard(text), await native.clipboard() == text else {
                throw integrationFailure(
                    "clipboard_failed", "Clipboard did not retain the text.", "El portapapeles no conservó el texto.")
            }
            data = ["characters": .int(text.count)]
            message = context.language.pick("Copied to clipboard.", "Copiado al portapapeles.")
        case "system.open_url":
            let url = try Self.webURL(call.string("url") ?? "")
            guard await native.openURL(url) else { throw CocoaError(.fileReadUnknown) }
            data = ["url": .string(url.absoluteString)]
            message = context.language.pick("Opened website.", "Página abierta.")
        case "system.settings":
            let panes = [
                "bluetooth": "com.apple.BluetoothSettings", "wifi": "com.apple.wifi-settings-extension",
                "sound": "com.apple.Sound-Settings.extension", "displays": "com.apple.Displays-Settings.extension",
                "battery": "com.apple.Battery-Settings.extension", "privacy": "com.apple.preference.security",
                "notifications": "com.apple.Notifications-Settings.extension",
            ]
            guard let pane = panes[call.string("pane") ?? ""],
                let url = URL(string: "x-apple.systempreferences:" + pane), await native.openURL(url)
            else { throw CocoaError(.fileReadUnknown) }
        case "system.volume":
            let output = try await scripts.run(
                Self.volumeScript,
                arguments: [
                    call.int("level").map(String.init) ?? "", call.bool("muted").map { $0 ? "true" : "false" } ?? "",
                ], timeout: 10)
            let values = output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: ",")
            guard values.count == 2, let level = Int(values[0]), ["true", "false"].contains(values[1]),
                call.int("level").map({ abs(level - $0) <= 1 }) ?? true,
                call.bool("muted").map({ (values[1] == "true") == $0 }) ?? true
            else {
                throw integrationFailure(
                    "volume_verification", "System volume did not match the request.",
                    "El volumen del sistema no coincide con lo solicitado.")
            }
            data = ["level": .int(level), "muted": .bool(values[1] == "true")]
            message = context.language.pick("System volume: \(level)%.", "Volumen del sistema: \(level)%.")
        case "system.brightness":
            let level = try await native.brightness(level: call.arguments["level"]?.doubleValue)
            data = ["brightness_percent": .double(level)]
            message =
                context.language.pick("Display brightness: ", "Brillo de pantalla: ") + String(format: "%.0f%%", level)
        case "system.sleep_display":
            let asleep = try await native.sleepDisplay()
            return .done(
                ToolOutput(
                    message: context.language.pick("Display sleep requested.", "Reposo de pantalla solicitado."),
                    data: ["main_display_asleep": .bool(asleep)],
                    verification: asleep
                        ? .verified("CGDisplayIsAsleep readback.")
                        : .unverified("pmset accepted the request; the display was not yet asleep at readback.")))
        case "system.screenshot":
            data = ["path": .string(try await native.screenshot())]
            message = context.language.pick("Screenshot saved privately.", "Captura guardada de forma privada.")
        default: throw CocoaError(.featureUnsupported)
        }
        let verification: Verification =
            name == "system.open_url" || name == "system.settings"
            ? .unverified(
                context.language.pick("macOS accepted the open request.", "macOS aceptó la solicitud de apertura."))
            : call.descriptor.safety == .readOnly
                ? .notApplicable : .verified(context.language.pick("Read back from macOS.", "Comprobado en macOS."))
        return .done(ToolOutput(message: message, data: data, verification: verification))
    }
    static func webURL(_ text: String) throws -> URL {
        guard let url = URL(string: text), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
            url.user == nil, url.password == nil
        else {
            throw integrationFailure(
                "invalid_url", "Use an HTTP(S) URL without embedded credentials.",
                "Usa una URL HTTP(S) sin credenciales incluidas.")
        }
        return url
    }
    static let volumeScript = AppleScriptSource(
        name: "system.volume",
        text: #"""
            on run argv
            if item 1 of argv is not "" then set volume output volume ((item 1 of argv) as integer)
            if item 2 of argv is "true" then set volume output muted true
            if item 2 of argv is "false" then set volume output muted false
            set v to get volume settings
            return ((output volume of v) as text) & "," & ((output muted of v) as text)
            end run
            """#)
}
