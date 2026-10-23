import Foundation
import JarvisCore

/// English/Spanish rules for Apple Notes. Free-form payloads (note bodies) arrive masked, see `PayloadMasker`.
struct NotesRules: IntentRuleSet {
    private static let mask = "\u{E000}"
    private static let noteNoun = #"(?:note|nota|apunte)"#

    private static let createVerb = #"(?:create|make|new|add|write|take|start|compose|crea|crear|haz|escribe|escribir|nueva|nuevo|toma|redacta|genera)"#
    private static let createNote = Rx.make(#"^\#(createVerb)\s+(?:(?:a|an|una|un|new|nueva|nuevo|another|otra|otro)\s+)*\#(noteNoun)\b(?<rest>.*)$"#)
    private static let quickNote = Rx.make(#"^(?:take (?:a )?note|jot down|write down|note to self|make a note|new note|toma nota|nueva nota|anota|apunta|anotar|apuntar|nota|note)\s*(?:[:\-]\s*|that\s+|que\s+|de que\s+|\s+)(?<content>.+)$"#)
    private static let quickNoteBare = Rx.make(#"^(?:take (?:a )?note|jot down|write down|make a note|toma nota)$"#)

    private static let titleMarker = Rx.make(#"(?:^|\s)(?:called|named|titled|entitled|with the (?:title|name)|with (?:title|name)|llamada|llamado|titulada|titulado|con el (?:titulo|nombre)|con (?:titulo|nombre)|title)\s*:?\s+(?<title>.+)$"#)
    private static let contentMarker = Rx.make(#"(?:^|\s)(?:with(?: the)?(?: following)?(?: content| text| body| message)?|containing|saying|that says|which says|reading|content|text|body|con(?: el)?(?: siguiente)?(?: contenido| texto| cuerpo)?|contenido|texto|que diga|que dice|diciendo|conteniendo)\s*[:\-]?\s*(?<content>\#(mask)+)\s*$"#)
    private static let trailingPayload = Rx.make(#"\s*[:\-]\s*(?<content>\#(mask)+)\s*$"#)
    private static let folderAtEnd = Rx.make(#"\s+(?:in|inside|into|within|under|en|dentro de)\s+(?:my\s+|the\s+|mi\s+|la\s+|el\s+)?(?:(?:folder|carpeta)\s+(?<f1>\S+(?:\s+\S+){0,2})|(?<f2>\S+(?:\s+\S+){0,2})\s+(?:folder|carpeta))\s*$"#)
    private static let folderAtStart = Rx.make(#"^\s*(?:in|inside|into|within|under|en|dentro de)\s+(?:my\s+|the\s+|mi\s+|la\s+|el\s+)?(?:(?:folder|carpeta)\s+(?<f1>\S+(?:\s+\S+){0,2}?)|(?<f2>\S+(?:\s+\S+){0,2}?)\s+(?:folder|carpeta))(?=\s+(?:called|named|titled|with|containing|saying|llamada|llamado|titulada|titulado|con|que)\b|\s*$)"#)

    private static let noteRef = #"(?:(?:my|the|mi|la|el)\s+)?(?:note\s+(?:called\s+|named\s+|titled\s+|llamada\s+|titulada\s+)?(?<t1>[^\#(mask):]+?)|nota\s+(?:llamada\s+|titulada\s+|de\s+)?(?<t3>[^\#(mask):]+?)|(?<t2>[^\#(mask):]+?)\s+note|(?<t4>[^\#(mask):]+?)\s+nota)"#

    private static let appendVerb = #"(?:append|add|insert|attach|put|write|agrega|agregar|anade|anadir|adjunta|pon|poner|escribe|incluye|inserta)"#
    private static let appendPattern = Rx.make(#"^(?<verb>\#(appendVerb))\s+(?<what>.+?)\s+(?:to|onto|at the end of|in|into|a|al final de|en|al)\s+\#(noteRef)\s*[:,]?\s*(?<payload>\#(mask)+)?$"#)
    private static let appendToNote = Rx.make(#"^(?<verb>\#(appendVerb))\s+(?:to|onto|a|al)\s+\#(noteRef)\s*[:,]?\s*(?<payload>\#(mask)+)$"#)
    private static let inNoteAdd = Rx.make(#"^(?:in|en)\s+\#(noteRef)\s*,?\s*(?:\#(appendVerb))\s*[:,]?\s*(?<payload>\#(mask)+|.+)$"#)
    private static let addToNotes = Rx.make(#"^(?:add|put|write|save|jot|agrega|agregar|anade|anadir|pon|poner|escribe|guarda)\s+(?<content>.+?)\s+(?:to|in|into|on|a|en|al)\s+(?:my\s+|the\s+|mis\s+|las\s+)?(?:notes|notas)$"#)
    private static let deicticWhat = Rx.make(#"^(?:this|the following|these|that|those|esto|este|esta|estos|estas|el siguiente|la siguiente|lo siguiente)\b.*$|^(?:a |an |un |una )?(?:paragraph|line|text|note|sentence|item|parrafo|linea|texto|frase)s?$"#)

    private static let updatePattern = Rx.make(#"^(?:replace|update|change|set|overwrite|rewrite|reemplaza|reemplazar|actualiza|actualizar|cambia|cambiar|sobrescribe|reescribe)\s+(?:the\s+|el\s+)?(?:content|contents|text|body|contenido|texto|cuerpo)\s+(?:of|in|de|en)\s+\#(noteRef)\s+(?:with|to|by|con|por|a)\s*[:,]?\s*(?<payload>\#(mask)+)$"#)
    private static let updateSay = Rx.make(#"^(?:update|change|set|actualiza|cambia)\s+\#(noteRef)\s+(?:to say|to read|so it says|para que diga|a)\s*[:,]?\s*(?<payload>\#(mask)+)$"#)

    private static let readPattern = Rx.make(#"^(?:read|show|open|display|get|see|print|give|pull up|bring up|lee|leer|leeme|muestra|muestrame|ensename|abre|abrir|abreme|dime|dame|ver)\s+(?:me\s+)?(?:(?:what|lo que)\s+(?:is\s+in\s+|esta\s+en\s+)?)?\#(noteRef)\s*\??$"#)
    private static let whatDoesSay = Rx.make(#"^(?:what(?:'s| is)?\s+(?:does\s+|in\s+)?|que\s+(?:dice|hay en|contiene|tiene)\s+)\#(noteRef)\s*(?:say|contain|have)?\s*\??$"#)
    private static let contentsOf = Rx.make(#"^(?:what(?:'s| is)? in|que hay en|contenido de)\s+\#(noteRef)\s*\??$"#)

    private static let searchNotes = Rx.make(#"^(?:search|find|look for|look up|busca|buscar|encuentra|encontrar)\s+(?:(?:in|through|en)\s+)?(?:(?:my|all|mis|todas mis)\s+)?(?:notes|notas)\s*(?:for|about|that mention|mentioning|containing|with|sobre|acerca de|que mencionen|que contengan|con|de)?\s*(?<q>.+)$"#)
    private static let searchNotesB = Rx.make(#"^(?:search|find|look for|busca|buscar|encuentra|encontrar)\s+(?:for\s+)?(?:(?:my|all my|mis|todas mis|mi)\s+)?(?:notes?|notas?)\s+(?:about|that mention|mentioning|containing|with|on|sobre|acerca de|que mencionen|que contengan|con|de)\s+(?<q>.+)$"#)
    private static let searchNotesC = Rx.make(#"^(?:search|find|look for|busca|buscar|encuentra)\s+(?:for\s+)?(?<q>.+?)\s+(?:in|within|among|en|entre)\s+(?:my\s+|all my\s+|mis\s+)?(?:notes|notas)$"#)

    private static let listNotes = Rx.make(#"^(?:list|show|display|get|see|what are|muestra|muestrame|lista|listar|ver|cuales son)\s+(?:me\s+)?(?:all\s+)?(?:(?:my|mis|the|las)\s+)?(?:(?:recent|latest|recientes|ultimas)\s+)?(?:notes|notas)(?:\s+(?:in|from|of|en|de)\s+(?:my\s+|the\s+|mi\s+|la\s+)?(?:(?:folder|carpeta)\s+(?<f1>.+)|(?<f2>.+?)\s+(?:folder|carpeta)))?\s*\??$"#)
    private static let listFolders = Rx.make(#"^(?:list|show|display|get|see|what are|muestra|muestrame|lista|listar|ver|cuales son)\s+(?:me\s+)?(?:all\s+)?(?:(?:my|mis|the|las)\s+)?(?:notes?\s+)?(?:folders|carpetas)(?:\s+(?:of|in|de|en)\s+(?:my\s+|mis\s+)?(?:notes|notas))?\s*\??$"#)

    private static let deletePattern = Rx.make(#"^(?:delete|remove|trash|erase|elimina|eliminar|borra|borrar|quita|quitar)\s+\#(noteRef)\s*$"#)

    private static let titleBefore = Rx.make(#"(?:note|nota|apunte)\s+(?:(?:called|named|titled|entitled|llamada|titulada)\s+)?$"#)
    private static let titleAfter = Rx.make(#"^\s*(?:note|nota|apunte)\b"#)
    private static let articlesOnly: Set<String> = ["my", "mi", "mis", "the", "a", "an", "la", "el", "un", "una", "this", "that", "esta", "este", "esa", "ese", "our", "your"]

    /// Quoted text is masked so that words inside it are never taken for commands. But a quoted span right after
    /// (or right before) the word "note" is the note's *title* — `read my note “Ideas”`, `show me my “Old Plans” note` —
    /// so for the commands that address a note those spans become ordinary text again. Payloads stay masked.
    private static func revealingNoteTitles(_ clause: Clause) -> Clause {
        let text = clause.text
        var revealed = text
        for run in text.maskedRuns() {
            let before = text.foldedSlice(0..<run.lowerBound)
            let after = text.foldedSlice(run.upperBound..<text.count)
            let beforeMatch = titleBefore.firstMatch(in: before, range: NSRange(before.startIndex..., in: before)).map { $0.range.upperBound == NSRange(before.startIndex..., in: before).upperBound } ?? false
            let afterMatch = titleAfter.firstMatch(in: after, range: NSRange(after.startIndex..., in: after)) != nil
            if beforeMatch || afterMatch { revealed = revealed.unmasking(run) }
        }
        return Clause(text: revealed, context: clause.context)
    }

    func interpret(_ clause: Clause) -> [RuleResult] {
        var results: [RuleResult] = []
        let text = clause.text
        let folded = clause.folded
        guard !folded.isEmpty else { return [] }
        let titled = Self.revealingNoteTitles(clause)

        // --- Folders / listing
        if clause.whole(Self.listFolders, groups: []) != nil {
            results.append(.calls([ToolCall(tool: .notesListFolders)], confidence: 0.92))
        }
        if let match = clause.whole(Self.listNotes, groups: ["f1", "f2"]) {
            var arguments: JSONObject = [:]
            if let folder = (match.original("f1") ?? match.original("f2")).map(TextCleanup.name), !folder.isEmpty { arguments["folder"] = .string(folder) }
            results.append(.calls([ToolCall(tool: .notesList, arguments: arguments)], confidence: 0.9))
        }

        // --- Search
        for regex in [Self.searchNotes, Self.searchNotesB, Self.searchNotesC] {
            if let match = clause.whole(regex, groups: ["q"]), let query = match.original("q").map(TextCleanup.name), !query.isEmpty {
                var arguments: JSONObject = ["query": .string(query)]
                if folded.contains("containing") || folded.contains("mention") || folded.contains("contengan") || folded.contains("mencionen") || folded.contains("body") {
                    arguments["scope"] = "any"
                }
                results.append(.calls([ToolCall(tool: .notesSearch, arguments: arguments)], confidence: 0.92))
                break
            }
        }

        // --- Append / update (payload-bearing)
        if let call = appendCall(titled) { results.append(call) }
        if let match = titled.whole(Self.updatePattern, groups: noteGroups + ["payload"]) ?? titled.whole(Self.updateSay, groups: noteGroups + ["payload"]),
           let title = noteTitle(match), let payload = match.original("payload") {
            results.append(.calls([ToolCall(tool: .notesUpdate, arguments: ["title": .string(title), "new_content": .string(payload)])], confidence: 0.93))
        }

        // --- Read
        for regex in [Self.readPattern, Self.whatDoesSay, Self.contentsOf] {
            if let match = titled.whole(regex, groups: noteGroups), let title = noteTitle(match) {
                let lowered = title.lowercased()
                // "show my notes" is a listing, not a note called "notes".
                if lowered == "notes" || lowered == "notas" || lowered == "all" { continue }
                results.append(.calls([ToolCall(tool: .notesRead, arguments: ["title": .string(title)])], confidence: 0.9))
                break
            }
        }

        // --- Delete
        if let match = titled.whole(Self.deletePattern, groups: noteGroups), let title = noteTitle(match) {
            results.append(.calls([ToolCall(tool: .notesDelete, arguments: ["title": .string(title)])], confidence: 0.92))
        }

        // --- Create
        if let call = createCall(clause) { results.append(call) }
        if let match = clause.whole(Self.addToNotes, groups: ["content"]), let content = match.original("content") {
            results.append(.calls([ToolCall(tool: .notesCreate, arguments: ["content": .string(TextCleanup.capitalizeFirst(content))])], confidence: 0.88))
        }
        if let match = clause.whole(Self.quickNote, groups: ["content"]), let content = match.original("content") {
            // "anota X" without the word note is weaker: it competes with reminders and lists.
            let explicit = folded.contains("note") || folded.contains("nota")
            let cleaned = TextCleanup.capitalizeFirst(content)
            results.append(.calls([ToolCall(tool: .notesCreate, arguments: ["content": .string(cleaned)])], confidence: explicit ? 0.9 : 0.5))
        } else if clause.whole(Self.quickNoteBare, groups: []) != nil {
            results.append(.clarify(
                LocalizedText(en: "What should the note say?", es: "¿Qué debe decir la nota?"), confidence: 0.85
            ))
        }
        _ = text
        return results
    }

    // MARK: Helpers

    private var noteGroups: [String] { ["t1", "t2", "t3", "t4"] }

    private func noteTitle(_ match: MatchedClause) -> String? {
        guard let raw = match.original("t1") ?? match.original("t2") ?? match.original("t3") ?? match.original("t4") else { return nil }
        let title = TextCleanup.name(raw)
        // "add this to my note" names no note: "my" is the possessive, not a title.
        if title.isEmpty || Self.articlesOnly.contains(TextFolding.fold(title)) { return nil }
        return title
    }

    private func appendCall(_ clause: Clause) -> RuleResult? {
        let groups = noteGroups + ["verb", "what", "payload"]
        if let match = clause.whole(Self.appendToNote, groups: groups) ?? clause.whole(Self.inNoteAdd, groups: groups) {
            guard let title = noteTitle(match), let payload = match.original("payload") else { return nil }
            return .calls([ToolCall(tool: .notesAppend, arguments: ["title": .string(title), "text": .string(payload)])], confidence: 0.93)
        }
        guard let match = clause.whole(Self.appendPattern, groups: groups), let title = noteTitle(match) else { return nil }
        let what = match.original("what") ?? ""
        let payload = match.original("payload")
        let foldedWhat = TextCleanup.name(what)
        var text: String?
        if let payload, !payload.isEmpty {
            // "append this paragraph to my X note: <payload>" → the payload is the text.
            let isDeictic = FoldedText(foldedWhat).wholeMatch(Self.deicticWhat) != nil || foldedWhat.isEmpty
            text = isDeictic ? payload : foldedWhat + "\n" + payload
        } else if !foldedWhat.isEmpty {
            text = foldedWhat
        }
        guard let text, !text.isEmpty else { return nil }
        // "add milk to my shopping note" is an append; "add X to my calendar/list" never reaches here (needs the word note).
        let isDeictic = FoldedText(foldedWhat).wholeMatch(Self.deicticWhat) != nil
        if payload == nil && isDeictic {
            // "append this paragraph to my X note" with nothing to append.
            return .clarify(LocalizedText(en: "What text should I add to the note?", es: "¿Qué texto debo añadir a la nota?"), confidence: 0.85)
        }
        return .calls([ToolCall(tool: .notesAppend, arguments: ["title": .string(title), "text": .string(text)])], confidence: 0.9)
    }

    private func createCall(_ clause: Clause) -> RuleResult? {
        guard let match = clause.whole(Self.createNote, groups: ["rest"]), let restRange = match.range("rest") else { return nil }
        var rest = clause.text.slice(restRange).collapsedWhitespace()
        // "take a note: buy milk" is a quick note, handled by the `quickNote` rule.
        if let first = rest.foldedCharacters.first, first == ":" || first == "-" { return nil }

        var content: String?
        if let found = rest.findMatch(Self.contentMarker, groups: ["content"]) ?? rest.findMatch(Self.trailingPayload, groups: ["content"]),
           let range = found.range("content") {
            content = FoldedText.unquote(rest.original(range))
            rest = rest.removing([found.range]).collapsedWhitespace()
        }

        var folder: String?
        if let found = rest.findMatch(Self.folderAtEnd, groups: ["f1", "f2"]), found.range.upperBound == rest.count {
            folder = (found.original("f1") ?? found.original("f2")).map(TextCleanup.name)
            rest = rest.removing([found.range]).collapsedWhitespace()
        } else if let found = rest.findMatch(Self.folderAtStart, groups: ["f1", "f2"]), found.range.lowerBound == 0 {
            folder = (found.original("f1") ?? found.original("f2")).map(TextCleanup.name)
            rest = rest.removing([found.range]).collapsedWhitespace()
        }

        var title: String?
        if let found = rest.findMatch(Self.titleMarker, groups: ["title"]), let range = found.range("title") {
            title = TextCleanup.title(rest.original(range))
            rest = rest.removing([found.range]).collapsedWhitespace()
        }

        // Whatever is left over has no marker: a bare payload is the note's text.
        let leftover = TextCleanup.name(rest.original)
        let leftoverIsPayload = !leftover.isEmpty && leftover.lowercased() != "about" && leftover.lowercased() != "sobre"
        if content == nil, title == nil, leftoverIsPayload {
            content = leftover
        } else if title == nil, content != nil, leftoverIsPayload {
            title = TextCleanup.title(leftover)
        }

        if title == nil, content == nil {
            return .clarify(LocalizedText(en: "What should the note be called or say?", es: "¿Cómo se llama la nota o qué debe decir?"), confidence: 0.8)
        }
        var arguments: JSONObject = [:]
        if let title, !title.isEmpty { arguments["title"] = .string(title) }
        if let content, !content.isEmpty { arguments["content"] = .string(content) }
        if let folder, !folder.isEmpty { arguments["folder"] = .string(folder) }
        return .calls([ToolCall(tool: .notesCreate, arguments: arguments)], confidence: 0.95)
    }
}

/// Masks free-form payloads (note bodies and appended text) so the clause splitter and the other rule sets never
/// interpret them. Everything after "with the following content:" or a trailing colon belongs to the payload.
enum PayloadMasker {
    private static let markers: [NSRegularExpression] = [
        Rx.make(#"(?:^|\s)(?:with(?: the)? following(?: content| text| body| message)?|with(?: the)? (?:content|text|body)|containing|which says|that says|saying|reading|con(?: el)? siguiente(?: contenido| texto| cuerpo| mensaje)?|con(?: el)? (?:contenido|texto|cuerpo)|diciendo|conteniendo)\s*[:\-]?\s+"#),
        // "una nota que dice …" introduces a payload, but a question that STARTS with it ("¿qué dice mi nota?") does not.
        Rx.make(#"\s(?:que diga|que dice)\s*[:\-]?\s+"#),
        Rx.make(#"(?:^|\s)(?:content|text|body|contenido|texto|cuerpo)\s*:\s*"#),
    ]
    private static let noteWord = Rx.make(#"\b(?:note|notes|nota|notas|apunte)\b"#)
    private static let colon = Rx.make(#"\s*:\s*(?=\S)"#)
    private static let quickNoteLead = Rx.make(#"^(?:take (?:a )?note|jot down|write down|note to self|make a note|toma nota|anota|apunta|anotar|apuntar|nota|note)\s*(?:[:\-]\s*|that\s+|que\s+|de que\s+|\s+)"#)

    private static let createNoteStart = Rx.make(#"\b(?:create|make|new|add|write|take|start|compose|crea|crear|haz|escribe|escribir|nueva|nuevo|toma|redacta|genera)\s+(?:(?:a|an|una|un|new|nueva|nuevo|another|otra|otro)\s+)*(?:note|nota|apunte)\b"#)

    /// The part of a note-creation command that precedes its content ("create a note called Plan and Review with the
    /// following content: …"). Separators inside it belong to the note's title/folder and must not split the command.
    static func attributeRange(in text: FoldedText) -> Range<Int>? {
        guard let start = text.firstMatch(createNoteStart) else { return nil }
        var end: Int?
        for marker in markers {
            for match in text.matches(marker) where match.range.lowerBound > start.range.lowerBound && !text.isMasked(match.range) {
                end = min(end ?? Int.max, match.range.lowerBound)
                break
            }
        }
        guard let end, end > start.range.lowerBound else { return nil }
        return start.range.lowerBound..<end
    }

    static func apply(to text: FoldedText) -> FoldedText {
        var result = text
        let hasNote = result.firstMatch(noteWord) != nil
        let quick = result.firstMatch(quickNoteLead)

        // 1. "take a note: …" / "anota …": the whole remainder is the payload.
        if let quick, quick.range.lowerBound == 0, quick.range.upperBound < result.count, !result.isMasked(quick.range.upperBound..<result.count) {
            // Keep a leading quoted payload intact; otherwise everything is payload.
            return result.masking(quick.range.upperBound..<result.count)
        }
        guard hasNote else { return result }

        // 2. Explicit content markers.
        var earliest: Range<Int>?
        for marker in markers {
            for match in result.matches(marker) where !result.isMasked(match.range) {
                if earliest == nil || match.range.lowerBound < earliest!.lowerBound { earliest = match.range }
                break
            }
        }
        // 3. A colon after the note noun.
        if earliest == nil, let noteMatch = result.firstMatch(noteWord) {
            for match in result.matches(colon, from: noteMatch.range.upperBound) where !result.isMasked(match.range) {
                earliest = match.range
                break
            }
        }
        if let earliest, earliest.upperBound < result.count {
            let payload = earliest.upperBound..<result.count
            // A quoted payload ends at its closing quote; do not swallow what follows it.
            let leadingMasked = result.foldedCharacters[payload.lowerBound] == FoldedText.maskCharacter
            if !leadingMasked { result = result.masking(payload) }
        }
        return result
    }
}
