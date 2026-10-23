import Foundation

/// A problem found while validating a tool call against its descriptor.
public struct ValidationIssue: Sendable, Hashable, Codable, Error {
    public enum Code: String, Codable, Sendable {
        case unknownTool = "unknown_tool"
        case unsupportedTool = "unsupported_tool"
        case missingRequired = "missing_required"
        case unknownParameter = "unknown_parameter"
        case wrongType = "wrong_type"
        case outOfRange = "out_of_range"
        case invalidValue = "invalid_value"
        case constraintViolated = "constraint_violated"
        case tooLong = "too_long"
    }

    public let code: Code
    public let parameter: String?
    public let detail: String

    public init(_ code: Code, parameter: String? = nil, _ detail: String) {
        self.code = code
        self.parameter = parameter
        self.detail = detail
    }
}

/// Typed errors thrown by integrations and the engine. The engine converts them into ``ToolResult`` values.
public enum JarvisError: Error, Sendable, Hashable {
    case validation([ValidationIssue])
    /// The thing the user referred to does not exist (list, playlist, note, event…).
    case notFound(code: String, LocalizedText)
    /// A parameter is syntactically valid but semantically unusable.
    case invalidArgument(parameter: String, LocalizedText)
    /// The capability does not exist in public Apple interfaces.
    case unsupported(LocalizedText, alternative: LocalizedText?)
    case permissionRequired(PermissionRequirement)
    /// The target application is not installed or cannot run.
    case unavailable(LocalizedText)
    case setupRequired(SetupInstructions, LocalizedText)
    /// The action ran but reading the result back showed it did not take effect.
    case verificationFailed(LocalizedText)
    case failed(code: String, LocalizedText)
    case timedOut(seconds: Double)
    case cancelled

    public var resultStatus: ToolResult.Status {
        switch self {
        case .validation, .notFound, .invalidArgument, .verificationFailed, .failed, .timedOut: return .failed
        case .unsupported: return .unsupported
        case .permissionRequired: return .permissionRequired
        case .unavailable: return .unavailable
        case .setupRequired: return .setupRequired
        case .cancelled: return .cancelled
        }
    }

    public var code: String {
        switch self {
        case .validation(let issues): return issues.first?.code.rawValue ?? "validation_failed"
        case .notFound(let code, _): return code
        case .invalidArgument: return "invalid_argument"
        case .unsupported: return "unsupported"
        case .permissionRequired: return "permission_required"
        case .unavailable: return "unavailable"
        case .setupRequired: return "setup_required"
        case .verificationFailed: return "verification_failed"
        case .failed(let code, _): return code
        case .timedOut: return "timeout"
        case .cancelled: return "cancelled"
        }
    }

    /// Short convenience for the most common failure shape.
    public static func failed(_ code: String, en: String, es: String) -> JarvisError {
        .failed(code: code, LocalizedText(en: en, es: es))
    }

    public static func notFound(_ code: String, en: String, es: String) -> JarvisError {
        .notFound(code: code, LocalizedText(en: en, es: es))
    }

    public func message(in language: Language) -> String {
        switch self {
        case .validation(let issues):
            let details = issues.map(\.detail).joined(separator: "; ")
            return language.pick("The request is not valid: \(details)", "La solicitud no es válida: \(details)")
        case .notFound(_, let text), .invalidArgument(_, let text), .unavailable(let text),
             .verificationFailed(let text), .failed(_, let text), .setupRequired(_, let text):
            return text.resolved(language)
        case .unsupported(let text, let alternative):
            guard let alternative else { return text.resolved(language) }
            return text.resolved(language) + " " + alternative.resolved(language)
        case .permissionRequired(let requirement):
            return language.pick(
                "Jarvis needs permission: \(requirement.title.en). \(requirement.rationale.en)",
                "Jarvis necesita permiso: \(requirement.title.es). \(requirement.rationale.es)"
            )
        case .timedOut(let seconds):
            let rounded = Int(seconds.rounded())
            return language.pick(
                "The action did not finish within \(rounded) seconds and was stopped.",
                "La acción no terminó en \(rounded) segundos y se detuvo."
            )
        case .cancelled:
            return language.pick("The action was cancelled.", "La acción se canceló.")
        }
    }
}
