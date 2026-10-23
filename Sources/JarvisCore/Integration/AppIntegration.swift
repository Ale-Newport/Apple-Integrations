import Foundation

/// What an integration returns from ``AppIntegration/execute(_:context:)``.
public enum ToolOutcome: Sendable {
    /// The tool ran and its effect was verified (or explicitly marked unverified).
    case done(ToolOutput)
    /// Nothing was changed yet; the engine must ask the user before running `request.call`.
    case confirm(ConfirmationRequest)
    /// The request matched several things; the user must choose.
    case clarify(Clarification)
}

/// Result of a permission check for one tool.
public enum AuthorizationState: Sendable, Hashable {
    case authorized
    /// The user has not been asked yet. ``AppIntegration/requestAuthorization(for:)`` shows the system prompt.
    case notDetermined(PermissionRequirement)
    case denied(PermissionRequirement)
    /// Blocked by a profile / parental controls; the user cannot change it in System Settings.
    case restricted(PermissionRequirement)
    /// The target app is missing or the capability does not exist on this Mac.
    case unavailable(LocalizedText)

    public var isAuthorized: Bool { if case .authorized = self { return true } else { return false } }
}

/// Aggregate state of an integration, shown in the sidebar and Settings. Computing it never shows a prompt.
public struct IntegrationStatus: Sendable, Hashable {
    public enum State: String, Sendable, Hashable {
        case ready
        case needsPermission
        case denied
        case restricted
        case needsSetup
        case unavailable
    }

    public struct PermissionEntry: Sendable, Hashable, Identifiable {
        public var requirement: PermissionRequirement
        public var state: AuthorizationState
        public var id: String { requirement.id }

        public init(requirement: PermissionRequirement, state: AuthorizationState) {
            self.requirement = requirement
            self.state = state
        }
    }

    public var state: State
    public var detail: LocalizedText?
    public var permissions: [PermissionEntry]

    public init(state: State, detail: LocalizedText? = nil, permissions: [PermissionEntry] = []) {
        self.state = state
        self.detail = detail
        self.permissions = permissions
    }
}

/// The contract every Apple application integration implements.
///
/// * **Discovery** – ``tools`` and ``permissionRequirements`` describe what the integration can do and needs.
/// * **Authorization** – ``authorization(for:)`` / ``requestAuthorization(for:)`` wrap the platform's permission model.
/// * **Execution** – ``execute(_:context:)`` runs a validated call and returns a verified outcome.
/// * **Error handling** – failures are thrown as ``JarvisError``; the engine renders them in the user's language.
///
/// Adding a new integration means adding a type that conforms to this protocol and listing it where the
/// registry is built; the engine, registry and interpreter pipeline do not change.
public protocol AppIntegration: Sendable {
    var id: IntegrationID { get }
    var displayName: LocalizedText { get }
    var summary: LocalizedText { get }
    /// An SF Symbol name used by the UI.
    var symbolName: String { get }

    var tools: [ToolDescriptor] { get }
    var permissionRequirements: [PermissionRequirement] { get }

    /// Summarises availability and permissions without prompting the user.
    func status() async -> IntegrationStatus

    /// Current authorization for one tool, without prompting.
    func authorization(for tool: ToolDescriptor) async -> AuthorizationState

    /// Asks the system for access when the state is `notDetermined`. May suspend until the user answers.
    func requestAuthorization(for tool: ToolDescriptor) async -> AuthorizationState

    /// Runs one validated call. Implementations must verify their effect before returning `.done`
    /// and must honour task cancellation.
    func execute(_ call: ValidatedToolCall, context: ExecutionContext) async throws -> ToolOutcome
}
