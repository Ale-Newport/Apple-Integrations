import Foundation
import JarvisCore

/// One clause of the user's command, ready for the domain rule sets.
struct Clause: Sendable {
    /// Quote/payload-masked text with politeness stripped.
    let text: FoldedText
    let context: DateContext

    var folded: String { text.folded }
    var language: Language { context.language }
    var settings: JarvisSettings { context.settings }

    /// The clause with date/time phrases cut out (computed once per rule that needs it).
    func parseDates(allowBareDuration: Bool = false) -> (when: ParsedWhen, remainder: FoldedText) {
        let when = NaturalDateParser().parse(text, context: context, allowBareDuration: allowBareDuration)
        return (when, text.removing(when.consumed))
    }
}

/// What a rule concluded about a clause.
enum RuleResult: Sendable {
    /// Understood: run these calls. `confidence` ranks competing rule sets (0…1).
    case calls([ToolCall], confidence: Double)
    /// Understood the intent but information is missing.
    case clarify(LocalizedText, confidence: Double)
    /// A conversational answer.
    case reply(LocalizedText, confidence: Double)

    var confidence: Double {
        switch self {
        case .calls(_, let value), .clarify(_, let value), .reply(_, let value): return value
        }
    }
}

/// A group of rules for one area. Adding a new integration adds a rule set; the interpreter core does not change.
protocol IntentRuleSet: Sendable {
    func interpret(_ clause: Clause) -> [RuleResult]
}

// MARK: - Regex helpers

enum Rx {
    /// A lone hour such as "4" or "4:30" (used for "move my meeting to 4").
    static let bareHour = make(#"^(?:the\s+|las?\s+)?(?:1[0-2]|0?[1-9])(?::[0-5]\d)?$"#)

    /// Compiles a pattern once. Patterns are developer-controlled constants, so failure is a programming error.
    static func make(_ pattern: String, caseInsensitive: Bool = false) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
        } catch {
            preconditionFailure("Invalid rule pattern: \(pattern)\n\(error)")
        }
    }
}

extension Clause {
    /// Full-string match of `regex` against the folded clause, returning the named groups as original-case text.
    func whole(_ regex: NSRegularExpression, groups: [String]) -> MatchedClause? {
        guard let match = text.firstMatch(regex, groupNames: groups), match.range == 0..<text.count else { return nil }
        return MatchedClause(text: text, match: match)
    }

    func find(_ regex: NSRegularExpression, groups: [String] = []) -> MatchedClause? {
        guard let match = text.firstMatch(regex, groupNames: groups) else { return nil }
        return MatchedClause(text: text, match: match)
    }
}

struct MatchedClause: Sendable {
    let text: FoldedText
    let match: FoldedText.Match

    var range: Range<Int> { match.range }

    func range(_ name: String) -> Range<Int>? { match.group(name) }

    /// The user's own spelling of a group, with surrounding quotes removed.
    func original(_ name: String) -> String? {
        guard let range = match.group(name) else { return nil }
        let value = FoldedText.unquote(text.original(range))
        return value.isEmpty ? nil : value
    }

    func folded(_ name: String) -> String? {
        guard let range = match.group(name) else { return nil }
        return text.foldedSlice(range)
    }
}

// MARK: - Text cleanup

enum TextCleanup {
    /// Trims, drops trailing punctuation, removes wrapping quotes and capitalises the first letter
    /// ("buy milk." → "Buy milk"). Mixed-case input such as "iPhone case" keeps its shape.
    static func title(_ raw: String) -> String {
        var text = unwrapQuotedName(raw) ?? FoldedText.unquote(raw)
        text = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;:-–—")))
        while let last = text.last, ".!?,;:".contains(last) { text.removeLast() }
        text = text.trimmingCharacters(in: .whitespaces)
        return capitalizeFirst(text)
    }

    static func capitalizeFirst(_ text: String) -> String {
        guard let first = text.first, first.isLowercase else { return text }
        return first.uppercased() + text.dropFirst()
    }

    /// Cleans a name extracted by a pattern: unquotes, trims and drops trailing punctuation. Determiners are
    /// consumed by the patterns themselves, so names such as "The Beatles" or "The Gym" keep their article.
    static func name(_ raw: String) -> String {
        var text = (unwrapQuotedName(raw) ?? FoldedText.unquote(raw)).trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = text.last, ".!?,;:".contains(last) { text.removeLast() }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let quotedSpan = #"(?:"[^"\n]+"|\x{201C}[^\x{201D}\n]+\x{201D}|\x{00AB}[^\x{00BB}\n]+\x{00BB})"#
    private static let nounThenQuote = Rx.make(#"^(?:(?:the|my|our|el|la|mi)\s+)?(?<noun>\p{L}+)\s+(?<name>\#(quotedSpan))$"#, caseInsensitive: true)
    private static let quoteThenNoun = Rx.make(#"^(?<name>\#(quotedSpan))\s+(?<noun>\p{L}+)$"#, caseInsensitive: true)
    /// Words that only say *what kind of thing* a quoted name belongs to ("the event “Dentist”", "cita «Dentista»").
    private static let structuralNouns: Set<String> = [
        "appointment", "appointments", "event", "events", "meeting", "meetings", "reminder", "reminders", "note", "notes", "task", "tasks",
        "list", "playlist", "calendar", "folder", "alarm", "timer", "song", "track", "album", "artist", "class", "lecture",
        "cita", "citas", "evento", "eventos", "reunion", "reuniones", "recordatorio", "recordatorios", "nota", "notas", "tarea", "tareas",
        "lista", "carpeta", "calendario", "alarma", "temporizador", "cancion", "tema", "artista", "clase",
    ]

    /// `event "Dentist"`, `"Dentist" appointment`, `cita «Dentista»` → `Dentist` / `Dentista`: when the name is quoted, the
    /// word next to the quotes only says what it is and is not part of the name. Anything else returns `nil`.
    static func unwrapQuotedName(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(text.startIndex..., in: text)
        for regex in [nounThenQuote, quoteThenNoun] {
            guard let match = regex.firstMatch(in: text, range: range), match.range == range,
                  let nounRange = Range(match.range(withName: "noun"), in: text), let nameRange = Range(match.range(withName: "name"), in: text),
                  structuralNouns.contains(TextFolding.fold(String(text[nounRange]))) else { continue }
            let inner = FoldedText.unquote(String(text[nameRange]))
            return inner.isEmpty ? nil : inner
        }
        return nil
    }

    /// Strips dangling connector words left behind after cutting date phrases out of a clause.
    static func trimConnectors(_ clause: FoldedText) -> FoldedText {
        var current = clause.collapsedWhitespace()
        // Leading connectors.
        if let match = current.firstMatch(DateLexicon.leadingConnectors), match.range.lowerBound == 0, match.range.upperBound < current.count {
            current = current.removing([match.range])
        }
        // Trailing connectors.
        if let match = current.firstMatch(DateLexicon.danglingConnectors), match.range.upperBound == current.count, match.range.lowerBound > 0 {
            current = current.removing([match.range])
        }
        return current
    }
}
