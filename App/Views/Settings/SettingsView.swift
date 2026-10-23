import JarvisCore
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
                Picker(model.t("Replies and interface", "Respuestas e interfaz"), selection: model.binding(\.languagePreference)) {
                    Text(model.t("Automatic — match what I type", "Automático: el idioma que escriba")).tag(LanguagePreference.automatic)
                    Text("English").tag(LanguagePreference.english)
                    Text("Español").tag(LanguagePreference.spanish)
                }
                Text(model.t(
                    "Jarvis understands English and Spanish commands whatever you choose here, including both in one sentence.",
                    "Jarvis entiende comandos en español e inglés elijas lo que elijas, incluso mezclados en una frase."
                ))
                .font(.caption).foregroundStyle(.secondary)
            }

            Section(model.t("Appearance", "Apariencia")) {
                Picker(model.t("Theme", "Tema"), selection: Binding(get: { shell.appearance }, set: { shell.setAppearance($0) })) {
                    Text(model.t("Match system", "Como el sistema")).tag(AppearancePreference.system)
                    Text(model.t("Light", "Claro")).tag(AppearancePreference.light)
                    Text(model.t("Dark", "Oscuro")).tag(AppearancePreference.dark)
                }
                .pickerStyle(.segmented)
            }

            Section(model.t("Where Jarvis lives", "Dónde vive Jarvis")) {
                Toggle(model.t("Show in the Dock", "Mostrar en el Dock"), isOn: Binding(get: { shell.showInDock }, set: { shell.setShowInDock($0) }))
                    .disabled(shell.showInDock && !shell.showMenuBarIcon)
                Toggle(model.t("Show in the menu bar", "Mostrar en la barra de menús"), isOn: Binding(get: { shell.showMenuBarIcon }, set: { shell.setShowMenuBarIcon($0) }))
                    .disabled(shell.showMenuBarIcon && !shell.showInDock)
                Text(model.t("At least one of them stays on so Jarvis is always reachable.", "Al menos una queda activada para que siempre puedas llegar a Jarvis."))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(model.t("Open at login", "Abrir al iniciar sesión"), isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                if LaunchAtLogin.needsApproval {
                    Label(model.t("macOS needs your approval in System Settings ▸ General ▸ Login Items.", "macOS necesita tu aprobación en Ajustes del Sistema ▸ General ▸ Ítems de inicio."), systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let launchError {
                    Text(launchError).font(.caption).foregroundStyle(.red)
                }
            }

            Section(model.t("Global shortcut", "Atajo global")) {
                Toggle(model.t("Open Jarvis from anywhere", "Abrir Jarvis desde cualquier sitio"), isOn: Binding(get: { shell.hotkeyEnabled }, set: { shell.setHotkeyEnabled($0) }))
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
                Text(model.t("Pressing it shows Jarvis with the command field ready. It needs no extra permission.", "Al pulsarlo aparece Jarvis con el campo de comandos listo. No necesita permisos adicionales."))
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
            launchError = model.t("Could not change this: \(error.localizedDescription)", "No se pudo cambiar: \(error.localizedDescription)")
        }
        launchAtLogin = LaunchAtLogin.isEnabled
    }
}
