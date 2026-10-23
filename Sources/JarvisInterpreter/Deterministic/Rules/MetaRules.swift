import Foundation
import JarvisCore

/// Conversational commands that need no tools: help, greetings, thanks.
struct MetaRules: IntentRuleSet {
    private static let help = Rx.make(#"^(?:help|\?|ayuda|ayudame|auxilio|what can you do|what do you do|what can i say|what can i ask|que puedes hacer|que sabes hacer|que puedo decir|que haces|commands|comandos|como funciona|how does this work|how do i use this|capabilities|capacidades|examples|ejemplos)\s*[?!.]*$"#)
    private static let greeting = Rx.make(#"^(?:hi|hello|hey|hola|buenas|buenos dias|buenas tardes|buenas noches|good morning|good afternoon|good evening|yo|ey|hiya|que tal|como estas|how are you)(?:\s+jarvis)?\s*[?!.]*$"#)
    private static let thanks = Rx.make(#"^(?:thanks|thank you|thx|ty|gracias|muchas gracias|genial gracias|perfecto gracias|ok thanks|great thanks)(?:\s+jarvis)?\s*[!.]*$"#)
    private static let identity = Rx.make(#"^(?:who are you|what are you|quien eres|que eres|como te llamas|what is your name|what's your name)\s*[?!.]*$"#)

    func interpret(_ clause: Clause) -> [RuleResult] {
        let text = clause.folded
        if clause.whole(Self.help, groups: []) != nil { return [.reply(Self.helpText, confidence: 0.99)] }
        if clause.whole(Self.thanks, groups: []) != nil {
            return [.reply(LocalizedText(en: "You're welcome!", es: "¡De nada!"), confidence: 0.98)]
        }
        if clause.whole(Self.identity, groups: []) != nil {
            return [.reply(LocalizedText(
                en: "I'm Jarvis Apple Integrations: I turn what you type into real actions in Apple Music, Reminders, Notes, Calendar and Clock. Say “help” for examples.",
                es: "Soy Jarvis Apple Integrations: convierto lo que escribes en acciones reales en Apple Music, Recordatorios, Notas, Calendario y Reloj. Di «ayuda» para ver ejemplos."
            ), confidence: 0.98)]
        }
        if clause.whole(Self.greeting, groups: []) != nil, !text.isEmpty {
            return [.reply(LocalizedText(
                en: "Hello! Tell me what to do with Music, Reminders, Notes, Calendar or Clock — say “help” for examples.",
                es: "¡Hola! Dime qué hacer con Música, Recordatorios, Notas, Calendario o Reloj — di «ayuda» para ver ejemplos."
            ), confidence: 0.97)]
        }
        return []
    }

    static let helpText = LocalizedText(
        en: """
        I can control Apple Music, Reminders, Notes, Calendar and Clock. Try:
        • Play my Study playlist · Pause the music · What's playing? · Volume 40
        • Remind me tomorrow at 6 PM to submit my assignment · Add milk to my Shopping reminders list · Show my pending reminders
        • Create a note called Project Ideas with the following content: … · Append … to my Project Ideas note
        • What's on my calendar tomorrow? · Schedule a meeting with Daniel on Friday at 3 PM for one hour · Move my meeting to 4 PM
        • Set an alarm for 7:30 tomorrow morning · Set a timer for 10 minutes
        You can chain actions: “Play my Chill playlist and remind me to study at 8 PM”. I always ask before deleting anything.
        """,
        es: """
        Puedo controlar Apple Music, Recordatorios, Notas, Calendario y Reloj. Prueba:
        • Pon mi lista Study · Pausa la música · ¿Qué suena? · Volumen 40
        • Recuérdame mañana a las 6 PM entregar mi tarea · Agrega leche a mi lista de recordatorios Compras · Muestra mis recordatorios pendientes
        • Crea una nota llamada Ideas con el siguiente contenido: … · Añade … a mi nota Ideas
        • ¿Qué tengo en mi calendario mañana? · Agenda una reunión con Daniel el viernes a las 3 PM por una hora · Mueve mi reunión a las 4 PM
        • Pon una alarma a las 7:30 de la mañana · Pon un temporizador de 10 minutos
        Puedes encadenar acciones: «Pon mi lista Chill y recuérdame estudiar a las 8 PM». Siempre pregunto antes de borrar algo.
        """
    )
}
