import Foundation

/// Regular expressions for English and Spanish date/time vocabulary. All patterns run on *folded* text
/// (lowercase, no diacritics), so "miércoles" is written `miercoles` and "mañana" is `manana`.
enum DateLexicon {
    static let num = NumberWords.fragment

    // MARK: Vocabulary

    static let weekdayNumbers: [String: Int] = [
        "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4, "thursday": 5, "friday": 6, "saturday": 7,
        "sun": 1, "mon": 2, "tue": 3, "tues": 3, "wed": 4, "thu": 5, "thur": 5, "thurs": 5, "fri": 6, "sat": 7,
        "domingo": 1, "lunes": 2, "martes": 3, "miercoles": 4, "jueves": 5, "viernes": 6, "sabado": 7,
    ]

    static let monthNumbers: [String: Int] = [
        "january": 1, "february": 2, "march": 3, "april": 4, "may": 5, "june": 6, "july": 7, "august": 8,
        "september": 9, "october": 10, "november": 11, "december": 12,
        "jan": 1, "feb": 2, "mar": 3, "apr": 4, "jun": 6, "jul": 7, "aug": 8, "sep": 9, "sept": 9, "oct": 10, "nov": 11, "dec": 12,
        "enero": 1, "febrero": 2, "marzo": 3, "abril": 4, "mayo": 5, "junio": 6, "julio": 7, "agosto": 8,
        "septiembre": 9, "setiembre": 9, "octubre": 10, "noviembre": 11, "diciembre": 12,
        "ene": 1, "abr": 4, "ago": 8, "dic": 12,
    ]

    private static func alternation(_ words: some Sequence<String>) -> String {
        words.sorted { $0.count > $1.count }.joined(separator: "|")
    }

    static let weekdayFull = "sunday|monday|tuesday|wednesday|thursday|friday|saturday|domingo|lunes|martes|miercoles|jueves|viernes|sabado"
    static let weekdayAbbreviated = "sun|mon|tues?|wed|thu(?:rs?)?|fri|sat"
    static let monthWords = alternation(monthNumbers.keys)

    // MARK: Durations

    static let unitWord = "hours?|hrs?|hr|minutes?|mins?|min|seconds?|secs?|sec|days?|weeks?|months?|years?|horas?|minutos?|segundos?|segs?|dias?|semanas?|meses|mes|anos?"
    static let digitsQuantity = #"\d+(?:[.,]\d+)?"#
    static let wordQuantity = "(?:\(num)|an?|one|un|una|half|media|medio)"
    /// `2 hours`, `90min`, `1h`, `an hour`, `dos horas`
    static let component = "(?:(?:\(digitsQuantity))\\s*(?:\(unitWord)|h|m)(?![a-z])|\(wordQuantity)\\s+(?:\(unitWord))(?![a-z]))"
    static let halfHour = #"(?:half\s+an\s+hour|a\s+half\s+hour|half\s+a\s+hour|half\s+hour|media\s+hora|medio\s+hora)"#
    static let andHalf = #"(?:and\s+a\s+half|and\s+an\s+half|and\s+half|y\s+media|y\s+medio)"#
    /// One or more components, optionally joined by "and", "y", commas, with an optional "and a half".
    /// `1h30`, `1h 30m`, `2h15`
    static let compactHoursMinutes = #"\d+\s*h\s*\d{1,2}(?:\s*m(?:in)?)?(?![a-z\d])"#
    static let durationExpression = "(?:\(compactHoursMinutes)|\(halfHour)|\(component)(?:\\s*(?:,|and|y|e|&)?\\s*(?:\(component)|\(halfHour)|\(andHalf)))*(?:\\s*\(andHalf))?|\(component)\\s+y\\s+media)"

    // MARK: Patterns

