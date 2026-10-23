import Foundation
import JarvisCore

/// The built-in, rule-based interpreter. It understands common English and Spanish commands without any
/// network access, AI subscription or model, and produces exactly the same structured ``ToolCall`` values an
/// LLM interpreter would — so the engine treats both identically.
///
/// Pipeline: mask quoted text and free-form payloads → strip politeness → split multi-action commands into
/// clauses → run every rule set on every clause → keep the most confident reading of each clause.
public struct DeterministicInterpreter: CommandInterpreting {
    public let identifier = "deterministic"

    private let ruleSets: [any IntentRuleSet]
    private static let minimumConfidence = 0.5

    public init() {
        self.init(ruleSets: [UtilityRules(), MetaRules(), ClockRules(), MusicRules(), NotesRules(), RemindersRules(), CalendarRules()])
    }

    init(ruleSets: [any IntentRuleSet]) {
        self.ruleSets = ruleSets
    }

    public func interpret(_ request: InterpretationRequest) async throws -> Interpretation {
        if let followup = ContextualFollowup.interpret(request) { return followup }
        let context = DateContext(now: request.now, calendar: request.calendar, settings: request.settings, language: request.language)
        let prepared = Self.prepare(request.text)

        var outcome = try evaluate(ClauseSplitter.split(prepared), context: context)
        if outcome.steps.isEmpty, outcome.replies.isEmpty, outcome.questions.isEmpty {
            // Nothing was understood. Maybe one part of a longer command was: retry splitting at every separator.
            let aggressive = ClauseSplitter.split(prepared, requireCommandStart: false)
            if aggressive.count > 1 {
                let second = try evaluate(aggressive, context: context)
                if !second.steps.isEmpty { outcome = second }
            }
        }

        let language = request.language
        if !outcome.steps.isEmpty {
            var notes = outcome.notes
            for fragment in outcome.unrecognized {
                notes.append(language.pick("I didn't understand: “\(fragment)”.", "No entendí: «\(fragment)»."))
            }
            return .plan(ToolPlan(steps: outcome.steps, language: language, interpreter: identifier, notes: notes))
        }
        if let reply = outcome.replies.first, outcome.questions.isEmpty, outcome.unrecognized.isEmpty {
            return .reply(reply.resolved(language))
        }
        if let question = outcome.questions.first {
            return .clarification(Clarification(question: question.resolved(language)))
        }
        if let reply = outcome.replies.first { return .reply(reply.resolved(language)) }
        return .unrecognized(hint: language.pick(
            "Try something like “Play my Study playlist”, “Remind me tomorrow at 6 PM to call Mom” or say “help”.",
            "Prueba algo como «Pon mi lista Study», «Recuérdame mañana a las 6 PM llamar a mamá» o di «ayuda»."
        ))
    }

    private struct Outcome {
        var steps: [ToolCall] = []
        var notes: [String] = []
        var replies: [LocalizedText] = []
        var questions: [LocalizedText] = []
        var unrecognized: [String] = []
    }

    private func evaluate(_ clauses: [FoldedText], context: DateContext) throws -> Outcome {
        var outcome = Outcome()
        for clauseText in clauses {
            try Task.checkCancellation()
            let clause = Clause(text: clauseText, context: context)
            let results = ruleSets.flatMap { $0.interpret(clause) }.filter { $0.confidence >= Self.minimumConfidence }
            // Stable sort: on equal confidence the earlier rule set wins.
            let ranked = results.enumerated().sorted { left, right in
                if left.element.confidence != right.element.confidence { return left.element.confidence > right.element.confidence }
                return left.offset < right.offset
            }.map(\.element)

            guard let best = ranked.first else {
                outcome.unrecognized.append(Self.display(clauseText))
                continue
            }
            switch best {
            case .calls(let calls, _):
                let source = Self.display(clauseText)
                outcome.steps.append(contentsOf: calls.map { call in
                    var copy = call
                    copy.sourceText = source
                    return copy
                })
            case .clarify(let question, _):
                outcome.questions.append(question)
                if clauses.count > 1 { outcome.notes.append(Self.noteText(question, clause: clauseText, language: context.language)) }
            case .reply(let text, _):
                outcome.replies.append(text)
            }
        }
        return outcome
    }

    // MARK: Preparation

    /// Masks quotes, strips politeness, then masks free-form note payloads.
    static func prepare(_ text: String) -> FoldedText {
        var quoted = FoldedText.withQuotesMasked(text.trimmingCharacters(in: .whitespacesAndNewlines))
        // Spanish questions start with ¿ / ¡, which would stop every anchored pattern from matching.
        while let first = quoted.foldedCharacters.first, "¿¡".contains(first), quoted.count > 1 { quoted = quoted.slice(1..<quoted.count) }
        let polite = Politeness.strip(quoted)
        var masked = PayloadMasker.apply(to: polite)
        // Sentence-final punctuation is noise ("Pause the music."), except inside masked payloads.
        while let last = masked.foldedCharacters.last, ".!?".contains(last) || last == "¿", masked.count > 1 {
            masked = masked.slice(0..<(masked.count - 1))
        }
        return masked.collapsedWhitespace()
    }

    private static func display(_ clause: FoldedText) -> String {
        clause.original.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func noteText(_ question: LocalizedText, clause: FoldedText, language: Language) -> String {
        let fragment = String(display(clause).prefix(60))
        return language.pick("About “\(fragment)”: \(question.en)", "Sobre «\(fragment)»: \(question.es)")
    }
}
