import Foundation

/// Something the engine is waiting for the user to decide.
struct PendingAction: Sendable {
    enum Kind: Sendable {
        case confirmation(ConfirmationRequest)
        case clarification(Clarification)
    }

    let token: String
    let session: String
    let commandID: UUID
    let createdAt: Date
    let kind: Kind

    var optionLabels: [String] {
        if case .clarification(let clarification) = kind { return clarification.options.map(\.label) }
        return []
    }

    var isConfirmation: Bool { if case .confirmation = kind { return true } else { return false } }
}

/// Single-use, expiring tokens for confirmations and clarifications.
struct PendingActionStore: Sendable {
    private(set) var items: [String: PendingAction] = [:]
    private var order: [String] = []

    mutating func add(session: String, commandID: UUID, kind: PendingAction.Kind, now: Date, capacity: Int) -> String {
        var token = Self.makeToken()
        while items[token] != nil { token = Self.makeToken() }
        items[token] = PendingAction(token: token, session: session, commandID: commandID, createdAt: now, kind: kind)
        order.append(token)
        while order.count > capacity, let oldest = order.first {
            items[oldest] = nil
            order.removeFirst()
        }
        return token
    }

    /// The most recent pending item of a session.
    func latest(session: String) -> PendingAction? {
        for token in order.reversed() {
            if let item = items[token], item.session == session { return item }
        }
        return nil
    }

    func peek(token: String) -> PendingAction? { items[token] }

    /// Removes and returns the item (tokens are single-use).
    mutating func take(token: String) -> PendingAction? {
        guard let item = items.removeValue(forKey: token) else { return nil }
        order.removeAll { $0 == token }
        return item
    }

    mutating func purgeExpired(now: Date, lifetime: TimeInterval) {
        let expired = items.values.filter { now.timeIntervalSince($0.createdAt) > lifetime }.map(\.token)
        for token in expired { _ = take(token: token) }
    }

    private static func makeToken() -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        return String((0..<10).map { _ in alphabet.randomElement()! })
    }
}

/// Suppresses accidental repeats of creation-style actions (double Enter, retried IPC request…).
struct DuplicateGuard: Sendable {
    private enum Entry: Sendable {
        case inFlight(since: Date)
        case finished(at: Date)
    }

    private var entries: [String: Entry] = [:]

    /// Returns `false` when an identical call is running or finished within `window` seconds.
    mutating func begin(key: String, now: Date, window: TimeInterval) -> Bool {
        purge(now: now, window: window)
        if entries[key] != nil { return false }
        entries[key] = .inFlight(since: now)
        return true
    }

    mutating func end(key: String, now: Date, succeeded: Bool) {
        if succeeded {
            entries[key] = .finished(at: now)
        } else {
            // A failed attempt must never block a retry.
            entries[key] = nil
        }
    }

    private mutating func purge(now: Date, window: TimeInterval) {
        entries = entries.filter { _, entry in
            switch entry {
            case .inFlight(let since): return now.timeIntervalSince(since) < 600
            case .finished(let at): return now.timeIntervalSince(at) < window
            }
        }
    }
}

/// Recognises short conversational replies ("yes", "cancel", "2", "the first one", "sí", "la segunda")
/// to a pending confirmation or clarification.
public enum ReplyClassifier {
    private static let affirmative: Set<String> = [
        "yes", "y", "yeah", "yep", "yup", "ok", "okay", "sure", "confirm", "confirmed", "do it", "go ahead", "proceed",
        "yes please", "affirmative", "si", "claro", "vale", "dale", "confirmo", "confirmar", "confirmado", "adelante",
        "hazlo", "procede", "de acuerdo", "por supuesto", "sip", "okey", "listo",
    ]

    private static let negative: Set<String> = [
        "no", "n", "nope", "nah", "cancel", "cancelled", "canceled", "never mind", "nevermind", "dont", "don't", "abort",
        "no thanks", "no thank you", "cancela", "cancelar", "cancelado", "olvidalo", "mejor no", "no gracias", "nel",
    ]

    private static let ordinals: [String: Int] = [
        "1": 1, "one": 1, "first": 1, "1st": 1, "uno": 1, "primero": 1, "primera": 1, "primer": 1,
        "2": 2, "two": 2, "second": 2, "2nd": 2, "dos": 2, "segundo": 2, "segunda": 2,
        "3": 3, "three": 3, "third": 3, "3rd": 3, "tres": 3, "tercero": 3, "tercera": 3, "tercer": 3,
        "4": 4, "four": 4, "fourth": 4, "4th": 4, "cuatro": 4, "cuarto": 4, "cuarta": 4,
        "5": 5, "five": 5, "fifth": 5, "5th": 5, "cinco": 5, "quinto": 5, "quinta": 5,
        "6": 6, "six": 6, "sixth": 6, "seis": 6, "sexto": 6, "sexta": 6,
        "7": 7, "seven": 7, "seventh": 7, "siete": 7, "septimo": 7, "septima": 7,
        "8": 8, "eight": 8, "eighth": 8, "ocho": 8, "octavo": 8, "octava": 8,
        "9": 9, "nine": 9, "ninth": 9, "nueve": 9, "noveno": 9, "novena": 9,
    ]

    private static let lastWords: Set<String> = ["last", "ultimo", "ultima"]

    private static let fillers: Set<String> = [
        "please", "por", "favor", "the", "el", "la", "lo", "option", "opcion", "number", "numero", "num", "one", "choice", "elige", "elijo", "quiero",
        "i", "choose", "pick", "select", "item", "n", "no.", "#", "thanks", "gracias", "then", "entonces",
    ]

    /// - Parameters:
    ///   - optionCount: number of clarification options currently offered (0 for a confirmation).
    ///   - optionLabels: labels of those options, so "daniel" can pick "Meeting with Daniel".
    public static func classify(_ text: String, optionCount: Int, optionLabels: [String] = []) -> PendingDecision? {
        let folded = TextFolding.fold(text)
            .replacingOccurrences(of: #"[.,!?¡¿;:"]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !folded.isEmpty, folded.count <= 60 else { return nil }

        if optionCount == 0 {
            if affirmative.contains(folded) { return .confirm }
            if negative.contains(folded) { return .cancel }
        } else {
            if negative.contains(folded) { return .cancel }
        }

        let words = folded.split(separator: " ").map(String.init)
        let core = words.filter { !fillers.contains($0) }
        if optionCount > 0 {
            if core.count == 1, let word = core.first {
                if let number = ordinals[word], number <= optionCount { return .choose(number - 1) }
                if lastWords.contains(word) { return .choose(optionCount - 1) }
            }
            if core.isEmpty, words.count == 1, let number = ordinals[words[0]], number <= optionCount { return .choose(number - 1) }
            // Digits standing alone ("2") are handled above; now try matching the option labels.
            if !optionLabels.isEmpty {
                let matches = NameMatcher.rank(optionLabels.indices.map { $0 }, query: folded, minimumScore: 60) { optionLabels[$0] }
                if let best = matches.first, matches.filter({ $0.score == best.score }).count == 1 {
                    return .choose(best.item)
                }
            }
        } else {
            let joined = core.joined(separator: " ")
            if affirmative.contains(joined) { return .confirm }
            if negative.contains(joined) { return .cancel }
        }
        return nil
    }
}
