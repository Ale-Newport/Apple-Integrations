import Foundation
import JarvisCore

/// User text prepared for pattern matching.
///
/// `folded` is lowercase, free of diacritics and typographic quirks, and has **exactly one character per
/// original character**. That 1:1 alignment lets the rules run case/accent-insensitive regular expressions
/// on `folded` while extracting the user's *original* spelling (`original(_:)`) for titles, names and
/// note content. Quoted text and free-form payloads are *masked* in `folded` so that keywords inside them
/// (for example a note that says "remind me tomorrow") are never mistaken for commands.
struct FoldedText: Sendable, Hashable {
    static let maskCharacter: Character = "\u{E000}"

    let originalCharacters: [Character]
    let foldedCharacters: [Character]
    /// Character offsets (into `originalCharacters`) of the UTF-16 code units of `folded`.
    private let utf16ToCharacter: [Int]
    let folded: String

    var count: Int { originalCharacters.count }
    var isEmpty: Bool { originalCharacters.isEmpty }
    var original: String { String(originalCharacters) }

    init(_ text: String, masks: [Range<Int>] = []) {
        var originals = Array(text)
        // Normalise line breaks and tabs to plain characters so patterns can use \s.
        for index in originals.indices where originals[index] == "\r\n" { originals[index] = "\n" }
        var foldedChars = originals.map { TextFolding.normalizeTypography(TextFolding.fold($0)) }
        for range in masks {
            for index in range where foldedChars.indices.contains(index) {
                foldedChars[index] = Self.maskCharacter
            }
        }
        self.init(originalCharacters: originals, foldedCharacters: foldedChars)
    }

    private init(originalCharacters: [Character], foldedCharacters: [Character]) {
        self.originalCharacters = originalCharacters
        self.foldedCharacters = foldedCharacters
        self.folded = String(foldedCharacters)
        var map: [Int] = []
        map.reserveCapacity(foldedCharacters.count + 1)
        for (index, character) in foldedCharacters.enumerated() {
            for _ in 0..<String(character).utf16.count { map.append(index) }
        }
        map.append(foldedCharacters.count)
        self.utf16ToCharacter = map
    }

    // MARK: Slicing

    func original(_ range: Range<Int>) -> String {
        guard let clamped = clamp(range) else { return "" }
        return String(originalCharacters[clamped])
    }

    func foldedSlice(_ range: Range<Int>) -> String {
        guard let clamped = clamp(range) else { return "" }
        return String(foldedCharacters[clamped])
    }

    func slice(_ range: Range<Int>) -> FoldedText {
        guard let clamped = clamp(range) else { return FoldedText("") }
        return FoldedText(originalCharacters: Array(originalCharacters[clamped]), foldedCharacters: Array(foldedCharacters[clamped]))
    }

    /// Removes character ranges and re-compacts whitespace. Used to take date phrases out of a clause.
    func removing(_ ranges: [Range<Int>]) -> FoldedText {
        guard !ranges.isEmpty else { return self.trimmed() }
        var keep = [Bool](repeating: true, count: count)
        for range in ranges {
            guard let clamped = clamp(range) else { continue }
            for index in clamped { keep[index] = false }
        }
        var originals: [Character] = []
        var foldeds: [Character] = []
        for index in 0..<count where keep[index] {
            originals.append(originalCharacters[index])
            foldeds.append(foldedCharacters[index])
        }
        return FoldedText(originalCharacters: originals, foldedCharacters: foldeds).collapsedWhitespace()
    }

    func trimmed() -> FoldedText { collapsedWhitespace() }

    /// Collapses runs of spaces and trims both ends (newlines inside masked payloads are preserved because the
    /// folded form of a masked character is not whitespace).
    func collapsedWhitespace() -> FoldedText {
        var originals: [Character] = []
        var foldeds: [Character] = []
        var previousSpace = true
        for index in 0..<count {
            let folded = foldedCharacters[index]
            if folded == " " || folded == "\t" {
                if previousSpace { continue }
                previousSpace = true
                originals.append(" ")
                foldeds.append(" ")
            } else {
                previousSpace = false
                originals.append(originalCharacters[index])
                foldeds.append(folded)
            }
        }
        while let last = foldeds.last, last == " " || last == "\n" {
            foldeds.removeLast()
            originals.removeLast()
        }
        while let first = foldeds.first, first == " " || first == "\n" {
            foldeds.removeFirst()
            originals.removeFirst()
        }
        return FoldedText(originalCharacters: originals, foldedCharacters: foldeds)
    }

