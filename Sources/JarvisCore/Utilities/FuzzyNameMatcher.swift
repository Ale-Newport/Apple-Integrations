import Foundation

/// Deliberately separate from exact entity matching used for destructive actions.
public enum FuzzyNameMatcher {
    public static func score(query: String, candidate: String) -> Int {
        let exact = NameMatcher.score(query: query, candidate: candidate)
        let q = TextFolding.tokens(query)
        let c = TextFolding.tokens(candidate)
        guard !q.isEmpty, q.count == c.count, q.count <= 20 else { return exact }
        var total = 0.0
        for (a, b) in zip(q, c) {
            if a == b { total += 1; continue }
            guard min(a.count, b.count) >= 4, max(a.count, b.count) <= 150 else { return exact }
            let distance = editDistance(a, b)
            let similarity = 1 - Double(distance) / Double(max(a.count, b.count))
            guard similarity >= 0.72, distance <= 2 else { return exact }
            total += similarity
        }
        return max(exact, Int(80 + 12 * total / Double(q.count)))
    }

    /// Damerau-Levenshtein: insertion, deletion, substitution and adjacent transposition.
    private static func editDistance(_ first: String, _ second: String) -> Int {
        let a = Array(first), b = Array(second)
        var older = Array(0...b.count)
        var previous = older
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { current[j] = min(current[j], older[j - 2] + 1) }
            }
            older = previous; previous = current
        }
        return previous[b.count]
    }
}
