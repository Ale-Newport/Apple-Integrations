import Foundation
import JarvisCore

struct UtilityRules: IntentRuleSet {
    private static let calculation = Rx.make(#"^(?:calculate|compute|calcula|calcular|cuanto es|what is|what's)\s+(?:el\s+)?(?<expression>.+)$"#)
    private static let percentage = Rx.make(#"^(?<percent>[\d.,]+)\s*(?:%|por ciento|percent)\s+(?:de|of)\s+(?<value>[\d.,]+)$"#)
    private static let conversion = Rx.make(#"^(?:convert|convertir|convierte|pasa)\s+(?<value>-?[\d.,]+)\s*(?<from>[a-zA-Z°/]+)\s+(?:a|to|in|en)\s+(?<to>[a-zA-Z°/]+)$"#)
    private static let weatherLocation = Rx.make(#"\s+(?:en|in|at|for)\s+(?<location>.+?)[?¿]*$"#)

    func interpret(_ clause: Clause) -> [RuleResult] {
        if clause.folded.contains("jarvis"), clause.folded.contains("temporizador") || clause.folded.contains("timer") {
            let when = clause.parseDates(allowBareDuration: true).when
            if let duration = when.duration, duration > 0 {
                return [.calls([ToolCall(tool: "jarvis_timers.create", arguments: ["duration_seconds": .int(Int(duration))])], confidence: 0.99)]
            }
            if clause.folded.contains("queda") || clause.folded.contains("list") || clause.folded.contains("show") {
                return [.calls([ToolCall(tool: "jarvis_timers.list")], confidence: 0.99)]
            }
        }
        if let match = clause.whole(Self.conversion, groups: ["value", "from", "to"]),
           let raw = match.original("value"), let value = number(raw, language: clause.language),
           let from = match.original("from"), let to = match.original("to") {
            return [.calls([ToolCall(tool: "utilities.convert", arguments: ["value": .double(value), "from": .string(from), "to": .string(to)])], confidence: 0.99)]
        }
        if let match = clause.whole(Self.calculation, groups: ["expression"]), let expression = match.original("expression") {
            let folded = FoldedText(expression)
            if let percentage = folded.wholeMatch(Self.percentage, groups: ["percent", "value"]),
               let percent = percentage.original("percent").flatMap({ number($0, language: clause.language) }),
               let value = percentage.original("value").flatMap({ number($0, language: clause.language) }) {
                return [.calls([ToolCall(tool: "utilities.calculate", arguments: ["expression": .string("\(percent)/100*\(value)")])], confidence: 0.99)]
            }
            let normalized = clause.language == .es ? expression.replacingOccurrences(of: ",", with: ".") : expression
            // Ordinary factual questions should go to the configured model, not to the numeric parser.
            if normalized.contains(where: \.isNumber) && !normalized.contains("euros") && !normalized.contains("dollars") {
                return [.calls([ToolCall(tool: "utilities.calculate", arguments: ["expression": .string(normalized)])], confidence: 0.96)]
            }
        }
        let folded = clause.folded
        if folded.contains("weather") || folded.contains("tiempo hace") || folded.contains("tiempo hara") || folded.contains("llover") || folded.contains("temperatura hara") || folded.contains("forecast") || folded.contains("prevision meteorologica") {
            let parsed = clause.parseDates()
            var arguments: JSONObject = [:]
            let withoutDates = Clause(text: TextCleanup.trimConnectors(parsed.remainder), context: clause.context)
            if let location = withoutDates.find(Self.weatherLocation, groups: ["location"])?.original("location") { arguments["location"] = .string(TextCleanup.name(location)) }
            if let day = parsed.when.day { arguments["date"] = .string(ISODates.dayString(from: day, timeZone: clause.context.calendar.timeZone)) }
            return [.calls([ToolCall(tool: "weather.forecast", arguments: arguments)], confidence: 0.99)]
        }
        return []
    }

    private func number(_ text: String, language: Language) -> Double? {
        let normalized = language == .es ? text.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".") : text.replacingOccurrences(of: ",", with: "")
        return Double(normalized)
    }
}
