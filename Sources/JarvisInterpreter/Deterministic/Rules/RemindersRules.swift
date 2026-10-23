import Foundation
import JarvisCore

/// English/Spanish rules for Apple Reminders.
struct RemindersRules: IntentRuleSet {
    // MARK: Patterns

    private static let remindMe = Rx.make(#"^(?:remind me|remind us|set (?:a |an )?reminder|create (?:a |an )?reminder|add (?:a |an )?reminder|make (?:a |an )?reminder|new reminder|reminder|recuerdame|recuerda me|recordarme|crea (?:un )?recordatorio|crear (?:un )?recordatorio|agrega (?:un )?recordatorio|anade (?:un )?recordatorio|pon (?:un )?recordatorio|ponme (?:un )?recordatorio|programa (?:un )?recordatorio|nuevo recordatorio|recordatorio)(?:\s*(?::|-)\s*|\s+(?:to|about|that|for|of|de que|que|de|a|para|sobre)\s+|\s+)(?<title>.+)$"#)
    private static let remindMeBare = Rx.make(#"^(?:remind me|recuerdame|set (?:a |an )?reminder|create (?:a |an )?reminder|crea (?:un )?recordatorio)$"#)
    private static let addVerb = Rx.make(#"^(?:add|put|create|insert|save|agrega|agregar|agregame|anade|anadir|anademe|pon|ponme|poner|apunta|mete|incluye)\s+(?<title>.+)$"#)

    private static let titlePrefix = Rx.make(#"^(?:(?:a |an )?reminders?(?: to| for| about| that)?[:\s]+|(?:un )?recordatorio(?: de| para| sobre| que)?[:\s]+)"#)
    private static let obligationPrefix = Rx.make(#"^(?:that\s+)?(?:i\s+)?(?:have to|need to|must|should|got to|gotta|ought to|tengo que|debo|necesito|hay que|tienes que)\s+"#)
    private static let recurrence = Rx.make(#"\b(?:every|each|daily|weekly|monthly|yearly|annually|cada|todos los|todas las|diario|diaria|semanal|mensual|anual|a diario)\b"#)

    // The list phrase at the end of a clause. `before` is greedy so the LAST preposition wins ("talk to Bob to my X list").
    private static let listPhrases: [NSRegularExpression] = [
        Rx.make(#"^(?<before>.+)\s+a la (?<list>compra)$"#),
        Rx.make(#"^(?<before>.+)\s+(?:to|in|on|into|onto|under|at)\s+(?:my\s+|the\s+|our\s+)?(?:reminders?\s+)?list\s+(?:called\s+|named\s+|titled\s+)(?<list>\S+(?:\s+\S+){0,3}?)$"#),
        Rx.make(#"^(?<before>.+)\s+(?:to|in|on|into|onto|under|at)\s+(?:my\s+|the\s+|our\s+)?(?<list>\S+(?:\s+\S+){0,3}?)\s+(?:reminders?\s+)?list$"#),
        Rx.make(#"^(?<before>.+)\s+(?:to|in|on|into|onto|under|at)\s+(?:my\s+|the\s+|our\s+)?(?:reminders?\s+)?list\s+(?<list>\S+(?:\s+\S+){0,3}?)$"#),
        Rx.make(#"^(?<before>.+)\s+(?:to|in|on|into|onto|under|at)\s+(?:my\s+|the\s+|our\s+)?(?<list>\S+(?:\s+\S+){0,3}?)\s+reminders$"#),
        Rx.make(#"^(?<before>.+)\s+(?:a|en|al|dentro de|para)\s+(?:mi\s+|la\s+|el\s+)?lista\s+de\s+recordatorios\s+(?:llamada\s+|titulada\s+|de\s+)?(?<list>\S+(?:\s+\S+){0,3}?)$"#),
        Rx.make(#"^(?<before>.+)\s+(?:a|en|al|dentro de|para)\s+(?:mi\s+|la\s+|el\s+)?lista\s+(?:llamada\s+|titulada\s+)(?<list>\S+(?:\s+\S+){0,3}?)$"#),
        Rx.make(#"^(?<before>.+)\s+(?:a|en|al|dentro de|para)\s+(?:mi\s+|la\s+|el\s+)?lista\s+(?:de\s+|del\s+)?(?<list>\S+(?:\s+\S+){0,3}?)$"#),
        Rx.make(#"^(?<before>.+)\s+(?:a|en|al|dentro de|para)\s+(?:mi\s+|la\s+|el\s+)?(?<list>\S+(?:\s+\S+){0,3}?)\s+(?:lista|de recordatorios)$"#),
        Rx.make(#"^(?<before>.+)\s+(?:a|en|al|dentro de|para)\s+(?:mis\s+|los\s+)?recordatorios\s+(?:de\s+)?(?<list>\S+(?:\s+\S+){0,3}?)$"#),
    ]
    // "…to my reminders" (no list name): default list.
    private static let leadingList = Rx.make(#"^(?:en|in|on)\s+(?:(?:la|mi|the|my)\s+)?(?:lista|list)\s+(?:de\s+)?(?<list>.+?)(?:,?\s+(?:dentro de|en|within|in)\s+(?:(?:la|the)\s+)?(?:seccion|section)\s+(?<section>.+?))?,?\s+(?:anade|agrega|pon|add|put)\s+(?<content>.+)$"#)
    private static let leadingPut = Rx.make(#"^(?:pon|put)\s+(?:en|in)\s+(?:(?:la|the)\s+)?(?:lista|list)\s+(?<list>.+?)(?:,?\s+(?:en|in)\s+(?:(?:la|the)\s+)?(?:seccion|section)\s+(?<section>.+?))?,?\s+(?:que|that)\s+(?<content>.+)$"#)
    private static let toRemindersApp = Rx.make(#"^(?<before>.+)\s+(?:to|in|on|into|onto|a|en|al)\s+(?:my\s+|the\s+|mis\s+|mi\s+|los\s+)?(?:reminders?(?: app)?|recordatorios?)$"#)

    private static let queryStarter = Rx.make(#"^(?:show|list|display|what|which|see|get|tell|give|check|do i have|have i|whats|what's|are there|how many|muestra|muestrame|mostrar|lista|listar|dime|cuales|que|ver|revisa|consulta|tengo|tienes|hay|cuantos|cuantas)\b"#)
    private static let reminderNouns = Rx.make(#"\b(?:reminders?|recordatorios?|to-?dos?|todo list|tasks?|tareas?|pendientes)\b"#)
    private static let pendingWords = Rx.make(#"\b(?:pending|incomplete|open|outstanding|uncompleted|not done|undone|due|upcoming|pendientes?|sin completar|por hacer|abiertos?|no completados?)\b"#)
    private static let completedWords = Rx.make(#"\b(?:completed|complete|done|finished|checked off|completados?|completadas?|hechos?|hechas?|terminados?|terminadas?|realizados?|realizadas?)\b"#)
    private static let allWords = Rx.make(#"\b(?:all|every|todos|todas)\b"#)
    private static let overdueWords = Rx.make(#"\b(?:overdue|late|past due|atrasados?|atrasadas?|vencidos?|vencidas?)\b"#)
    private static let listFilter = Rx.make(#"\s+(?:in|from|on|of|de|en|del)\s+(?:my\s+|the\s+|mi\s+|la\s+)?(?:(?:reminders?\s+)?list\s+(?:called\s+|named\s+)?(?<a>\S+(?:\s+\S+){0,3})|(?<b>\S+(?:\s+\S+){0,3})\s+(?:reminders?\s+)?list|lista\s+(?:de\s+|llamada\s+)?(?<c>\S+(?:\s+\S+){0,3})|(?<d>\S+(?:\s+\S+){0,3})\s+lista)$"#)
    private static let listFilterNamed = Rx.make(#"\s+(?:in|from|on|of|de|en|del)\s+(?:my\s+|the\s+|mi\s+|la\s+)?(?<e>\S+(?:\s+\S+){0,3})$"#)

    private static let complete = Rx.make(#"^(?:mark|set|check off|tick off|cross off|complete|finish|marca|marcar|completa|completar|tacha|termina|finaliza)\s+(?:(?:the|my|el|mi)\s+)?(?:(?:reminder|recordatorio|task|tarea)\s+)?(?<title>.+?)(?:\s+(?:as\s+|como\s+)?(?:done|complete|completed|finished|hecho|hecha|completado|completada|terminado|terminada|listo|lista|realizado|realizada))?$"#)
    /// "mark as done buy milk", "marca como completado comprar leche": the state comes first.
    private static let completePrefix = Rx.make(#"^(?:mark|set|marca|marcar)\s+(?:as\s+|como\s+)(?:done|complete|completed|finished|hecho|hecha|completado|completada|terminado|terminada|listo|lista|realizado|realizada)\s+(?:(?:the|my|el|mi)\s+)?(?:(?:reminder|recordatorio|task|tarea)\s+)?(?<title>.+)$"#)
    private static let leadingConnector = Rx.make(#"^(?:to|that|about|for|para|que|de|sobre)\s+"#)
    /// Questions about what is still open ("what's pending", "qué tengo pendiente") are about reminders.
    private static let pendingNoun = Rx.make(#"\b(?:pending|outstanding|overdue|pendientes?|por hacer)\b"#)
    /// "what's on my shopping list", "show my shopping list", "qué hay en mi lista de la compra".
    private static let listContents = Rx.make(#"^(?:what(?:'s| is| are)?|show me|show|list|display|read|whats|que hay|que tengo|muestra|muestrame|dime|lee|ver)\s+(?:(?:on|in|en|dentro de)\s+)?(?:(?:my|the|mi|la|el)\s+)?(?:(?<a>\S+(?:\s+\S+){0,2}?)\s+list|lista\s+(?:de\s+)?(?<b>\S+(?:\s+\S+){0,3}))\s*\??$"#)
    private static let finishedPrefix = Rx.make(#"^(?:i (?:finished|completed|did)|ya (?:termine|complete|hice)|done with|terminado)\s+(?<title>.+)$"#)
    private static let uncomplete = Rx.make(#"^(?:mark|set|marca|marcar)\s+(?:(?:the|my|el|mi)\s+)?(?:(?:reminder|recordatorio|task|tarea)\s+)?(?<title>.+?)\s+(?:as\s+|como\s+)?(?:not done|incomplete|not completed|pending|undone|not finished|no completado|no completada|incompleto|incompleta|pendiente|sin completar|no terminado|no terminada)$"#)
    private static let uncheck = Rx.make(#"^(?:uncheck|unmark|reopen|uncomplete|desmarca|desmarcar|reabre|reabrir)\s+(?:(?:the|my|el|mi)\s+)?(?:(?:reminder|recordatorio|task|tarea)\s+)?(?<title>.+)$"#)
    private static let completeNeedsDone = Rx.make(#"\b(?:as\s+|como\s+)?(?:done|complete|completed|finished|hecho|hecha|completado|completada|terminado|terminada|listo|realizado)\b|^(?:check off|tick off|cross off|complete|finish|completa|completar|tacha|termina|finaliza)\b|\b(?:reminder|recordatorio)\b"#)

    private static let delete = Rx.make(#"^(?:delete|remove|erase|clear|trash|elimina|eliminar|borra|borrar|quita|quitar)\s+(?:(?:the|my|el|mi)\s+)?(?:(?:reminder|recordatorio|task|tarea)\s+)(?:(?:to|about|called|named|titled|de|llamado|llamada)\s+)?(?<title>.+)$"#)
    private static let deleteFromList = Rx.make(#"^(?:delete|remove|erase|clear|take|elimina|eliminar|borra|borrar|quita|quitar|saca)\s+(?:(?:the|my|el|mi)\s+)?(?<title>.+)$"#)

    private static let createList = Rx.make(#"^(?:create|make|add|new|start|crea|crear|agrega|agregar|anade|nueva|nuevo|haz)\s+(?:(?:a|an|una|un)\s+)?(?:new\s+|nueva\s+)?(?:reminders?\s+list|list of reminders|reminder list|lista(?:\s+de\s+recordatorios)?|list)\s*(?:called|named|titled|llamada|llamado|titulada|:)?\s*(?<name>.+)$"#)
    private static let createListB = Rx.make(#"^(?:create|make|new|crea|crear|nueva|haz)\s+(?:(?:a|an|una|un)\s+)?(?:new\s+|nueva\s+)?(?<name>[^\s]+(?:\s+[^\s]+){0,2}?)\s+(?:reminders?\s+list|reminder list|lista de recordatorios)$"#)
    private static let showLists = Rx.make(#"^(?:(?:list|show|display|what|which|get|see|muestra|muestrame|lista|listar|cuales|que|dime|ver)\s+)(?:(?:are|is|do i have|have i got|tengo|son|hay)\s+)*(?:(?:my|all|the|mis|todas|las)\s+)*(?:reminders?\s+lists|lists of reminders|reminder lists|lists|listas de recordatorios|listas)(?:\s+(?:do i have|i have|tengo|que tengo))?\s*\??$"#)

    private static let reschedule = Rx.make(#"^(?:reschedule|postpone|push|delay|move|change|update|reprograma|reprogramar|pospon|posponer|mueve|mover|cambia|cambiar|actualiza|actualizar|retrasa|atrasa)\s+(?:(?:the|my|el|mi)\s+)?(?:reminder|recordatorio)\s+(?:(?:to|about|called|named|titled|de|llamado|llamada)\s+)?(?<title>.+?)(?:\s+(?:to|for|until|till|a|para|hasta))?$"#)
    private static let rename = Rx.make(#"^(?:rename|retitle|renombra|renombrar|cambia el nombre de)\s+(?:(?:the|my|el|mi)\s+)?(?:reminder|recordatorio)\s+(?<title>.+?)\s+(?:to|as|a|como)\s+(?<new>.+)$"#)
    private static let moveToList = Rx.make(#"^(?:move|transfer|mueve|mover|pasa|pasar|cambia|cambiar)\s+(?:(?:the|my|el|mi)\s+)?(?:(?:reminder|recordatorio)\s+)?(?<title>.+?)\s+(?:to|into|a|al)\s+(?:my\s+|the\s+|mi\s+|la\s+)?(?:(?:reminders?\s+)?list\s+(?:called\s+|named\s+)?(?<a>.+)|(?<b>.+?)\s+(?:reminders?\s+)?list|lista\s+(?:de\s+)?(?<c>.+))$"#)

    // MARK: Interpretation

    func interpret(_ clause: Clause) -> [RuleResult] {
        var results: [RuleResult] = []
        let folded = clause.folded
        guard !folded.isEmpty else { return [] }
        let calendar = clause.context.calendar
        let hasReminderNoun = clause.find(Self.reminderNouns) != nil

        // --- List management uses stable identifiers after resolving a name.
        if let match = clause.whole(Rx.make(#"^(?:rename|renombra|cambia el nombre de)\s+(?:(?:the|la)\s+)?(?:list|lista)\s+(?<name>.+?)\s+(?:to|a|como)\s+(?<new>.+)$"#), groups: ["name", "new"]), let name = match.original("name"), let new = match.original("new") {
            return [.calls([ToolCall(tool: "reminders.rename_list", arguments: ["name": .string(TextCleanup.name(name)), "new_name": .string(TextCleanup.name(new))])], confidence: 0.99)]
        }
        if let match = clause.whole(Rx.make(#"^(?:delete|remove|borra|elimina)\s+(?:(?:the|la)\s+)?(?:reminders?\s+list|lista(?: de recordatorios)?|list)\s+(?<name>.+)$"#), groups: ["name"]), let name = match.original("name") {
            return [.calls([ToolCall(tool: "reminders.delete_list", arguments: ["name": .string(TextCleanup.name(name))])], confidence: 0.99)]
        }
        // --- Lists of lists / create list (no dates involved)
        if clause.whole(Self.showLists, groups: []) != nil, folded.contains("reminder") || folded.contains("recordatorio") || !folded.contains("playlist") {
            let confidence = (folded.contains("reminder") || folded.contains("recordatorio")) ? 0.93 : 0.55
            results.append(.calls([ToolCall(tool: .remindersListLists)], confidence: confidence))
        }
        if let match = clause.whole(Self.createList, groups: ["name"]) ?? clause.whole(Self.createListB, groups: ["name"]),
           let name = match.original("name").map(TextCleanup.name), !name.isEmpty,
           folded.contains("list") || folded.contains("lista") {
            let strong = folded.contains("reminder") || folded.contains("recordatorio")
            results.append(.calls([ToolCall(tool: .remindersCreateList, arguments: ["name": .string(name)])], confidence: strong ? 0.93 : 0.58))
        }

        // --- Dates (cut out of the clause)
        let parsed = clause.parseDates()
        let when = parsed.when
        let metadataFirst = clause.folded.hasPrefix("en ") || clause.folded.hasPrefix("in ") || clause.folded.hasPrefix("on ")
        let rest = metadataFirst ? parsed.remainder.collapsedWhitespace() : TextCleanup.trimConnectors(parsed.remainder)
        let restClause = Clause(text: rest, context: clause.context)

        // --- Move reminder to another list
        if let match = restClause.whole(Self.moveToList, groups: ["title", "a", "b", "c"]),
           let title = match.original("title").map(TextCleanup.title), !title.isEmpty,
           let list = (match.original("a") ?? match.original("b") ?? match.original("c")).map(TextCleanup.name), !list.isEmpty,
           when.isEmpty {
            let strong = hasReminderNoun
            results.append(.calls([ToolCall(tool: .remindersUpdate, arguments: ["title": .string(title), "new_list": .string(list)])], confidence: strong ? 0.9 : 0.6))
        }

        // --- Rename
        if let match = restClause.whole(Self.rename, groups: ["title", "new"]),
           let title = match.original("title").map(TextCleanup.title), let newTitle = match.original("new").map(TextCleanup.title) {
            results.append(.calls([ToolCall(tool: .remindersUpdate, arguments: ["title": .string(title), "new_title": .string(newTitle)])], confidence: 0.9))
        }

        // --- Reschedule
        if let match = restClause.whole(Self.reschedule, groups: ["title"]), let title = match.original("title").map(TextCleanup.title), !title.isEmpty, !when.isEmpty {
            var arguments: JSONObject = ["title": .string(title)]
            if let due = ArgumentBuilders.dueValue(when, calendar: calendar) { arguments["new_due"] = due }
            if arguments.count > 1 {
                results.append(.calls([ToolCall(tool: .remindersUpdate, arguments: arguments, assumptions: when.assumptions)], confidence: 0.9))
            }
        }

        // --- Uncomplete / complete
        if let match = restClause.whole(Self.uncomplete, groups: ["title"]) ?? restClause.whole(Self.uncheck, groups: ["title"]),
           let title = match.original("title").map(TextCleanup.title), !title.isEmpty {
            let (name, list) = splitListSuffix(title)
            var arguments: JSONObject = ["title": .string(name), "completed": false]
            if let list { arguments["list"] = .string(list) }
            results.append(.calls([ToolCall(tool: .remindersComplete, arguments: arguments)], confidence: 0.9))
        } else if let match = restClause.whole(Self.completePrefix, groups: ["title"]) ?? restClause.whole(Self.complete, groups: ["title"]) ?? restClause.whole(Self.finishedPrefix, groups: ["title"]),
                  restClause.find(Self.completeNeedsDone) != nil || restClause.whole(Self.finishedPrefix, groups: ["title"]) != nil,
                  let raw = match.original("title") {
            let (extracted, list) = Self.extractList(from: FoldedText(raw))
            let title = TextCleanup.title(extracted.original)
            if !title.isEmpty {
                var arguments: JSONObject = ["title": .string(title)]
                if let list { arguments["list"] = .string(list) }
                let strong = hasReminderNoun || folded.contains(" as done") || folded.contains("como hecho") || folded.contains("completado") || folded.contains("completed")
                results.append(.calls([ToolCall(tool: .remindersComplete, arguments: arguments)], confidence: strong ? 0.88 : 0.55))
            }
        }

        // --- Delete
        if let match = restClause.whole(Self.delete, groups: ["title"]), let raw = match.original("title") {
            let (extracted, list) = Self.extractList(from: FoldedText(raw))
            let title = TextCleanup.title(extracted.original)
            if !title.isEmpty {
                var arguments: JSONObject = ["title": .string(title)]
                if let list { arguments["list"] = .string(list) }
                results.append(.calls([ToolCall(tool: .remindersDelete, arguments: arguments)], confidence: 0.92))
            }
        } else if let match = restClause.whole(Self.deleteFromList, groups: ["title"]), let raw = match.original("title") {
            let (extracted, list) = Self.extractList(from: FoldedText(raw))
            if let list {
                let title = TextCleanup.title(extracted.original)
                if !title.isEmpty {
                    results.append(.calls([ToolCall(tool: .remindersDelete, arguments: ["title": .string(title), "list": .string(list)])], confidence: 0.86))
                }
            }
        }

        // --- Contents of one list ("what's on my shopping list")
        if let match = clause.whole(Self.listContents, groups: ["a", "b"]),
           let name = (match.original("a") ?? match.original("b")).map(TextCleanup.name), !name.isEmpty,
           !["my", "the", "reminder", "reminders", "recordatorios", "to-do", "todo", "to do", "mi", "playlist", "play"].contains(name.lowercased()) {
            results.append(.calls([ToolCall(tool: .remindersList, arguments: ["list": .string(name), "status": "pending"])], confidence: 0.7))
        }

        // --- List reminders
        let startsAsQuestion = clause.find(Self.queryStarter).map { $0.range.lowerBound == 0 } ?? false
        let asksWhatIsPending = startsAsQuestion && clause.find(Self.pendingNoun) != nil
        let asksWhatToDo = folded.contains("have to do") || folded.contains("need to do") || folded.contains("tengo que hacer") || folded.contains("hay que hacer")
        if hasReminderNoun || asksWhatToDo || asksWhatIsPending || folded.contains("hacer") && folded.contains("tengo") {
            let startsAsQuery = startsAsQuestion
            let createsInstead = clause.folded.hasPrefix("remind") || clause.folded.hasPrefix("recuerd") || clause.folded.hasPrefix("add") || clause.folded.hasPrefix("create") || clause.folded.hasPrefix("crea") || clause.folded.hasPrefix("agrega") || clause.folded.hasPrefix("set") || clause.folded.hasPrefix("new")
            if startsAsQuery && !createsInstead {
                results.append(.calls([listCall(for: clause, when: when, calendar: calendar)], confidence: 0.9))
            }
        }

        // --- Create ("remind me to…", "add X to my Y list")
        if let creation = createCall(restClause, when: when, clause: clause, calendar: calendar) {
            results.append(creation)
        }
        return results
    }

    // MARK: Create

    private func createCall(_ rest: Clause, when: ParsedWhen, clause: Clause, calendar: Calendar) -> RuleResult? {
        let extracted = Self.extractList(from: rest.text)
        var list = extracted.1
        var section: String?
        var leadingContent: String?
        if let match = rest.whole(Self.leadingList, groups: ["list", "section", "content"]) ?? rest.whole(Self.leadingPut, groups: ["list", "section", "content"]) {
            list = match.original("list").map(TextCleanup.name)
            section = match.original("section").map(TextCleanup.name)
            leadingContent = match.original("content")
        }
        let working = Clause(text: extracted.0, context: clause.context)

        var title: String?
        var confidence = 0.0
        var explicitReminder = false

        if let leadingContent {
            title = leadingContent
            confidence = 0.99
            explicitReminder = true
        }
        if working.whole(Self.remindMeBare, groups: []) != nil {
            return .clarify(
                LocalizedText(en: "What should I remind you about?", es: "¿Sobre qué quieres que te recuerde?"),
                confidence: 0.85
            )
        }
        if leadingContent != nil { /* metadata-first reminder */ }
        else if let match = working.whole(Self.remindMe, groups: ["title"]) {
            title = match.original("title")
            confidence = 0.95
            explicitReminder = true
        } else if let match = working.whole(Self.addVerb, groups: ["title"]), list != nil || Self.mentionsRemindersApp(rest.folded) {
            title = match.original("title")
            confidence = list != nil ? 0.9 : 0.8
        } else if let match = Self.toRemindersApp.firstMatchWhole(in: working.text), list == nil,
                  let addMatch = FoldedText(match).wholeMatch(Self.addVerb, groups: ["title"]) {
            title = addMatch.original("title")
            confidence = 0.8
        }
        guard var raw = title else { return nil }
        var parentTitle: String?
        if clause.folded.contains("subtarea") || clause.folded.contains("subtask") {
            let parent = Rx.make(#"^(?:como\s+)?(?:subtarea|subtask)\s+(?:de|of|under)\s+(?<parent>.+?)\s+(?:que|that|:)\s+(?<content>.+)$"#)
            if let match = FoldedText(raw).wholeMatch(parent, groups: ["parent", "content"]), let content = match.original("content") {
                parentTitle = match.original("parent")
                raw = content
            } else {
                return .reply(LocalizedText(en: "Public Reminders APIs cannot create subtasks. No reminder was created. Use the Reminders app to organize subtasks.", es: "Las API públicas de Recordatorios no permiten crear subtareas. No se creó ningún recordatorio. Organiza las subtareas en la app Recordatorios."), confidence: 0.99)
            }
        }

        // Strip "a reminder to", "I have to", …
        raw = Self.stripPrefix(Self.titlePrefix, from: raw)
        raw = Self.stripPrefix(Self.obligationPrefix, from: raw)
        // "ponme un recordatorio para mañana a las 8 para pagar la luz": the date is gone, its "para" is not part of the title.
        if explicitReminder { raw = Self.stripPrefix(Self.leadingConnector, from: raw) }
        var cleaned = TextCleanup.title(raw)
        // "Add buy milk to my reminders" leaves a trailing "to my reminders" handled above; remove stray leading "to ".
        if cleaned.lowercased().hasPrefix("to "), explicitReminder { cleaned = TextCleanup.capitalizeFirst(String(cleaned.dropFirst(3))) }
        guard !cleaned.isEmpty else {
            return .clarify(LocalizedText(en: "What should the reminder say?", es: "¿Qué debe decir el recordatorio?"), confidence: 0.8)
        }

        var arguments: JSONObject = ["title": .string(cleaned)]
        if let list { arguments["list"] = .string(list) }
        if let section { arguments["section"] = .string(section) }
        if let due = ArgumentBuilders.dueValue(when, calendar: calendar) { arguments["due"] = due }
        let assumptions = when.assumptions
        if clause.find(Self.recurrence) != nil, explicitReminder {
            let f = clause.folded
            let recurrence: String
            if f.contains("month") || f.contains("mensual") || f.contains("cada mes") { recurrence = "monthly" }
            else if f.contains("year") || f.contains("anual") || f.contains("cada ano") { recurrence = "yearly" }
            else if f.contains("daily") || f.contains("every day") || f.contains("cada dia") || f.contains("a diario") || f.contains("todos los dias") { recurrence = "daily" }
            else { recurrence = "weekly" }
            arguments["recurrence"] = .string(recurrence)
            // Remove recurrence metadata left by the date parser from the actual title.
            let cleanedRecurrence = cleaned.replacingOccurrences(of: #"(?i)\b(?:every|each|cada|todos los|todas las)\s*(?:day|week|month|year|dia|semana|mes|ano)?\b|\b(?:daily|weekly|monthly|yearly|diario|semanal|mensual|anual|a diario)\b"#, with: "", options: .regularExpression)
            cleaned = TextCleanup.title(cleanedRecurrence)
            cleaned = Self.stripPrefix(Self.leadingConnector, from: cleaned)
            arguments["title"] = .string(TextCleanup.title(cleaned))
        }
        if let parentTitle { arguments["parent_title"] = .string(parentTitle) }
        // Comma-separated shopping items become separate, individually verified reminders. Quoted dictation stays intact.
        let originalTitle = title ?? ""
        let masked = FoldedText.withQuotesMasked(cleaned)
        let separators = masked.matches(Rx.make(#",\s*|\s+(?:and|y)\s+"#)).filter { !masked.isMasked($0.range) }
        if section == nil, arguments["parent_title"] == nil, originalTitle.contains(","), !TextFolding.fold(clause.text.original).contains("\"" + TextFolding.fold(originalTitle) + "\""), !separators.isEmpty {
            var titles: [String] = []
            var offset = 0
            for separator in separators {
                titles.append(TextCleanup.title(masked.original(offset..<separator.range.lowerBound)))
                offset = separator.range.upperBound
            }
            titles.append(TextCleanup.title(masked.original(offset..<masked.count)))
            let calls = titles.filter { !$0.isEmpty }.prefix(30).map { value -> ToolCall in
                var args = arguments; args["title"] = .string(value)
                return ToolCall(tool: .remindersCreate, arguments: args, assumptions: assumptions)
            }
            return .calls(calls, confidence: confidence)
        }
        return .calls([ToolCall(tool: .remindersCreate, arguments: arguments, assumptions: assumptions)], confidence: confidence)
    }

    // MARK: List

    private func listCall(for clause: Clause, when: ParsedWhen, calendar: Calendar) -> ToolCall {
        var arguments: JSONObject = [:]
        var status = "pending"
        if clause.find(Self.completedWords) != nil, clause.find(Self.pendingWords) == nil { status = "completed" }
        else if clause.find(Self.allWords) != nil, clause.find(Self.pendingWords) == nil, clause.find(Self.completedWords) == nil { status = "all" }
        arguments["status"] = .string(status)

        if clause.find(Self.overdueWords) != nil {
            arguments["due_to"] = ArgumentBuilders.dateTime(clause.context.now, calendar: calendar)
            arguments["status"] = "pending"
        } else if let window = ArgumentBuilders.window(when, calendar: calendar) {
            arguments["due_from"] = ArgumentBuilders.dateTime(window.start, calendar: calendar)
            arguments["due_to"] = ArgumentBuilders.dateTime(window.end, calendar: calendar)
        }
        if let list = Self.listFilterName(in: clause.text, dateConsumed: when.consumed) {
            arguments["list"] = .string(list)
        }
        return ToolCall(tool: .remindersList, arguments: arguments, assumptions: when.assumptions)
    }

    private static func listFilterName(in text: FoldedText, dateConsumed: [Range<Int>]) -> String? {
        let withoutDates = TextCleanup.trimConnectors(text.removing(dateConsumed))
        guard let match = withoutDates.findMatch(listFilter, groups: ["a", "b", "c", "d"]) else { return nil }
        guard let raw = match.original("a") ?? match.original("b") ?? match.original("c") ?? match.original("d") else { return nil }
        let name = TextCleanup.name(raw)
        let generic: Set<String> = ["my", "the", "reminders", "reminder", "recordatorios", "mi", "mis"]
        return name.isEmpty || generic.contains(name.lowercased()) ? nil : name
    }

    // MARK: Shared helpers

    /// Extracts a trailing list phrase ("to my Shopping list") and returns the text before it plus the list name.
    static func extractList(from text: FoldedText) -> (FoldedText, String?) {
        for regex in listPhrases {
            if let match = text.findMatch(regex, groups: ["before", "list"]), match.range.upperBound == text.count,
               let beforeRange = match.range("before"), let listRange = match.range("list") {
                let list = TextCleanup.name(text.original(listRange))
                guard !list.isEmpty else { continue }
                return (text.slice(beforeRange).collapsedWhitespace(), list)
            }
        }
        return (text, nil)
    }

    private static func mentionsRemindersApp(_ folded: String) -> Bool {
        folded.contains("reminders") || folded.contains("recordatorios") || folded.contains("reminder list")
    }

    private func splitListSuffix(_ title: String) -> (String, String?) {
        let (rest, list) = Self.extractList(from: FoldedText(title))
        return (TextCleanup.title(rest.original), list)
    }

    private static func stripPrefix(_ regex: NSRegularExpression, from text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: FoldedText(text).folded, range: range), match.range.location == 0, match.range.length > 0 else { return text }
        let folded = FoldedText(text)
        guard let converted = folded.firstMatch(regex), converted.range.lowerBound == 0, converted.range.upperBound < folded.count else { return text }
        return folded.original(converted.range.upperBound..<folded.count)
    }
}

private extension NSRegularExpression {
    /// Matches the whole of `text` and returns its original string, used for "…to my reminders" forms.
    func firstMatchWhole(in text: FoldedText) -> String? {
        guard let match = text.firstMatch(self, groupNames: ["before"]), match.range.upperBound == text.count,
              let before = match.group("before") else { return nil }
        return text.original(before)
    }
}
