import Foundation

/// Case- and diacritic-insensitive text helpers shared by the interpreter and the integrations.
public enum TextFolding {
    /// Folds one character to its lowercase, diacritic-free form. The result is always exactly one
    /// `Character`, which keeps folded text index-aligned with the original (see `FoldedText`).
    public static func fold(_ character: Character) -> Character {
        if character.isASCII {
            return Character(character.lowercased())
        }
        // Decompose and drop combining marks (é → e, ñ → n, ü → u).
        let decomposed = String(character).decomposedStringWithCanonicalMapping.lowercased()
        let base = decomposed.unicodeScalars.filter { !$0.properties.isDiacritic && $0.properties.generalCategory != .nonspacingMark }
        var result = String.UnicodeScalarView()
        result.append(contentsOf: base)
        let text = String(result)
        if let first = text.first, text.count == 1 { return first }
        // Ligatures / special cases (ß, æ, …): keep the first folded character to preserve alignment.
        if let first = text.first { return first }
        return character
    }

    /// Lowercases, removes diacritics, normalises quotes/dashes and collapses runs of whitespace.
    public static func fold(_ text: String) -> String {
        var output = ""
        output.reserveCapacity(text.count)
        var previousWasSpace = true
        for character in text {
            let mapped = normalizeTypography(fold(character))
            if mapped.isWhitespace {
                if !previousWasSpace { output.append(" ") }
                previousWasSpace = true
            } else {
                output.append(mapped)
                previousWasSpace = false
            }
        }
        if output.hasSuffix(" ") { output.removeLast() }
        return output
    }

    /// Replaces typographic quotes and dashes with ASCII equivalents (single `Character` → single `Character`).
    public static func normalizeTypography(_ character: Character) -> Character {
        switch character {
        case "\u{2018}", "\u{2019}", "\u{201B}", "\u{02BC}": return "'"
        case "\u{201C}", "\u{201D}", "\u{201F}": return "\""
        case "\u{2013}", "\u{2014}", "\u{2212}": return "-"
        case "\u{00A0}", "\u{2009}", "\u{202F}": return " "
        default: return character
        }
    }

    /// Splits folded text into alphanumeric word tokens.
    public static func tokens(_ text: String) -> [String] {
        fold(text).split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
    }
}

/// Scores how well a user-supplied name matches a candidate name (list, playlist, note, event title…).
public enum NameMatcher {
    public struct Match<Item> {
        public let item: Item
        public let score: Int
    }

    /// Generic words people add around names ("my Shopping *list*", "la lista *de* Compras").
    private static let fillerWords: Set<String> = [
        "my", "the", "a", "an", "list", "playlist", "note", "folder", "reminders", "reminder", "calendar",
        "mi", "mis", "la", "el", "los", "las", "un", "una", "lista", "nota", "carpeta", "recordatorios", "recordatorio",
        "calendario", "de", "del", "of"
    ]

    /// 0 = no match, 100 = identical, lower scores are progressively looser matches.
    public static func score(query: String, candidate: String) -> Int {
        let q = TextFolding.fold(query)
        let c = TextFolding.fold(candidate)
        guard !q.isEmpty, !c.isEmpty else { return 0 }
        if q == c { return 100 }

        let qTokens = TextFolding.tokens(q)
        let cTokens = TextFolding.tokens(c)
        let qCore = qTokens.filter { !fillerWords.contains($0) }
        let cCore = cTokens.filter { !fillerWords.contains($0) }
        if !qCore.isEmpty, qCore == cCore { return 95 }
        if c.hasPrefix(q + " ") || (q.count >= 3 && c.hasPrefix(q)) { return 85 }
        if !qCore.isEmpty, cCore.starts(with: qCore) { return 82 }
        if c.contains(" " + q + " ") || c.hasSuffix(" " + q) { return 75 }
        if q.count >= 3, c.contains(q) { return 65 }
        if !qCore.isEmpty, qCore.allSatisfy({ token in cTokens.contains(where: { $0 == token }) }) { return 60 }
        if !qCore.isEmpty, qCore.allSatisfy({ token in token.count >= 3 && cTokens.contains(where: { $0.hasPrefix(token) }) }) { return 50 }
        // A query that merely adds filler words around the candidate ("shopping list" vs "Shopping").
        if !cCore.isEmpty, cCore.allSatisfy({ qTokens.contains($0) }), qCore.count <= cCore.count + 1 { return 70 }
        return 0
    }

    /// Returns candidates that match, best first. Ties keep the original order.
    public static func rank<Item>(_ items: [Item], query: String, minimumScore: Int = 50, name: (Item) -> String) -> [Match<Item>] {
        var scored: [(offset: Int, match: Match<Item>)] = []
        for (offset, item) in items.enumerated() {
            let value = score(query: query, candidate: name(item))
            if value >= minimumScore {
                scored.append((offset, Match(item: item, score: value)))
            }
        }
        scored.sort { left, right in
            if left.match.score != right.match.score { return left.match.score > right.match.score }
            return left.offset < right.offset
        }
        return scored.map { $0.match }
    }

    /// The matches that share the best score, or an empty array. More than one element means ambiguity.
    public static func bestMatches<Item>(_ items: [Item], query: String, minimumScore: Int = 50, name: (Item) -> String) -> [Item] {
        let ranked = rank(items, query: query, minimumScore: minimumScore, name: name)
        guard let top = ranked.first?.score else { return [] }
        return ranked.filter { $0.score == top }.map(\.item)
    }
}