    // MARK: Regular expressions

    struct Match: Sendable {
        let range: Range<Int>
        private let groups: [String: Range<Int>]
        private let numbered: [Range<Int>?]

        fileprivate init(range: Range<Int>, groups: [String: Range<Int>], numbered: [Range<Int>?]) {
            self.range = range
            self.groups = groups
            self.numbered = numbered
        }

        func group(_ name: String) -> Range<Int>? { groups[name] }
        func group(_ index: Int) -> Range<Int>? { index < numbered.count ? numbered[index] : nil }
    }

    func firstMatch(_ regex: NSRegularExpression, from start: Int = 0, groupNames: [String] = []) -> Match? {
        matches(regex, from: start, groupNames: groupNames, limit: 1).first
    }

    func matches(_ regex: NSRegularExpression, from start: Int = 0, groupNames: [String] = [], limit: Int = .max) -> [Match] {
        let nsText = folded as NSString
        let startUTF16: Int = {
            guard start > 0 else { return 0 }
            var offset = 0
            for index in 0..<min(start, foldedCharacters.count) { offset += String(foldedCharacters[index]).utf16.count }
            return offset
        }()
        guard startUTF16 <= nsText.length else { return [] }
        let searchRange = NSRange(location: startUTF16, length: nsText.length - startUTF16)
        var output: [Match] = []
        regex.enumerateMatches(in: folded, options: [], range: searchRange) { result, _, stop in
            guard let result else { return }
            guard let whole = characterRange(for: result.range) else { return }
            var named: [String: Range<Int>] = [:]
            for name in groupNames {
                let nsRange = result.range(withName: name)
                if nsRange.location != NSNotFound, let converted = characterRange(for: nsRange) { named[name] = converted }
            }
            var numbered: [Range<Int>?] = []
            for index in 0..<result.numberOfRanges {
                let nsRange = result.range(at: index)
                numbered.append(nsRange.location == NSNotFound ? nil : characterRange(for: nsRange))
            }
            output.append(Match(range: whole, groups: named, numbered: numbered))
            if output.count >= limit { stop.pointee = true }
        }
        return output
    }

    /// Like ``firstMatch(_:from:groupNames:)`` but runs on the *original* spelling, so patterns can use
    /// `\\p{Lu}` to find capitalised names and places ("with Daniel", "at Starbucks").
    func firstMatchInOriginal(_ regex: NSRegularExpression, groupNames: [String] = []) -> Match? {
        let source = original
        var map: [Int] = []
        for (index, character) in originalCharacters.enumerated() {
            for _ in 0..<String(character).utf16.count { map.append(index) }
        }
        map.append(originalCharacters.count)
        func convert(_ nsRange: NSRange) -> Range<Int>? {
            guard nsRange.location != NSNotFound, nsRange.location + nsRange.length < map.count else { return nil }
            let start = map[nsRange.location]
            var end = map[nsRange.location + nsRange.length]
            if nsRange.length > 0, end == start { end = start + 1 }
            return start..<max(start, end)
        }
        let length = (source as NSString).length
        guard let result = regex.firstMatch(in: source, range: NSRange(location: 0, length: length)), let whole = convert(result.range) else { return nil }
        var named: [String: Range<Int>] = [:]
        for name in groupNames {
            let nsRange = result.range(withName: name)
            if let converted = convert(nsRange) { named[name] = converted }
        }
        return Match(range: whole, groups: named, numbered: [])
    }

    private func characterRange(for nsRange: NSRange) -> Range<Int>? {
        guard nsRange.location != NSNotFound else { return nil }
        let lower = nsRange.location
        let upper = nsRange.location + nsRange.length
        guard lower < utf16ToCharacter.count, upper < utf16ToCharacter.count else { return nil }
        let start = utf16ToCharacter[lower]
        var end = utf16ToCharacter[upper]
        if upper > lower, end == start { end = start + 1 }
        return start..<max(start, end)
    }

    private func clamp(_ range: Range<Int>) -> Range<Int>? {
        let lower = max(0, range.lowerBound)
        let upper = min(count, range.upperBound)
        return lower < upper ? lower..<upper : (lower == upper ? nil : nil)
    }

    // MARK: Masks

    /// Whether any character of `range` is masked.
    func isMasked(_ range: Range<Int>) -> Bool {
        guard let clamped = clamp(range) else { return false }
        return foldedCharacters[clamped].contains(Self.maskCharacter)
    }

