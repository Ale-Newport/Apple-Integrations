import JarvisCore
import SwiftUI

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var confirmClear = false
    @State private var reviewing: HistoryEntry?
    @State private var selection = Set<UUID>()

    private var entries: [HistoryEntry] {
        let all = model.historyEntries
        guard !query.isEmpty else { return all }
        return all.filter {
            $0.text.localizedCaseInsensitiveContains(query) || $0.summary.localizedCaseInsensitiveContains(query)
                || ($0.conversation?.answer.localizedCaseInsensitiveContains(query) ?? false)
                || ($0.conversation?.user.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        Group {
            if model.historyEntries.isEmpty {
                ContentUnavailableView(
                    model.t("No history yet", "Todavía no hay historial"),
                    systemImage: "clock.arrow.circlepath",
                    description: Text(
                        model.settings.saveHistory
                            ? model.t(
                                "Commands you run appear here so you can reuse them.",
                                "Los comandos que ejecutes aparecerán aquí para reutilizarlos.")
                            : model.t(
                                "Saving history is switched off in Settings ▸ Privacy.",
                                "Guardar el historial está desactivado en Ajustes ▸ Privacidad."))
                )
            } else {
                List(selection: $selection) {
                    ForEach(entries) { entry in
                        HistoryRow(entry: entry)
                            .tag(entry.id)
                            .contextMenu {
                                if entry.conversation != nil {
                                    Button(model.t("Read conversation", "Leer conversación")) { reviewing = entry }
                                }
                                Button(model.t("Use in input", "Usar en el campo")) { model.reuse(entry) }
                                Button(model.t("Run again", "Ejecutar de nuevo")) { model.rerun(entry) }
                                Button(model.t("Copy", "Copiar")) {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(entry.text, forType: .string)
                                }
                                Divider()
                                Button(model.t("Delete", "Eliminar"), role: .destructive) {
                                    model.deleteHistory(selection.contains(entry.id) ? selection : [entry.id])
                                }
                            }
                    }
                }
                .searchable(text: $query, prompt: model.t("Search history", "Buscar en el historial"))
                .onDeleteCommand { model.deleteHistory(selection) }
            }
        }
        .navigationTitle(model.t("History", "Historial"))
        .toolbar {
            ToolbarItem {
                Button(role: .destructive) {
                    confirmClear = true
                } label: {
                    Label(model.t("Clear history", "Borrar historial"), systemImage: "trash")
                }
                .disabled(model.historyEntries.isEmpty)
            }
        }
        .confirmationDialog(model.t("Delete all history?", "¿Borrar todo el historial?"), isPresented: $confirmClear) {
            Button(model.t("Delete history", "Borrar historial"), role: .destructive) { model.clearHistory() }
        } message: {
            Text(
                model.t(
                    "Only Jarvis' own record of your commands is removed; nothing in your Apple apps is touched.",
                    "Solo se borra el registro de comandos de Jarvis; no se toca nada de tus apps de Apple."))
        }
        .sheet(item: $reviewing) { entry in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text(entry.date, format: .dateTime).foregroundStyle(.secondary)
                        Spacer()
                        Button(model.t("Close", "Cerrar")) { reviewing = nil }
                    }
                    if let conversation = entry.conversation {
                        Text(conversation.user).font(.headline).textSelection(.enabled)
                        Text(conversation.answer).textSelection(.enabled)
                        ForEach(Array(conversation.steps.enumerated()), id: \.offset) { _, step in
                            GroupBox(step.tool + " · " + step.status.rawValue) {
                                VStack(alignment: .leading) {
                                    Text(step.message).textSelection(.enabled)
                                    Text("\(step.durationMs) ms").font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }.padding(24)
            }.frame(width: 650, height: 550)
        }
        .onAppear { model.refreshHistory() }
    }
}

struct HistoryRow: View {
    @Environment(AppModel.self) private var model
    let entry: HistoryEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.status.symbol).foregroundStyle(ResponseTone(status: entry.status).color).frame(
                width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.text).lineLimit(2)
                Text(entry.summary.replacingOccurrences(of: "\n", with: " ")).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(entry.date, format: .dateTime.month().day().hour().minute()).font(.caption2).foregroundStyle(
                    .tertiary)
            }
            Spacer()
            Button {
                model.reuse(entry)
            } label: {
                Image(systemName: "arrow.uturn.left.circle")
            }
            .buttonStyle(.borderless)
            .help(model.t("Use again in the input field", "Usar de nuevo en el campo de texto"))
            Button {
                model.rerun(entry)
            } label: {
                Image(systemName: "play.circle")
            }
            .buttonStyle(.borderless)
            .help(model.t("Run again now", "Ejecutar de nuevo ahora"))
        }
        .padding(.vertical, 2)
    }
}
