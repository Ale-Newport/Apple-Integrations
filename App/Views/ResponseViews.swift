import JarvisCore
import SwiftUI

// MARK: - Visual vocabulary

extension ResponseTone {
    var color: Color {
        switch self {
        case .success: return .green
        case .failure: return .red
        case .warning: return .orange
        case .neutral: return .secondary
        case .info: return .blue
        }
    }
}

extension ToolResult.Status {
    var symbol: String {
        switch self {
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .permissionRequired: return "lock.shield.fill"
        case .needsConfirmation: return "questionmark.circle.fill"
        case .needsClarification: return "list.bullet.circle.fill"
        case .setupRequired: return "wrench.and.screwdriver.fill"
        case .unavailable: return "exclamationmark.triangle.fill"
        case .unsupported: return "nosign"
        case .skipped: return "forward.circle"
        case .cancelled: return "slash.circle"
        case .duplicate: return "doc.on.doc.fill"
        }
    }

    var color: Color {
        switch self {
        case .completed: return .green
        case .failed: return .red
        case .permissionRequired, .needsConfirmation, .setupRequired: return .orange
        case .needsClarification: return .blue
        case .unavailable, .unsupported, .skipped, .cancelled, .duplicate: return .secondary
        }
    }
}

extension EngineResponse.Status {
    var symbol: String {
        switch self {
        case .completed: return "checkmark.circle.fill"
        case .partial: return "exclamationmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .permissionRequired: return "lock.shield.fill"
        case .needsConfirmation: return "questionmark.circle.fill"
        case .needsClarification: return "list.bullet.circle.fill"
        case .setupRequired: return "wrench.and.screwdriver.fill"
        case .unavailable: return "exclamationmark.triangle.fill"
        case .unsupported: return "nosign"
        case .duplicate: return "doc.on.doc.fill"
        case .cancelled: return "slash.circle"
        case .reply: return "bubble.left.fill"
        case .unrecognized: return "questionmark.bubble.fill"
        }
    }

    @MainActor
    func title(_ model: AppModel) -> String {
        switch self {
        case .completed: return model.t("Done", "Hecho")
        case .partial: return model.t("Partly done", "Parcialmente hecho")
        case .failed: return model.t("Failed", "Falló")
        case .permissionRequired: return model.t("Permission needed", "Se necesita permiso")
        case .needsConfirmation: return model.t("Please confirm", "Confirma, por favor")
        case .needsClarification: return model.t("Which one?", "¿Cuál?")
        case .setupRequired: return model.t("Setup needed", "Falta configuración")
        case .unavailable: return model.t("Not available", "No disponible")
        case .unsupported: return model.t("Not supported", "No compatible")
        case .duplicate: return model.t("Skipped duplicate", "Duplicado omitido")
        case .cancelled: return model.t("Cancelled", "Cancelado")
        case .reply: return "Jarvis"
        case .unrecognized: return model.t("Not understood", "No entendido")
        }
    }
}

// MARK: - Message rows

struct MessageRow: View {
    @Environment(AppModel.self) private var model
    let message: ChatMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if message.showsUserBubble {
                HStack {
                    Spacer(minLength: 60)
                    Text(message.text)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(red: 0.16, green: 0.30, blue: 0.82), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .foregroundStyle(.white)
                        .contextMenu {
                            Button(model.t("Copy", "Copiar")) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(message.text, forType: .string)
                            }
                            Button(model.t("Edit in input", "Editar en el campo")) {
                                model.input = message.text
                                model.requestFocus()
                            }
                        }
                }
            }
            HStack(alignment: .top) {
                ResponseCard(message: message)
                Spacer(minLength: 40)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

struct ResponseCard: View {
    @Environment(AppModel.self) private var model
    let message: ChatMessage

    var body: some View {
        switch message.phase {
        case .interpreting:
            card(tone: .neutral) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.t("Working on it…", "Trabajando en ello…")).foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    stopButton
                }
            }
        case .running(let steps):
            card(tone: .neutral) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(model.t("Executing", "Ejecutando")).font(.headline)
                        Spacer()
                        stopButton
                    }
                    ForEach(steps) { step in
                        HStack(spacing: 8) {
                            stepIcon(step.state)
                            Text(step.title)
                            Spacer()
                        }
                        .font(.callout)
                    }
                }
            }
        case .finished(let response):
            FinishedResponse(message: message, response: response)
        }
    }

    private var stopButton: some View {
        Button {
            model.cancel(message.id)
        } label: {
            Label(model.t("Stop", "Detener"), systemImage: "stop.circle")
        }
        .buttonStyle(.borderless)
        .help(model.t("Cancel this command", "Cancelar este comando"))
    }

    @ViewBuilder
    private func stepIcon(_ state: StepInfo.State) -> some View {
        switch state {
        case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
        case .running: ProgressView().controlSize(.mini)
        case .finished(let status): Image(systemName: status.symbol).foregroundStyle(status.color)
        }
    }

    private func card<Content: View>(tone: ResponseTone, @ViewBuilder content: () -> Content) -> some View {
        ResponseCardChrome(tone: tone, content: content)
    }
}

/// The rounded container shared by every response state.
struct ResponseCardChrome<Content: View>: View {
    let tone: ResponseTone
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: 560, alignment: .leading)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(tone.color.opacity(tone == .neutral ? 0.25 : 0.9)).frame(width: 3).padding(.vertical, 8).padding(.leading, 2)
            }
    }
}

