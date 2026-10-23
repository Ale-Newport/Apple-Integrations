import Foundation
import JarvisCore

/// Words that begin a command. A conjunction only splits a multi-action command when the text that follows
/// starts with one of these ("… *and* remind me to study"), so "Add milk *and* eggs to my list" stays whole.
enum ClauseLexicon {
    private static let starters: Set<String> = [
        // English
        "play", "pause", "resume", "stop", "skip", "remind", "add", "create", "make", "set", "show", "list", "search",
        "find", "read", "open", "schedule", "move", "reschedule", "delete", "remove", "cancel", "mark", "complete",
        "turn", "start", "wake", "what", "whats", "what's", "how", "tell", "put", "append", "update", "change", "rename",
        "edit", "check", "get", "give", "new", "take", "unpause", "mute", "unmute", "lower", "raise", "increase",
        "decrease", "volume", "book", "plan", "write", "jot", "do", "am", "are", "is", "shuffle", "queue", "enable",
        "calculate", "compute", "convert", "calcula", "convierte", "disable", "switch", "postpone", "push", "display", "clear", "run", "begin", "bring", "i",
        // Spanish
        "reproduce", "reproducir", "pon", "ponme", "poner", "ponga", "pausa", "pausar", "deten", "detener", "parar",
        "salta", "saltar", "recuerdame", "recuerda", "recordar", "agrega", "agregar", "agregame", "anade", "anadir",
        "anademe", "crea", "crear", "creame", "programa", "programar", "muestra", "muestrame", "mostrar", "lista",
        "listar", "busca", "buscar", "encuentra", "lee", "leer", "abre", "abrir", "agenda", "agendar", "mueve",
        "mover", "reprograma", "reprogramar", "elimina", "eliminar", "borra", "borrar", "cancela", "cancelar", "marca",
        "marcar", "completa", "completar", "apaga", "apagar", "enciende", "encender", "inicia", "iniciar", "empieza",
        "despiertame", "que", "cuales", "cual", "cuanto", "dime", "anota", "anotar", "apunta", "apuntar", "actualiza",
        "actualizar", "cambia", "cambiar", "renombra", "edita", "editar", "revisa", "consulta", "sube", "baja",
        "silencia", "activa", "desactiva", "habilita", "deshabilita", "guarda", "toca", "escucha", "reserva",
        "pospon", "adelanta", "atrasa", "haz", "estoy", "tengo", "hay", "ve", "ver",
    ]

    private static let multiWordStarters: [String] = [
        "next song", "next track", "previous song", "previous track", "siguiente cancion", "cancion siguiente",
        "cancion anterior", "anterior cancion", "next one", "go back", "turn off", "turn on", "set up",
    ]

    private static let fillers: Set<String> = ["please", "por", "favor", "also", "tambien", "then", "luego", "ok", "okay", "ahora", "now", "and", "y", "e", "just"]

    static func startsClause(_ foldedRemainder: String) -> Bool {
        var words = foldedRemainder.split(separator: " ").map(String.init)
        while let first = words.first, fillers.contains(first) { words.removeFirst() }
        guard let first = words.first else { return false }
        let joined = words.prefix(2).joined(separator: " ")
        if multiWordStarters.contains(joined) { return true }
        // Bare "i" starts "i need to …" only when followed by a modal; avoid splitting on "and I" in prose.
        if first == "i" { return false }
        return starters.contains(first)
    }
}

enum ClauseSplitter {
    private static let conjunctions = "and then|and also|and|then|also|after that|afterwards|plus|y luego|y despues|y tambien|y ademas|luego|despues|tambien|ademas|y|e"
    private static let separator = Rx.make(
        #"(?:\s*[;,]\s*(?:(?:\#(conjunctions))\s+)?|\s*[.!?]+\s+(?:(?:\#(conjunctions))\s+)?|\s+(?:\#(conjunctions))\s+)"#
    )

    /// Splits a masked, politeness-stripped command into independent clauses.
    /// - Parameter requireCommandStart: when `false` every separator splits (used as a second attempt when the
    ///   conservative split recognised nothing, so the understood part of a command can still run).
    static func split(_ text: FoldedText, requireCommandStart: Bool = true) -> [FoldedText] {
        let keepTogether = PayloadMasker.attributeRange(in: text)
        // List/section prefixes belong to the following reminder creation, including the comma before "add".
        let reminderPrefix = text.firstMatch(Rx.make(#"^(?:en|in|on)\s+(?:(?:la|mi|the|my)\s+)?(?:lista|list)\s+.+?\b(?:anade|agrega|pon|add|put)\s+"#))?.range ?? text.firstMatch(Rx.make(#"^(?:pon|put)\s+(?:en|in)\s+.+?\s+(?:que|that)\s+"#))?.range
        let candidates = text.matches(separator).filter { candidate in
            if let reminderPrefix, reminderPrefix.overlaps(candidate.range) { return false }
            guard let keepTogether else { return true }
            return !keepTogether.overlaps(candidate.range)
        }
        guard !candidates.isEmpty else { return [text] }

        var clauses: [FoldedText] = []
        var clauseStart = 0
        for candidate in candidates {
            guard candidate.range.lowerBound > clauseStart else { continue }
            let remainder = text.foldedSlice(candidate.range.upperBound..<text.count)
            guard !requireCommandStart || ClauseLexicon.startsClause(remainder) else { continue }
            guard candidate.range.upperBound < text.count else { continue }
            clauses.append(text.slice(clauseStart..<candidate.range.lowerBound).collapsedWhitespace())
            clauseStart = candidate.range.upperBound
        }
        clauses.append(text.slice(clauseStart..<text.count).collapsedWhitespace())
        return clauses.filter { !$0.isEmpty }
    }
}

enum Politeness {
    private static let leading = Rx.make(
        #"^(?:(?:hey|hi|hello|ok|okay|so|well|then|thanks|thank you|thx|oye|hola|vale|bueno|gracias|ahora|entonces|luego)[,\s]+){0,3}(?:jarvis[,\s]+)?(?:(?:please|por favor|pls|porfa)[,\s]+)?(?:(?:can|could|would|will) you(?: please)?[,\s]+|(?:me )?(?:puedes|podrias|podria|puede)(?: por favor)?[,\s]+|i(?:'d| would) like (?:you )?to[,\s]+|i want (?:you )?to[,\s]+|i need you to[,\s]+|quiero que (?:me )?|necesito que (?:me )?|me gustaria que (?:me )?|(?:please|por favor)[,\s]+)?"#
    )
    private static let trailing = Rx.make(#"[,\s]*(?:please|por favor|thanks|thank you|gracias|pls|porfa|for me|por mi)[.!\s]*$"#)

    /// Removes greeting/please/"can you" prefixes and "please/thanks" suffixes, keeping character alignment.
    static func strip(_ text: FoldedText) -> FoldedText {
        var current = text
        if let match = current.firstMatch(leading), match.range.lowerBound == 0, match.range.upperBound > 0, match.range.upperBound < current.count {
            current = current.slice(match.range.upperBound..<current.count)
        }
        if let match = current.firstMatch(trailing), match.range.upperBound == current.count, match.range.lowerBound > 0, !current.isMasked(match.range) {
            current = current.slice(0..<match.range.lowerBound)
        }
        return current.collapsedWhitespace()
    }
}
