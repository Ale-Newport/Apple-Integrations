import JarvisCore
import SwiftUI

struct MainWindowView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(AppShell.self) private var shell

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView(selection: $model.selection)
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } detail: {
            switch model.selection {
            case .chat: ChatView()
            case .history: HistoryView()
            case .integration(let id): IntegrationDetailView(integrationID: id)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .onAppear {
            OpenWindowBridge.shared.open = { openWindow(id: "main") }
            AppDelegate.closeMainWindowIfLaunchedAtLogin()
        }
        #if DEBUG
        .task { model.applyDebugLaunchArguments(shell: shell, openSettings: { openSettings() }, openWindow: { openWindow(id: $0) }) }
        #endif
        .overlay(alignment: .top) { NoticeBanner() }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SidebarItem

    var body: some View {
        List(selection: $selection) {
            Section(model.t("Assistant", "Asistente")) {
                Label(model.t("Chat", "Chat"), systemImage: "bubble.left.and.bubble.right").tag(SidebarItem.chat)
                Label(model.t("History", "Historial"), systemImage: "clock.arrow.circlepath").tag(SidebarItem.history)
            }
            Section(model.t("Apple integrations", "Integraciones de Apple")) {
                ForEach(model.environment.integrations, id: \.id) { integration in
                    HStack {
                        Label(integration.displayName.resolved(model.language), systemImage: integration.symbolName)
                        Spacer()
                        StatusDot(state: model.statuses[integration.id]?.state)
                    }
                    .tag(SidebarItem.integration(integration.id))
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                SettingsLink {
                    Label(model.t("Settings", "Ajustes"), systemImage: "gearshape")
                }
                .buttonStyle(.borderless)
                Spacer()
                if model.environment.ipc.isRunning {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .foregroundStyle(.secondary)
                        .help(model.t("Local control channel is on", "El canal de control local está activo"))
                }
            }
            .padding(10)
        }
    }
}

struct StatusDot: View {
    let state: IntegrationStatus.State?

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .help(label)
            .accessibilityLabel(label)
    }

    private var color: Color {
        switch state {
        case .ready?: return .green
        case .needsPermission?, .needsSetup?: return .orange
        case .denied?, .restricted?: return .red
        case .unavailable?: return .gray
        case nil: return .gray.opacity(0.4)
        }
    }

    private var label: String {
        switch state {
        case .ready?: return "Ready"
        case .needsPermission?: return "Needs permission"
        case .needsSetup?: return "Needs setup"
        case .denied?: return "Access denied"
        case .restricted?: return "Restricted"
        case .unavailable?: return "Unavailable"
        case nil: return "Checking…"
        }
    }
}

struct NoticeBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let notice = model.notice {
            Text(notice)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .shadow(radius: 4)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: notice) {
                    try? await Task.sleep(for: .seconds(4))
                    withAnimation { model.notice = nil }
                }
        }
    }
}