    /// The contiguous masked stretches of the folded text (each quoted span, each payload).
    func maskedRuns() -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var start: Int?
        for (index, character) in foldedCharacters.enumerated() {
            if character == Self.maskCharacter {
                if start == nil { start = index }
            } else if let begin = start {
                runs.append(begin..<index)
                start = nil
            }
        }
        if let begin = start { runs.append(begin..<foldedCharacters.count) }
        return runs
    }

    /// Returns a copy in which `range` is visible again (the inverse of ``masking(_:)``): the rules then see the
    /// quoted words as ordinary text. Used when a quoted span is known to be a *name* rather than a payload.
    func unmasking(_ range: Range<Int>) -> FoldedText {
        guard let clamped = clamp(range) else { return self }
        var foldeds = foldedCharacters
        for index in clamped {
            foldeds[index] = TextFolding.normalizeTypography(TextFolding.fold(originalCharacters[index]))
        }
        return FoldedText(originalCharacters: originalCharacters, foldedCharacters: foldeds)
    }

    /// The same text with the folded form of `range` replaced by an equally long string, so the rules can read
    /// "for 7" as "at 7" without losing the alignment with the user's original spelling.
    func replacingFolded(_ range: Range<Int>, with replacement: String) -> FoldedText {
        guard let clamped = clamp(range), replacement.count == clamped.count else { return self }
        var foldeds = foldedCharacters
        for (offset, character) in replacement.enumerated() { foldeds[clamped.lowerBound + offset] = character }
        return FoldedText(originalCharacters: originalCharacters, foldedCharacters: foldeds)
    }

    /// Returns a copy in which `range` is masked in the folded form.
    func masking(_ range: Range<Int>) -> FoldedText {
        guard let clamped = clamp(range) else { return self }
        var foldeds = foldedCharacters
        for index in clamped { foldeds[index] = Self.maskCharacter }
        return FoldedText(originalCharacters: originalCharacters, foldedCharacters: foldeds)
    }
}

// MARK: - Quote handling

extension FoldedText {
    private static let quotePattern = try! NSRegularExpression(
        pattern: #""([^"\n]+)"|\x{201C}([^\x{201D}\n]+)\x{201D}|\x{00AB}([^\x{00BB}\n]+)\x{00BB}|(?<![\p{L}\p{N}])'([^'\n]{2,})'(?![\p{L}\p{N}])|(?<![\p{L}\p{N}])\x{2018}([^\x{2019}\n]{2,})\x{2019}(?![\p{L}\p{N}])"#
    )

    /// Builds a `FoldedText` where every quoted span is masked.
    static func withQuotesMasked(_ text: String) -> FoldedText {
        let base = FoldedText(text)
        // Quote detection runs on the *original* characters (typographic quotes are normalised in `folded`).
        let nsText = text as NSString
        var ranges: [Range<Int>] = []
        // Map UTF-16 → Character offsets of the original text.
        var map: [Int] = []
        for (index, character) in base.originalCharacters.enumerated() {
            for _ in 0..<String(character).utf16.count { map.append(index) }
        }
        map.append(base.originalCharacters.count)
        quotePattern.enumerateMatches(in: text, range: NSRange(location: 0, length: nsText.length)) { match, _, _ in
            guard let match, match.range.location + match.range.length < map.count else { return }
            let lower = map[match.range.location]
            let upper = map[match.range.location + match.range.length]
            if upper > lower { ranges.append(lower..<upper) }
        }
        return ranges.isEmpty ? base : FoldedText(text, masks: ranges)
    }

    /// If `text` is entirely wrapped in ONE matching pair of quotes, returns it without them.
    ///
    /// `"Hello" by "Adele"` starts and ends with a quote but holds two separate quoted spans, so it is returned as is;
    /// stripping its outer quotes would leave a stray one on each name. An apostrophe between letters (don't) is
    /// not a quote.
    static func unquote(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pairs: [(Character, Character)] = [("\"", "\""), ("\u{201C}", "\u{201D}"), ("\u{00AB}", "\u{00BB}"), ("'", "'"), ("\u{2018}", "\u{2019}")]
        guard trimmed.count >= 2, let first = trimmed.first, let last = trimmed.last else { return trimmed }
        for (open, close) in pairs where first == open && last == close {
            let inner = Array(trimmed.dropFirst().dropLast())
            for (index, character) in inner.enumerated() where character == open || character == close {
                let betweenLetters = index > 0 && index < inner.count - 1 && inner[index - 1].isLetter && inner[index + 1].isLetter
                if !(betweenLetters && (character == "'" || character == "\u{2019}")) { return trimmed }
            }
            return String(inner).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }
}
