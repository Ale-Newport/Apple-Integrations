import JarvisCore
import SwiftUI

/// One place to see, request and fix every macOS permission Jarvis uses.
struct PermissionsSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                Text(model.t(
                    "Jarvis only asks for what a feature needs, and only when you ask for it or press Allow here. macOS shows its own prompt; Jarvis never changes privacy settings for you.",
                    "Jarvis solo pide lo que necesita cada función, y solo cuando tú lo pides o pulsas Permitir aquí. macOS muestra su propio aviso; Jarvis nunca cambia por ti los ajustes de privacidad."
                ))
                .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button(model.t("Check again", "Comprobar de nuevo")) { model.refreshStatuses() }
                    Button(model.t("Open Privacy & Security", "Abrir Privacidad y seguridad")) {
                        model.openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy")
                    }
                }
            }
            ForEach(model.environment.integrations, id: \.id) { integration in
                Section {
                    if let status = model.statuses[integration.id], !status.permissions.isEmpty {
                        ForEach(status.permissions) { entry in
                            PermissionRow(integration: integration, entry: entry)
                        }
                    } else if integration.permissionRequirements.isEmpty {
                        Label(model.t("No macOS privacy permission needed.", "No necesita ningún permiso de privacidad de macOS."), systemImage: "checkmark.shield")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(model.t("Checking…", "Comprobando…")).foregroundStyle(.secondary)
                    }
                    if let status = model.statuses[integration.id], status.permissions.isEmpty, let detail = status.detail {
                        Text(detail.resolved(model.language)).font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    HStack(spacing: 6) {
                        Image(systemName: integration.symbolName)
                        Text(integration.displayName.resolved(model.language))
                        StatusDot(state: model.statuses[integration.id]?.state)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshStatuses() }
    }
}
