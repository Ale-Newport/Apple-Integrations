import Foundation
import JarvisCore

/// One step of a running command as shown in the UI.
struct StepInfo: Identifiable, Equatable {
    enum State: Equatable {
        case pending
        case running
        case finished(ToolResult.Status)
    }

    let id: UUID
    let tool: ToolName
    var title: String
    var state: State
}

/// One exchange in the conversation: what the user typed and what Jarvis made of it.
struct ChatMessage: Identifiable, Equatable {
    enum Phase: Equatable {
        case interpreting
        case running([StepInfo])
        case finished(EngineResponse)
    }

    let id: UUID
    var text: String
    let date: Date
    var phase: Phase
    /// Confirmation / clarification tokens already answered, so their buttons disappear.
    var resolvedTokens: Set<String> = []
    /// `false` for follow-up answers ("Confirmed") that continue an earlier message and have no user bubble.
    var showsUserBubble = true

    var response: EngineResponse? {
        if case .finished(let response) = phase { return response }
        return nil
    }

    var isRunning: Bool {
        switch phase {
        case .interpreting, .running: return true
        case .finished: return false
        }
    }
}

/// Sidebar destinations.
enum SidebarItem: Hashable {
    case chat
    case history
    case integration(IntegrationID)
}

/// Visual style of a finished response.
enum ResponseTone {
    case success, failure, warning, neutral, info

    init(status: EngineResponse.Status) {
        switch status {
        case .completed, .reply: self = .success
        case .failed: self = .failure
        case .partial, .permissionRequired, .needsConfirmation, .needsClarification, .setupRequired: self = .warning
        case .unavailable, .unsupported, .duplicate, .cancelled: self = .neutral
        case .unrecognized: self = .info
        }
    }
}
