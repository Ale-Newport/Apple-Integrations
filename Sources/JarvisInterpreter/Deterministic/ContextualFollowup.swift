import Foundation
import JarvisCore

/// Conservative offline follow-ups. Ambiguous selections never become creates or broad edits.
enum ContextualFollowup {
    static func interpret(_ request: InterpretationRequest) -> Interpretation? {
        let text = FoldedText.withQuotesMasked(request.text.trimmingCharacters(in: .whitespacesAndNewlines))
        let move = Rx.make(#"^(?:put it|move it|ponlo|ponla|pasalo|pasala|muevelo|muevela)\s+(?:in|into|to|en|a)\s+(?:(?:the|my|la|mi)\s+)?(?:list\s+|lista\s+(?:de\s+)?)(?<list>.+)$"#)
        let changeTime = Rx.make(#"^(?:change (?:its|the) time|change it|cambia(?:le)? (?:la )?hora|cambialo|cambiala|ponlo|ponla)\s+(?:to|a|al|para)\s+.+$"#)
        let complete = Rx.make(#"^(?:complete it|mark it (?:as )?done|completalo|completala|marcalo como completado|marcala como completada)$"#)
        let matchesMove = text.wholeMatch(move, groups: ["list"])
        let matchesTime = text.wholeMatch(changeTime, groups: []) != nil
        let matchesComplete = text.wholeMatch(complete, groups: []) != nil
        guard matchesMove != nil || matchesTime || matchesComplete else { return nil }
        let reminderTools: Set<ToolName> = [.remindersCreate, .remindersUpdate, .remindersComplete, .remindersList]
        guard let turn = request.conversation.reversed().first(where: { $0.results.contains { $0.success && reminderTools.contains($0.tool) } }) else {
            return .clarification(Clarification(question: request.language.pick("Which reminder do you mean?", "¿A qué recordatorio te refieres?")))
        }
        let recent = turn.results.filter { $0.success && reminderTools.contains($0.tool) }
        var byID: [String: JSONValue] = [:]
        for result in recent {
            if let data = result.data, let id = data["id"]?.stringValue { byID[id] = data }
            else {
                for data in result.data?["reminders"]?.arrayValue ?? [] {
                    if let id = data["id"]?.stringValue { byID[id] = data }
                }
            }
        }
        let candidates = Array(byID.values)
        guard candidates.count == 1, let id = candidates.first?["id"]?.stringValue else {
            return .clarification(Clarification(question: request.language.pick("Several reminders could match. Which title?", "Hay varios recordatorios posibles. ¿Cuál es el título?")))
        }
        var arguments: JSONObject = ["id": .string(id)]
        var tool = ToolName.remindersUpdate
        if let list = matchesMove?.original("list") { arguments["new_list"] = .string(TextCleanup.name(list)) }
        else if matchesComplete { tool = .remindersComplete; arguments["completed"] = true }
        else {
            let dateContext = DateContext(now: request.now, calendar: request.calendar, settings: request.settings, language: request.language)
            let when = NaturalDateParser().parse(text, context: dateContext)
            guard let due = ArgumentBuilders.dueValue(when, calendar: request.calendar) else {
                return .clarification(Clarification(question: request.language.pick("What date and time?", "¿Qué fecha y hora?")))
            }
            // A time-only correction keeps the reminder's existing day.
            if when.dayWasImplied, let old = candidates.first?["due"]?.stringValue,
               let oldDate = ISODates.date(from: old, timeZone: request.calendar.timeZone), let hour = when.hour,
               let corrected = request.calendar.date(bySettingHour: hour, minute: when.minute ?? 0, second: 0, of: oldDate) {
                arguments["new_due"] = .string(ISODates.string(from: corrected, timeZone: request.calendar.timeZone))
            } else { arguments["new_due"] = due }
        }
        return .plan(ToolPlan(steps: [ToolCall(tool: tool, arguments: arguments)], language: request.language, interpreter: "context"))
    }
}