// MARK: - Finished responses

struct FinishedResponse: View {
    @Environment(AppModel.self) private var model
    let message: ChatMessage
    let response: EngineResponse

    var body: some View {
        let tone = ResponseTone(status: response.status)
        ResponseCardChrome(tone: tone) {
            VStack(alignment: .leading, spacing: 8) {
                if response.status != .reply {
                    Label {
                        Text(response.status.title(model)).font(.headline)
                    } icon: {
                        Image(systemName: response.status.symbol).foregroundStyle(tone.color)
                    }
                }
                body(for: response)
                actions
            }
        }
    }

    @ViewBuilder
    private func body(for response: EngineResponse) -> some View {
        if response.results.count > 1 {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(response.results) { result in
                    ResultRow(message: message, result: result)
                }
                let extra = trailingNotes(response)
                if !extra.isEmpty { Text(extra).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            }
        } else if let only = response.results.first {
            SingleResult(message: message, result: only, fallback: response.message)
        } else {
            Text(response.message).textSelection(.enabled)
        }
    }

    /// Text added by the interpreter about parts it did not understand (after the per-step lines).
    private func trailingNotes(_ response: EngineResponse) -> String {
        let used = response.results.map(\.message).joined(separator: "\n")
        var message = response.message
        if message.hasPrefix(used) { message.removeFirst(used.count) }
        return message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @ViewBuilder
    private var actions: some View {
        let permissionIssue = response.results.compactMap(\.permission).first
        if let permission = permissionIssue {
            HStack {
                Button(model.t("Open Privacy Settings", "Abrir ajustes de privacidad")) { model.openSystemSettings(permission.settingsURL) }
                Button(model.t("Try again", "Reintentar")) { model.retry(message) }
            }
            .buttonStyle(.bordered)
            Text(permission.rationale.resolved(model.language)).font(.caption).foregroundStyle(.secondary)
        } else if response.status == .failed || response.status == .partial {
            Button(model.t("Try again", "Reintentar")) { model.retry(message) }.buttonStyle(.borderless).font(.callout)
        }
    }
}

struct SingleResult: View {
    @Environment(AppModel.self) private var model
    let message: ChatMessage
    let result: ToolResult
    let fallback: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(fallback).textSelection(.enabled)
            ResultExtras(message: message, result: result)
        }
    }
}

struct ResultRow: View {
    @Environment(AppModel.self) private var model
    let message: ChatMessage
    let result: ToolResult

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: result.status.symbol).foregroundStyle(result.status.color).frame(width: 18)
            VStack(alignment: .leading, spacing: 6) {
                Text(result.message).textSelection(.enabled)
                ResultExtras(message: message, result: result)
            }
        }
    }
}

/// Verification badge, assumptions, warnings and the interactive parts (confirm / choose / setup steps).
struct ResultExtras: View {
    @Environment(AppModel.self) private var model
    let message: ChatMessage
    let result: ToolResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if result.status == .completed { verification }
            ForEach(result.assumptions, id: \.self) { assumption in
                Label(assumption, systemImage: "lightbulb").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(result.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            if let confirmation = result.confirmation, let token = confirmation.token, !message.resolvedTokens.contains(token) {
                HStack {
                    Button(role: confirmation.destructive ? .destructive : nil) {
                        model.resolve(in: message, token: token, decision: .confirm, label: model.t("Confirm", "Confirmar"))
                    } label: {
                        Text(confirmation.destructive ? model.t("Delete", "Eliminar") : model.t("Confirm", "Confirmar"))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(confirmation.destructive ? .red : .accentColor)
                    Button(model.t("Cancel", "Cancelar")) {
                        model.resolve(in: message, token: token, decision: .cancel, label: model.t("Cancel", "Cancelar"))
                    }
                    .keyboardShortcut(.cancelAction)
                }
            }
            if let clarification = result.clarification, let token = clarification.token, !message.resolvedTokens.contains(token) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(clarification.options.enumerated()), id: \.offset) { index, option in
                        Button {
                            model.resolve(in: message, token: token, decision: .choose(index), label: option.label)
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(index + 1). \(option.label)")
                                if let detail = option.detail {
                                    Text(detail).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                    }
                    Button(model.t("None of these", "Ninguna")) {
                        model.resolve(in: message, token: token, decision: .cancel, label: model.t("None of these", "Ninguna"))
                    }
                    .buttonStyle(.borderless)
                }
            }
            if let setup = result.setup {
                DisclosureGroup(setup.title) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(setup.steps.enumerated()), id: \.offset) { _, step in
                            Text(step).font(.caption).textSelection(.enabled)
                        }
                        Button(model.t("Open Shortcuts", "Abrir Atajos")) { model.openShortcutsApp() }.padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                }
                .font(.callout)
            }
        }
    }

    @ViewBuilder
    private var verification: some View {
        switch result.verification {
        case .verified(let detail):
            Label(model.t("Verified", "Verificado"), systemImage: "checkmark.seal.fill").font(.caption).foregroundStyle(.green).help(detail)
        case .unverified(let reason):
            Label(model.t("Done, not verified", "Hecho, sin verificar"), systemImage: "exclamationmark.shield").font(.caption).foregroundStyle(.orange).help(reason)
        case .notApplicable:
            EmptyView()
        }
    }
}
