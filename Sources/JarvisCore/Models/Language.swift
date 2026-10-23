import Foundation

/// Languages understood by the deterministic interpreter and used for user-facing responses.
public enum Language: String, Codable, Sendable, CaseIterable, Hashable {
    case en
    case es

    public var locale: Locale {
        switch self {
        case .en: return Locale(identifier: "en_US")
        case .es: return Locale(identifier: "es_ES")
        }
    }

    public var displayName: String {
        switch self {
        case .en: return "English"
        case .es: return "Español"
        }
    }

    /// Picks the string for this language. Both arguments are lazy so only the chosen one is built.
    public func pick(_ english: @autoclosure () -> String, _ spanish: @autoclosure () -> String) -> String {
        self == .es ? spanish() : english()
    }

    /// Parses `"en"`, `"es"`, `"en-US"`, `"es_MX"`, `"English"`, `"español"` … Returns `nil` for anything else.
    public init?(hint: String?) {
        guard let raw = hint?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else { return nil }
        if raw.hasPrefix("en") { self = .en; return }
        if raw.hasPrefix("es") || raw.hasPrefix("spa") || raw.hasPrefix("esp") { self = .es; return }
        return nil
    }
}

/// A message available in every supported language. Used where an error is created far away from the
/// request that triggered it, so the final text can still be rendered in the user's language.
public struct LocalizedText: Sendable, Hashable, Codable {
    public var en: String
    public var es: String

    public init(en: String, es: String) {
        self.en = en
        self.es = es
    }

    public init(_ both: String) {
        self.en = both
        self.es = both
    }

    public func resolved(_ language: Language) -> String { language == .es ? es : en }
}

/// User preference for the interface/response language.
public enum LanguagePreference: String, Codable, Sendable, CaseIterable, Hashable {
    case automatic
    case english
    case spanish

    public var fixedLanguage: Language? {
        switch self {
        case .automatic: return nil
        case .english: return .en
        case .spanish: return .es
        }
    }
}