    static func regex(_ pattern: String) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: [])
        } catch {
            preconditionFailure("Invalid date pattern: \(pattern)\n\(error)")
        }
    }

    // Day offsets
    static let dayAfterTomorrow = regex(#"(?<![a-z])(?:(?:the\s+)?day\s+after\s+tomorrow|pasado\s+manana)(?![a-z])"#)
    static let tomorrow = regex(#"(?<![a-z])(?:tomorrow|tmrw|tmr)(?![a-z])"#)
    static let spanishTomorrow = regex(#"(?<!\bla )(?<!\besta )(?<!\bpor la )(?<!\bde la )(?<!\ben la )(?<!\ba la )(?<!\btoda la )(?<!\bpasado )(?<![a-z])manana(?![a-z])"#)
    static let today = regex(#"(?<![a-z])(?:today|hoy)(?![a-z])"#)
    static let yesterday = regex(#"(?<![a-z])(?:yesterday|ayer)(?![a-z])"#)
    static let dayBeforeYesterday = regex(#"(?<![a-z])(?:the\s+day\s+before\s+yesterday|anteayer|antes\s+de\s+ayer)(?![a-z])"#)
    static let tonight = regex(#"(?<![a-z])(?:tonight|esta\s+noche)(?![a-z])"#)
    static let lastNight = regex(#"(?<![a-z])(?:last\s+night|anoche)(?![a-z])"#)

    // Parts of the day
    static let partOfDayEnglish = regex(#"(?<![a-z])(?:(?:in|during|this|at|every)\s+(?:the\s+)?)?(?<pod>morning|afternoon|evening|night)(?![a-z])"#)
    static let partOfDaySpanish = regex(#"(?<![a-z])(?:(?:por|en|de|durante|a)\s+la\s+|esta\s+)(?<pod>manana|tarde|noche|madrugada)(?![a-z])"#)
    static let namedTime = regex(#"(?<![a-z])(?<name>noon|midday|midnight|mediodia|medianoche)(?![a-z])"#)

    // Weekdays
    static let weekdayEnglish = regex(#"(?<![a-z])(?:on\s+)?(?:(?<mod>this|next|last|coming|upcoming|following)\s+)?(?<wd>\#(weekdayFull))(?![a-z])"#)
    static let weekdayEnglishAbbreviated = regex(#"(?<![a-z])(?:on|this|next|last)\s+(?:(?<mod>this|next|last)\s+)?(?<wd>\#(weekdayAbbreviated))\.?(?![a-z])"#)
    static let weekdaySpanish = regex(#"(?<![a-z])(?:(?:el|este|para el)\s+)?(?:(?<mod>este|proximo|pasado|ultimo)\s+)?(?<wd>domingo|lunes|martes|miercoles|jueves|viernes|sabado)(?:\s+(?<mod2>proximo|pasado|que\s+viene|siguiente))?(?![a-z])"#)

    // Spans
    static let spanEnglish = regex(#"(?<![a-z])(?:(?:for|during|in|on)\s+)?(?<mod>this|next|last|coming|upcoming|following)\s+(?<scope>week|weekend|month|year)(?![a-z])"#)
    static let spanSpanish = regex(#"(?<![a-z])(?:(?:para|durante|en)\s+)?(?:(?<art>esta|este|la|el)\s+)?(?:(?<mod>proxima|proximo|siguiente|pasada|pasado)\s+)?(?<scope>semana|fin\s+de\s+semana|mes|ano)(?:\s+(?<mod2>que\s+viene|proxima|proximo|pasada|pasado|siguiente))?(?![a-z])"#)
    static let nextDays = regex(#"(?<![a-z])(?:in\s+)?(?:the\s+)?(?:next|coming|upcoming|following|proximos|proximas|siguientes)\s+(?<n>\#(num))\s+(?<unit>days?|weeks?|dias?|semanas?)(?![a-z])"#)

    // Absolute dates
    static let isoDate = regex(#"(?<![\d])(?<y>\d{4})-(?<m>\d{2})-(?<d>\d{2})(?![\d])"#)
    static let monthFirst = regex(#"(?<![a-z])(?:on\s+)?(?:the\s+)?(?<mon>\#(monthWords))\.?\s+(?<day>\d{1,2})(?:st|nd|rd|th)?(?:\s*,?\s*(?<year>\d{4}))?(?![\d:]|\s*(?:am|pm|a\.m|p\.m))"#)
    static let dayFirst = regex(#"(?<![a-z\d])(?:on\s+)?(?:the\s+)?(?<day>\d{1,2})(?:st|nd|rd|th)?\s+(?:of\s+)?(?<mon>\#(monthWords))\.?(?:\s*,?\s*(?<year>\d{4}))?(?![a-z])"#)
    static let spanishDate = regex(#"(?<![a-z\d])(?:el\s+)?(?<day>\d{1,2})\s+de\s+(?<mon>\#(monthWords))(?:\s+(?:de|del)\s+(?<year>\d{4}))?(?![a-z])"#)
    static let numericDate = regex(#"(?<![\d/.:-])(?<a>\d{1,2})[/-](?<b>\d{1,2})(?:[/-](?<y>\d{2,4}))?(?![\d/:-]|\s*(?:am|pm|a\.m|p\.m|h\b))"#)
    static let dottedDate = regex(#"(?<![\d/.:-])(?<a>\d{1,2})\.(?<b>\d{1,2})\.(?<y>\d{4})(?![\d])"#)
    static let ordinalEnglish = regex(#"(?<![a-z])(?:on\s+)?the\s+(?<day>\d{1,2})(?:st|nd|rd|th)(?![a-z])"#)
    static let ordinalSpanish = regex(#"(?<![a-z\d])el\s+(?<day>\d{1,2})(?![\d:]|\s*(?:de\s|h\b|horas|hrs|am|pm|%|\w*\s*(?:minutos|horas|dias)))(?![a-z])"#)

    // Relative offsets and durations
    static let relativeIn = regex(#"(?<![a-z])(?:in|within|dentro\s+de|en|de\s+aqui\s+a)\s+(?<dur>\#(durationExpression))"#)
    static let relativeFromNow = regex(#"(?<![a-z\d])(?<dur>\#(durationExpression))\s+(?:from\s+now|from\s+today|later|mas\s+tarde|desde\s+ahora)(?![a-z])"#)
    static let durationWithPreposition = regex(#"(?<![a-z])(?:for|lasting|last(?:s|ing)?|during|of|that\s+lasts|which\s+lasts|lasts|durante|por|de|que\s+dure|con\s+(?:una\s+)?duracion\s+de|duracion\s+de|duration|dura)\s+(?<dur>\#(durationExpression))"#)
    static let durationLong = regex(#"(?<![a-z\d])(?<dur>\#(durationExpression))\s+(?:long|de\s+duracion)(?![a-z])"#)
    static let bareDuration = regex(#"(?<![a-z\d.,])(?<dur>\#(durationExpression))"#)
    static let durationComponent = regex(#"(?<![a-z\d])(?<qty>\d+(?:[.,]\d+)?|\#(num)|an?|one|un|una|half|media|medio)\s*(?<unit>\#(unitWord)|h|m)(?![a-z])"#)

    // Clock times
    static let timeRange = regex(#"(?<![a-z\d:])(?:(?:from|de|entre)\s+(?:las?\s+)?)?(?<h1>\d{1,2})(?::(?<m1>[0-5]\d))?\s*(?<mer1>a\.?\s?m\.?|p\.?\s?m\.?)?\s*(?:-|to|until|till|a|y|hasta|and)\s*(?:las?\s+)?(?<h2>\d{1,2})(?::(?<m2>[0-5]\d))?\s*(?<mer2>a\.?\s?m\.?|p\.?\s?m\.?)?(?![a-z\d:])"#)
    static let clockColon = regex(#"(?<![\d:.,/-])(?:(?:at|@|by|around|about|a\s+las?|para\s+las?|hacia\s+las?|desde\s+las?|hasta\s+las?)\s+)?(?<h>[01]?\d|2[0-3]):(?<m>[0-5]\d)(?::[0-5]\d)?\s*(?<mer>a\.?\s?m\.?|p\.?\s?m\.?)?(?:\s*(?:h|hs|hrs|horas))?(?![\d:])"#)
    static let clockMeridiem = regex(#"(?<![\d:.,/-])(?:(?:at|@|by|around|about|a\s+las?|para\s+las?)\s+)?(?<h>1[0-2]|0?[1-9])(?:\.(?<m>[0-5]\d))?\s*(?<mer>a\.?\s?m\.?|p\.?\s?m\.?)(?![a-z])"#)
    static let clockOClock = regex(#"(?<![\d:.,/-])(?:(?:at|by|around|about)\s+)?(?<h>\#(num))\s*o'?\s*clock(?![a-z])"#)
    static let clockAt = regex(#"(?<![a-z\d:.,/-])(?:at|@|by|around|about)\s+(?<h>\#(num))(?![\d:.,/%-]|\s*(?:am|pm|a\.m|p\.m|min|hour|hr|day|week|month|year|dollar|euro|people|items|st\b|nd\b|rd\b|th\b|o'?\s*clock))"#)
    static let clockSpanish = regex(#"(?<![a-z\d:.,/-])(?:a|para|hacia|desde|hasta|sobre)\s+las?\s+(?<h>\#(num))(?:\s+y\s+(?<mod>media|cuarto|\#(num))|\s+menos\s+(?<less>cuarto|\#(num)))?(?![\d:.,%]|\s*(?:am|pm|a\.m|p\.m|min|hora|dia|semana|mes|ano|dolar|euro|personas))"#)
    static let clockSpanishBare = regex(#"(?<![a-z\d:.,/-])las?\s+(?<h>\#(num))\s+(?:y\s+(?<mod>media|cuarto|\#(num))|menos\s+(?<less>cuarto|\#(num)))(?![a-z\d])"#)
    static let clockPast = regex(#"(?<![a-z\d])(?:(?:at|by|around)\s+)?(?<mod>half|(?:a\s+)?quarter|\#(num))\s+(?<dir>past|after|to|till|before|of)\s+(?<h>\#(num))(?![a-z\d:])"#)
    static let hourWithPeriod = regex(#"(?<![a-z\d:.,/-])(?<h>1[0-2]|0?[1-9])\s*(?:de\s+la\s+|in\s+the\s+|at\s+|por\s+la\s+)(?<pod>manana|tarde|noche|madrugada|morning|afternoon|evening|night)(?![a-z])"#)

    // MARK: Connectors left behind after removing date phrases

    static let danglingConnectors = regex(#"(?:^|\s)(?:(?:at|on|by|for|in|to|from|until|till|around|about|the|and|then|also|el|la|las|los|para|a|en|de|del|por|hasta|desde|hacia|y|e|luego|tambien)\s*)+$"#)
    static let leadingConnectors = regex(#"^(?:(?:at|on|by|for|in|to|from|until|till|and|then|also|el|la|las|los|para|a|en|de|y|luego|tambien)\s+)+"#)
}
