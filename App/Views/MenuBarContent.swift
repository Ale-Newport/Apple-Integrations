import AppKit
import JarvisCore
import SwiftUI

/// The popover behind the menu bar icon: a compact command field, playback buttons and the latest results.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Jarvis").font(.headline)
                if model.hasRunningCommands { ProgressView().controlSize(.small) }
                Spacer()
                Button { model.showMainWindow() } label: { Image(systemName: "macwindow") }
                    .help(model.t("Open the Jarvis window", "Abrir la ventana de Jarvis"))
                Button {
                    NSApp.activate()
                    openSettings()
                } label: { Image(systemName: "gearshape") }
                    .help(model.t("Settings", "Ajustes"))
                Button { NSApplication.shared.terminate(nil) } label: { Image(systemName: "power") }
                    .help(model.t("Quit Jarvis", "Salir de Jarvis"))
            }
            .buttonStyle(.borderless)

            InputBar(compact: true)

            HStack(spacing: 18) {
                Spacer()
                playback("backward.fill", .musicPrevious, model.t("Previous song", "Canción anterior"))
                playback("pause.fill", .musicPause, model.t("Pause the music", "Pausar la música"))
                playback("play.fill", .musicResume, model.t("Resume the music", "Reanudar la música"))
                playback("forward.fill", .musicNext, model.t("Next song", "Siguiente canción"))
                playback("music.note.list", .musicNowPlaying, model.t("What's playing?", "¿Qué suena?"))
                Spacer()
            }

            if model.messages.isEmpty {
                Text(model.t("Type a command in English or Spanish, for example “Pause the music”.", "Escribe un comando en español o inglés, por ejemplo «Pausa la música»."))
                    .font(.callout).foregroundStyle(.secondary).padding(.horizontal, 8)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(model.messages.suffix(3)) { message in
                                MessageRow(message: message).id(message.id)
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                    .frame(maxHeight: 320)
                    .onChange(of: model.messages) { _, messages in
                        if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
        .padding(10)
        .frame(width: 420)
        .onAppear {
            OpenWindowBridge.shared.open = { openWindow(id: "main") }
            model.requestFocus()
        }
    }

    private func playback(_ symbol: String, _ tool: ToolName, _ label: String) -> some View {
        Button { model.runTool(tool, label: label) } label: {
            Image(systemName: symbol).frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }
}
