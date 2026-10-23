import Foundation

/// A small, dependency-free detector for the two supported languages. It scores function words and
/// command verbs that only occur in one language; accents and Spanish punctuation add weight.
public enum LanguageDetector {
    private static let spanishWords: Set<String> = [
        "el", "la", "los", "las", "un", "una", "unos", "unas", "de", "del", "al", "para", "por", "con", "sin", "mi", "mis", "tu",
        "que", "qué", "y", "o", "en", "es", "es", "está", "esta", "este", "muy", "pero", "también", "mañana", "hoy", "ayer",
        "pon", "ponme", "reproduce", "pausa", "pausar", "detén", "detener", "para", "siguiente", "anterior", "sube", "baja",
        "recuérdame", "recuerdame", "recuerda", "recordatorio", "recordatorios", "agrega", "agregar", "añade", "añadir", "anade",
        "crea", "crear", "muestra", "muéstrame", "muestrame", "lista", "listas", "busca", "buscar", "lee", "abre", "agenda",
        "agendar", "programa", "programar", "mueve", "mover", "reprograma", "elimina", "eliminar", "borra", "borrar", "cancela",
        "cancelar", "marca", "completa", "apaga", "enciende", "alarma", "alarmas", "temporizador", "reunión", "reunion", "cita",
        "nota", "notas", "carpeta", "calendario", "evento", "eventos", "semana", "mes", "lunes", "martes", "miércoles",
        "miercoles", "jueves", "viernes", "sábado", "sabado", "domingo", "tarde", "noche", "hora", "horas", "minutos",
        "canción", "cancion", "música", "musica", "volumen", "despiértame", "despiertame", "dime", "cuál", "cuales", "tengo",
        "tienes", "hay", "ayuda", "gracias", "sí", "si", "dale", "vale", "próximo", "proximo", "próxima", "proxima", "luego",
        "después", "despues", "durante", "llamada", "llamado", "llamada", "contenido", "siguiente", "título", "titulo",
    ]

    private static let englishWords: Set<String> = [
        "the", "a", "an", "to", "of", "my", "me", "on", "at", "in", "for", "and", "then", "with", "from", "is", "are", "what",
        "what's", "whats", "please", "play", "pause", "resume", "stop", "next", "previous", "skip", "remind", "reminder",
        "reminders", "add", "create", "show", "list", "search", "find", "read", "open", "schedule", "move", "reschedule",
        "delete", "remove", "cancel", "mark", "complete", "turn", "set", "alarm", "alarms", "timer", "meeting", "appointment",
        "note", "notes", "folder", "calendar", "event", "events", "week", "month", "tomorrow", "today", "tonight", "yesterday",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "morning", "afternoon", "evening",
        "night", "hour", "hours", "minutes", "song", "music", "volume", "wake", "tell", "have", "do", "does", "how", "playlist",
        "content", "called", "named", "titled", "following", "yes", "thanks", "help", "append", "update", "lasting", "next",
    ]

    /// Words that exist in both languages or are too ambiguous to count.
    private static let neutral: Set<String> = ["no", "ok", "a", "si", "es", "para", "me", "mi", "in", "on"]

    public static func detect(_ text: String, fallback: Language = .en) -> Language {
        var spanish = 0.0
        var english = 0.0

        if text.contains("¿") || text.contains("¡") { spanish += 3 }
        if text.range(of: "[ñáéíóúü]", options: [.regularExpression, .caseInsensitive]) != nil { spanish += 1.5 }

        let words = text.lowercased().split(whereSeparator: { !($0.isLetter || $0 == "'" || $0 == "’") }).map(String.init)
        for word in words {
            if neutral.contains(word) { continue }
            let folded = TextFolding.fold(word)
            if spanishWords.contains(word) || spanishWords.contains(folded) { spanish += 1 }
            if englishWords.contains(word) || englishWords.contains(folded) { english += 1 }
        }

        if spanish > english { return .es }
        if english > spanish { return .en }
        return fallback
    }
}
