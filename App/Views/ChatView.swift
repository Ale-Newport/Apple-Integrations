import AppKit
import JarvisCore
import SwiftUI

struct ChatView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: model.settings.model.enabled ? "sparkles" : "desktopcomputer")
                Text(model.settings.model.enabled
                    ? model.t("AI assistant · \(model.settings.model.model)", "Asistente IA · \(model.settings.model.model)")
                    : model.t("Local commands · Configure a model in Settings for advanced workflows", "Comandos locales · Configura un modelo en Ajustes para flujos avanzados"))
                Spacer()
                if model.settings.rememberSession {
                    Image(systemName: "bubble.left.and.bubble.right").help(model.t("Session context enabled", "Contexto de sesión activado"))
                }
            }
            .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 8)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if model.messages.isEmpty {
                            WelcomeView()
                        }
                        ForEach(model.messages) { message in
                            MessageRow(message: message).id(message.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(20)
                }
                .scrollBounceBehavior(.basedOnSize)
                .onChange(of: model.messages) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            Divider()
            InputBar()
        }
        .toolbar {
            ToolbarItemGroup {
                if model.hasRunningCommands {
                    Button { model.cancelAll() } label: { Label(model.t("Stop all", "Detener todo"), systemImage: "stop.circle") }
                        .help(model.t("Cancel everything that is running", "Cancelar todo lo que se está ejecutando"))
                }
                Button { model.clearConversation() } label: { Label(model.t("Clear conversation", "Limpiar conversación"), systemImage: "trash") }
                    .disabled(model.messages.isEmpty)
                    .help(model.t("Clear the conversation (your history is kept)", "Limpiar la conversación (el historial se conserva)"))
            }
        }
        .navigationTitle(model.t("Assistant", "Asistente"))
    }
}

struct InputBar: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool
    var compact = false

    /// Puts a line break at the caret of whichever text field is being edited (the key window first, then any visible one).
    private static func insertLineBreakAtCaret() {
        let candidates = [NSApp.keyWindow].compactMap { $0 } + NSApp.windows.filter(\.isVisible)
        for window in candidates {
            if let editor = window.firstResponder as? NSTextView, editor.isEditable {
                editor.insertNewlineIgnoringFieldEditor(nil)
                return
            }
        }
    }

    var body: some View {
        @Bindable var model = model
        HStack(alignment: .bottom, spacing: 8) {
            TextField(
                compact
                    ? model.t("Tell Jarvis what to do…", "Dile a Jarvis qué hacer…")
                    : model.t("Tell Jarvis what to do…  (e.g. “Play my Study playlist”)", "Dile a Jarvis qué hacer…  (p. ej. «Pon mi lista Study»)"),
                text: $model.input, axis: .vertical
            )
            .textFieldStyle(.plain)
            .lineLimit(1...(compact ? 3 : 8))
            .focused($focused)
            .onSubmit { model.submit() }
            .onKeyPress(.return, phases: .down) { press in
                // Return runs the command (onSubmit). Shift+Return adds a line, like every chat app: the field editor's own
                // "insert newline ignoring the field editor" action puts it at the caret. (Option+Return does this natively.)
                guard press.modifiers.contains(.shift) else { return .ignored }
                Self.insertLineBreakAtCaret()
                return .handled
            }
            .onKeyPress(.upArrow) {
                guard model.input.isEmpty || model.input.split(separator: "\n").count <= 1 else { return .ignored }
                model.recallPrevious()
                return .handled
            }
            .onKeyPress(.downArrow) {
                guard !model.input.contains("\n") else { return .ignored }
                model.recallNext()
                return .handled
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.separator))
            .accessibilityLabel(model.t("Command", "Comando"))

            Button {
                model.submit()
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 26))
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary : Color.accentColor)
            .disabled(model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help(model.t("Run (Return)", "Ejecutar (Intro)"))
            .accessibilityLabel(model.t("Run command", "Ejecutar comando"))
        }
        .padding(compact ? 8 : 12)
        .onAppear { focused = true }
        .onChange(of: model.focusRequest) { _, _ in focused = true }
    }
}

/// Shown while the conversation is empty: what Jarvis can do, with examples that fill the input when clicked.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    private struct Example: Identifiable {
        let id = UUID()
        let symbol: String
        let english: String
        let spanish: String
    }

    private let examples: [Example] = [
        Example(symbol: "function", english: "Calculate (2+3)^4", spanish: "Calcula el 17,5% de 2.450"),
        Example(symbol: "cloud.sun", english: "Weather in London tomorrow", spanish: "¿Va a llover mañana en Londres?"),
        Example(symbol: "music.note", english: "Play my Study playlist", spanish: "Pon mi lista Study"),
        Example(symbol: "checklist", english: "Remind me tomorrow at 6 PM to submit my assignment", spanish: "Recuérdame mañana a las 6 PM entregar mi tarea"),
        Example(symbol: "checklist", english: "Add milk to my Shopping reminders list", spanish: "Agrega leche a mi lista de recordatorios Compras"),
        Example(symbol: "note.text", english: "Create a note called Project Ideas with the following content: …", spanish: "Crea una nota llamada Ideas con el siguiente contenido: …"),
        Example(symbol: "calendar", english: "Schedule a meeting with Daniel on Friday at 3 PM for one hour", spanish: "Agenda una reunión con Daniel el viernes a las 3 PM por una hora"),
        Example(symbol: "calendar", english: "What's on my calendar tomorrow?", spanish: "¿Qué tengo en mi calendario mañana?"),
        Example(symbol: "alarm", english: "Set an alarm for 7:30 tomorrow morning", spanish: "Pon una alarma a las 7:30 de la mañana"),
        Example(symbol: "bolt.horizontal", english: "Play my Chill playlist and remind me to study at 8 PM", spanish: "Pon mi lista Chill y recuérdame estudiar a las 8 PM"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.t("What would you like to do?", "¿Qué quieres hacer?")).font(.title2.weight(.semibold))
                Text(model.t(
                    "Type a command in English or Spanish. Jarvis acts directly in Apple Music, Reminders, Notes, Calendar and Clock — and tells you exactly what happened.",
                    "Escribe un comando en español o inglés. Jarvis actúa directamente en Apple Music, Recordatorios, Notas, Calendario y Reloj, y te dice exactamente qué pasó."
                ))
                .foregroundStyle(.secondary)
            }
            if needsAttention {
                Button {
                    model.selection = .integration(firstNeedingAttention ?? .music)
                } label: {
                    Label(model.t("Some integrations need permission or setup — review", "Algunas integraciones necesitan permiso o configuración: revisar"), systemImage: "lock.shield")
                }
                .buttonStyle(.bordered)
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(examples) { example in
                    Button {
                        model.input = model.t(example.english, example.spanish)
                        model.requestFocus()
                    } label: {
                        Label(model.t(example.english, example.spanish), systemImage: example.symbol)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }
            .frame(maxWidth: 560)
            Text(model.t("Say “help” for more examples. Up-arrow recalls earlier commands.", "Di «ayuda» para ver más ejemplos. La flecha arriba recupera comandos anteriores."))
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.top, 24)
    }

    private var firstNeedingAttention: IntegrationID? {
        model.environment.integrations.first { id in
            if let state = model.statuses[id.id]?.state { return state != .ready }
            return false
        }?.id
    }

    private var needsAttention: Bool { firstNeedingAttention != nil }
}
