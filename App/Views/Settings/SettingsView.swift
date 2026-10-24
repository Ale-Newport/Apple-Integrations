import JarvisCore
import JarvisInterpreter
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppShell.self) private var shell
    @AppStorage("pref.settingsTab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettingsView()
                .tabItem { Label(model.t("General", "General"), systemImage: "gearshape") }
                .tag("general")
            IntelligenceSettingsView()
                .tabItem { Label(model.t("Intelligence", "Inteligencia"), systemImage: "sparkles") }
                .tag("intelligence")
            PermissionsSettingsView()
                .tabItem { Label(model.t("Permissions", "Permisos"), systemImage: "lock.shield") }
                .tag("permissions")
            IntegrationSettingsView()
                .tabItem { Label(model.t("Integrations", "Integraciones"), systemImage: "puzzlepiece.extension") }
                .tag("integrations")
            PrivacySettingsView()
                .tabItem { Label(model.t("Privacy", "Privacidad"), systemImage: "hand.raised") }
                .tag("privacy")
            AdvancedSettingsView()
                .tabItem { Label(model.t("Advanced", "Avanzado"), systemImage: "terminal") }
                .tag("advanced")
        }
        .frame(width: 680, height: 560)
        .preferredColorScheme(shell.appearance.colorScheme)
    }
}

struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppShell.self) private var shell
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?

    var body: some View {
        Form {
            Section(model.t("Language", "Idioma")) {
                Picker(
                    model.t("Replies and interface", "Respuestas e interfaz"),
                    selection: model.binding(\.languagePreference)
                ) {
                    Text(model.t("Automatic — match what I type", "Automático: el idioma que escriba")).tag(
                        LanguagePreference.automatic)
                    Text("English").tag(LanguagePreference.english)
                    Text("Español").tag(LanguagePreference.spanish)
                }
                Text(
                    model.t(
                        "Jarvis understands English and Spanish commands whatever you choose here, including both in one sentence.",
                        "Jarvis entiende comandos en español e inglés elijas lo que elijas, incluso mezclados en una frase."
                    )
                )
                .font(.caption).foregroundStyle(.secondary)
            }

            Section(model.t("Appearance", "Apariencia")) {
                Picker(
                    model.t("Theme", "Tema"),
                    selection: Binding(get: { shell.appearance }, set: { shell.setAppearance($0) })
                ) {
                    Text(model.t("Match system", "Como el sistema")).tag(AppearancePreference.system)
                    Text(model.t("Light", "Claro")).tag(AppearancePreference.light)
                    Text(model.t("Dark", "Oscuro")).tag(AppearancePreference.dark)
                }
                .pickerStyle(.segmented)
            }

            Section(model.t("Where Jarvis lives", "Dónde vive Jarvis")) {
                Toggle(
                    model.t("Show in the Dock", "Mostrar en el Dock"),
                    isOn: Binding(get: { shell.showInDock }, set: { shell.setShowInDock($0) })
                )
                .disabled(shell.showInDock && !shell.showMenuBarIcon)
                Toggle(
                    model.t("Show in the menu bar", "Mostrar en la barra de menús"),
                    isOn: Binding(get: { shell.showMenuBarIcon }, set: { shell.setShowMenuBarIcon($0) })
                )
                .disabled(shell.showMenuBarIcon && !shell.showInDock)
                Text(
                    model.t(
                        "At least one of them stays on so Jarvis is always reachable.",
                        "Al menos una queda activada para que siempre puedas llegar a Jarvis.")
                )
                .font(.caption).foregroundStyle(.secondary)
                Toggle(
                    model.t("Open at login", "Abrir al iniciar sesión"),
                    isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                if LaunchAtLogin.needsApproval {
                    Label(
                        model.t(
                            "macOS needs your approval in System Settings ▸ General ▸ Login Items.",
                            "macOS necesita tu aprobación en Ajustes del Sistema ▸ General ▸ Ítems de inicio."),
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption).foregroundStyle(.orange)
                }
                if let launchError {
                    Text(launchError).font(.caption).foregroundStyle(.red)
                }
            }

            Section(model.t("Global shortcut", "Atajo global")) {
                Toggle(
                    model.t("Open Jarvis from anywhere", "Abrir Jarvis desde cualquier sitio"),
                    isOn: Binding(get: { shell.hotkeyEnabled }, set: { shell.setHotkeyEnabled($0) }))
                LabeledContent(model.t("Shortcut", "Atajo")) {
                    HStack {
                        ShortcutRecorder(combo: shell.hotkey) { shell.setHotkey($0) }
                        Button(model.t("Reset", "Restablecer")) { shell.resetHotkey() }
                            .disabled(shell.hotkey == .default)
                    }
                }
                .disabled(!shell.hotkeyEnabled)
                if let error = shell.hotkeyError {
                    Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
                Text(
                    model.t(
                        "Pressing it shows Jarvis with the command field ready. It needs no extra permission.",
                        "Al pulsarlo aparece Jarvis con el campo de comandos listo. No necesita permisos adicionales.")
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLogin.set(enabled)
            launchError = nil
        } catch {
            launchError = model.t(
                "Could not change this: \(error.localizedDescription)",
                "No se pudo cambiar: \(error.localizedDescription)")
        }
        launchAtLogin = LaunchAtLogin.isEnabled
    }
}

struct IntelligenceSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var apiKey = ""
    @State private var feedback: String?
    @State private var alias = ""
    @State private var target = ""
    @State private var testing = false

    var body: some View {
        Form {
            Section(model.t("Model provider", "Proveedor del modelo")) {
                Toggle(
                    model.t("Use AI for advanced requests", "Usar IA para peticiones avanzadas"),
                    isOn: model.binding(\.model.enabled))
                CommitTextField(
                    title: model.t("API base URL", "URL base de la API"), value: model.settings.model.endpoint
                ) { endpoint in
                    let value = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let c = URLComponents(string: value), let host = c.host?.lowercased(), c.user == nil,
                        c.password == nil, c.query == nil, c.fragment == nil,
                        c.scheme == "https"
                            || (c.scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host))
                    else {
                        feedback = model.t(
                            "Use an HTTPS base URL (or local HTTP) without credentials, query or fragment. Store API keys in Keychain below.",
                            "Usa una URL HTTPS (o HTTP local) sin credenciales, consulta ni fragmento. Guarda las claves en el Llavero, abajo."
                        )
                        return
                    }
                    if value != model.settings.model.endpoint { model.update { $0.model.endpoint = value } }
                }
                TextField(model.t("Model name", "Nombre del modelo"), text: model.binding(\.model.model))
                Toggle(
                    model.t("Use native API tool calling", "Usar llamadas nativas de herramientas"),
                    isOn: model.binding(\.model.nativeTools))
                Toggle(
                    model.t("Request JSON output from the provider", "Solicitar salida JSON al proveedor"),
                    isOn: model.binding(\.model.jsonMode))
                Text(
                    model.t(
                        "Ollama: http://localhost:11434/v1 · llama.cpp and any compatible API. Remote endpoints require HTTPS. Simple commands work offline.",
                        "Ollama: http://localhost:11434/v1 · llama.cpp y cualquier API compatible. Los servidores remotos requieren HTTPS. Los comandos sencillos funcionan sin conexión."
                    )
                )
                .font(.caption).foregroundStyle(.secondary)
                SecureField(
                    model.t("API key (optional for local models)", "Clave de API (opcional para modelos locales)"),
                    text: $apiKey)
                HStack {
                    Button(model.t("Save key", "Guardar clave")) { saveKey() }.disabled(apiKey.isEmpty)
                    Button(model.t("Remove key", "Eliminar clave")) {
                        do {
                            try KeychainSecretStore().removeSecret(for: model.settings.model.credentialAccount)
                            feedback = model.t("Key removed.", "Clave eliminada.")
                        } catch { feedback = model.t("Could not access Keychain.", "No se pudo acceder al Llavero.") }
                    }
                    Button(model.t("Test connection", "Probar conexión")) { testConnection() }.disabled(testing)
                    if testing { ProgressView().controlSize(.small) }
                }
                Text(
                    model.t(
                        "When enabled, requests, recent session context and tool results are sent to the configured provider. Keys stay in macOS Keychain. No provider is configured by default.",
                        "Al activarlo, las peticiones, el contexto reciente y los resultados se envían al proveedor configurado. Las claves se guardan en el Llavero. No hay proveedor activo por defecto."
                    )
                )
                .font(.caption).foregroundStyle(.secondary)
                if let feedback { Text(feedback).font(.caption).textSelection(.enabled) }
            }
            Section(model.t("Authorized web search", "Búsqueda web autorizada")) {
                CommitTextField(
                    title: model.t("SearXNG search URL", "URL de búsqueda SearXNG"),
                    value: model.settings.capabilities.searchEndpoint
                ) { endpoint in model.update { $0.capabilities.searchEndpoint = endpoint } }
                Text(
                    model.t(
                        "Optional. Use a trusted SearXNG /search endpoint with JSON enabled. HTTPS is required outside localhost. Queries are sent to this provider; retrieved sources are shown with links. Without it, Jarvis cannot verify current web facts.",
                        "Opcional. Usa el endpoint /search de un servidor SearXNG de confianza con JSON activado. Se exige HTTPS fuera de localhost. Las consultas se envían a ese proveedor; las fuentes se muestran con enlaces. Sin él, Jarvis no puede verificar información web actual."
                    )
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Section(model.t("Conversation and preferences", "Conversación y preferencias")) {
                Toggle(
                    model.t("Remember context during this session", "Recordar el contexto durante esta sesión"),
                    isOn: model.binding(\.rememberSession))
                Toggle(
                    model.t("Use my saved aliases", "Usar mis alias guardados"),
                    isOn: model.binding(\.preferenceMemoryEnabled))
                TextField(
                    model.t("Default weather location", "Ubicación predeterminada para el tiempo"),
                    text: Binding(
                        get: { model.settings.weatherLocation ?? "" },
                        set: { value in model.update { $0.weatherLocation = value.isEmpty ? nil : value } }))
                ForEach(model.settings.aliases.keys.sorted(), id: \.self) { key in
                    HStack {
                        Text(key)
                        Spacer()
                        Text(model.settings.aliases[key] ?? "").foregroundStyle(.secondary)
                        Button(role: .destructive) {
                            model.update { $0.aliases[key] = nil }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField(model.t("Alias", "Alias"), text: $alias)
                    TextField(model.t("Refers to", "Se refiere a"), text: $target)
                    Button(model.t("Save", "Guardar")) {
                        model.update { $0.aliases[alias.trimmingCharacters(in: .whitespacesAndNewlines)] = target }
                        alias = ""
                        target = ""
                    }.disabled(alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || target.isEmpty)
                }
                Button(
                    model.t("Erase aliases and session context", "Borrar alias y contexto de sesión"),
                    role: .destructive
                ) {
                    model.update { $0.aliases = [:] }
                    Task { await model.environment.engine.clearSession("ui") }
                }
            }
        }.formStyle(.grouped)
    }

    private func saveKey() {
        do {
            try KeychainSecretStore().set(apiKey, for: model.settings.model.credentialAccount)
            apiKey = ""
            feedback = model.t("Key saved in Keychain.", "Clave guardada en el Llavero.")
        } catch { feedback = model.t("Could not save the key.", "No se pudo guardar la clave.") }
    }

    private func testConnection() {
        testing = true
        let configuration = model.settings.model
        Task {
            defer { testing = false }
            do {
                let provider = CompatibleModelProvider(
                    configuration: configuration,
                    secret: try KeychainSecretStore().secret(for: configuration.credentialAccount))
                _ = try await provider.complete(
                    system: "Reply with a JSON object: {\"reply\":\"OK\"}.", user: "Connection test")
                feedback = model.t("Connection succeeded.", "Conexión correcta.")
            } catch {
                feedback = model.t(
                    "Connection failed. Check endpoint, model, key and whether the server is running.",
                    "No se pudo conectar. Revisa la URL, el modelo, la clave y que el servidor esté activo.")
            }
        }
    }
}
