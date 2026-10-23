import Foundation
import JarvisCore

/// English/Spanish rules for Apple Music.
struct MusicRules: IntentRuleSet {
    // Suffix such as "on Apple Music" / "en Apple Music" / "en la app de música".
    private static let appSuffix = Rx.make(#"\s+(?:on|in|using|with|via|through|from|en|con|usando|desde|mediante)\s+(?:the\s+|my\s+|la\s+|mi\s+)?(?:apple\s+)?(?:music|musica)(?:\s+app)?$"#)
    private static let appSuffixWithDe = Rx.make(#"\s+(?:en|con|desde)\s+(?:la\s+)?app\s+de\s+(?:apple\s+)?musica$"#)

    private static let playVerb = #"(?:play|put on|queue up|cue up|reproduce|reproducir|reproduzca|pon|ponme|poner|ponga|toca|tocar|quiero escuchar|quiero oir|escucha|escuchar|oir|listen to|i want to hear|i want to listen to|start playing|start|inicia|iniciar|empieza|empezar)"#
    private static let shuffleVerb = #"(?:shuffle|mezcla|mezclar|aleatorio)"#
    private static let determiner = #"(?:(?:the|my|a|an|some|mi|mis|el|la|los|las|un|una|unos|unas)\s+)?"#
    private static let playlistWord = #"(?:playlist|play list|lista de reproduccion|lista de reproducciones|listas de reproduccion|lista(?:\s+de)?|playlist de)"#

    private static let pause = Rx.make(#"^(?:pause|pausa|pausar|haz una pausa)\b(?:\s+(?:the|la|el|this|esta|este|my|mi|current|actual))*(?:\s+(?:music|song|track|playback|it|musica|cancion|reproduccion|tema|esto|playing|reproduciendo))?$"#)
    private static let resume = Rx.make(#"^(?:resume|unpause|continue|continua|continuar|reanuda|reanudar|sigue|seguir|keep playing|continue playing|play(?: the)?(?: music)?|play it|play again|reproduce(?: la)?(?: musica)?|pon(?: la)?(?: musica)?|ponme(?: musica)?|poner musica|toca(?: la)? musica|dale play|dale|start the music|start playing|start playback|reproduce de nuevo)(?:\s+(?:the|la|el|my|mi))*(?:\s+(?:music|song|track|playback|musica|cancion|reproduccion|tema))?$"#)
    private static let stop = Rx.make(#"^(?:stop|deten|detener|para|parar|termina|apaga|quit)\b(?:\s+(?:the|la|el|this|esta|este|my|mi|current|actual|all|toda))*(?:\s+(?:music|song|track|playback|musica|cancion|reproduccion|tema|playing|reproduciendo|todo))?$"#)
    private static let next = Rx.make(#"^(?:next|skip|siguiente|salta|saltar|pasa|pasar|avanza|adelanta|play next|play the next|pon la siguiente|ponme la siguiente|reproduce la siguiente|pon el siguiente|skip to the next)\b(?:\s+(?:to|a|al|la|el|the|this|esta|este|current|actual|one|song|track|tune|cancion|tema|siguiente|next))*$"#)
    private static let previous = Rx.make(#"^(?:previous|prev|back|go back|last|anterior|vuelve|volver|regresa|retrocede|atras|play previous|play the previous|pon la anterior|reproduce la anterior|ponme la anterior|pon el anterior)\b(?:\s+(?:to|a|al|la|el|the|this|esta|este|one|song|track|cancion|tema|anterior|previous|last|ultima|ultimo|de|vez))*$"#)

    private static let nounFirstNext = Rx.make(#"^(?:cancion|tema|pista|song|track)\s+(?:siguiente|next)$"#)
    private static let nounFirstPrevious = Rx.make(#"^(?:cancion|tema|pista|song|track)\s+(?:anterior|previous)$"#)
    private static let volumeSet = Rx.make(#"^(?:(?:set|change|put|turn|adjust|make|pon|ponme|poner|ajusta|cambia|establece|configura|sube|baja|mueve)\s+)?(?:(?:the|el)\s+)?(?:(?:music|musica)\s+)?volume(?:n)?\s*(?:to|at|a|al|en|hasta|=)?\s*(?:level\s+)?(?<level>\d{1,3})\s*(?:%|percent|por ciento)?$"#)
    private static let volumeNamed = Rx.make(#"^(?:(?:set|change|put|turn|adjust|make|pon|ponme|poner|ajusta|cambia|establece)\s+)?(?:(?:the|el)\s+)?(?:(?:music|musica)\s+)?volume(?:n)?\s*(?:to|at|a|al|en|hasta)?\s*(?<word>max|maximum|full|half|min|minimum|mute|maximo|maxima|mitad|minimo|silencio)$"#)
    private static let volumeUpDown = Rx.make(#"^(?:(?:turn|bring|crank|move)\s+)?(?:(?:the|el|it)\s+)?(?:(?:music|musica)\s+)?(?:volume(?:n)?\s+)?(?<dir>up|down)(?:\s+(?:the\s+)?(?:volume|music))?(?:\s+(?:by\s+)?(?<n>\d{1,3}))?\s*%?(?:\s+(?:a\s+)?(?:bit|little|touch|notch|lot)|\s+un\s+poco|\s+mucho|\s+bastante)?$"#)
    private static let volumeVerb = Rx.make(#"^(?<dir>increase|raise|lower|decrease|reduce|boost|sube|subir|baja|bajar|aumenta|aumentar|disminuye|disminuir|reduce|reducir)\s+(?:(?:the|el)\s+)?(?:volume(?:n)?|music|musica)(?:\s+(?:by|en|un|al)\s+(?<n>\d{1,3}))?\s*(?:%|percent|por ciento)?(?:\s+(?:a\s+)?(?:bit|little|touch|notch|lot)|\s+un\s+poco|\s+mucho|\s+bastante)?$"#)
    private static let louderQuieter = Rx.make(#"^(?:make it\s+|hazlo\s+)?(?<dir>louder|quieter|softer|mas fuerte|mas alto|mas bajo|mas suave|mas flojo|mas despacio)(?:\s+please)?$"#)
    private static let mute = Rx.make(#"^(?:mute|silencia|silenciar|silencio|mute the music|silencia la musica)$"#)

    private static let nowPlaying = Rx.make(#"^(?:what(?:'s| is)?\s+(?:currently\s+)?(?:playing|this song|this track|on)|what song is (?:this|playing)|what track is (?:this|playing)|what am i listening to|what's playing|whats playing|current(?:ly playing)?(?: song| track)?|now playing|who sings this|who(?:'s| is) this by|que (?:esta sonando|suena|cancion es esta|cancion suena|estoy escuchando|tema es este|esta sonando ahora)|cual es la cancion actual|que cancion (?:es|esta sonando)|informacion de la cancion|info de la cancion|playback info|song info)\s*\??$"#)

    private static let listPlaylists = Rx.make(#"^(?:(?:list|show|display|get|see|tell me|give me|what are|which are|muestra|muestrame|lista|listar|dime|ver|cuales son|que)\s+)?(?:(?:me|all|todas|todos)\s+)*(?:(?:my|mis|the|las)\s+)?(?:playlists|play lists|listas de reproduccion|listas de musica)(?:\s+(?:do i have|i have|tengo|que tengo|available|disponibles))?\s*\??$"#)
    private static let whatPlaylists = Rx.make(#"^(?:what|which|que|cuales)\s+playlists\s+(?:do i have|have i got|tengo|hay)\s*\??$"#)

    private static let searchLibrary = Rx.make(#"^(?:search|find|look for|look up|busca|buscar|encuentra|encontrar)\s+(?:(?:(?:in|on|en|through)\s+)?(?:my\s+|mi\s+)?(?:music\s+|musica\s+)?(?:library|biblioteca|music|musica)\s+(?:for\s+|por\s+)?|for\s+)?(?<q>.+?)(?:\s+(?:in|on|en)\s+(?:my\s+|mi\s+)?(?:music|library|biblioteca|musica)(?:\s+library)?)?$"#)
    private static let doIHave = Rx.make(#"^(?:do i have|have i got|tengo)\s+(?<q>.+?)\s+(?:in|on|en)\s+(?:my\s+|mi\s+)?(?:music|library|biblioteca|musica)(?:\s+library)?\s*\??$"#)

    private static let playPlaylistFirst = Rx.make(#"^(?:\#(shuffleVerb)\s+)?\#(playVerb)\s+\#(determiner)\#(playlistWord)\s+(?:(?:called|named|titled|llamada|llamado|titulada|que se llama)\s+)?(?<name>.+?)(?:\s+(?:on\s+)?shuffle|\s+en aleatorio|\s+aleatori[oa])?$"#)
    private static let playPlaylistLast = Rx.make(#"^(?:\#(shuffleVerb)\s+)?\#(playVerb)\s+\#(determiner)(?<name>.+?)\s+\#(playlistWord)(?:\s+(?:on\s+)?shuffle|\s+en aleatorio|\s+aleatori[oa])?$"#)
    private static let shufflePlaylist = Rx.make(#"^\#(shuffleVerb)\s+\#(determiner)(?:\#(playlistWord)\s+)?(?<name>.+?)(?:\s+\#(playlistWord))?$"#)
    private static let playGeneric = Rx.make(#"^\#(playVerb)\s+(?<rest>.+)$"#)

    private static let playlistKeyword = Rx.make(#"\b(?:playlist|play list|lista de reproduccion|listas de reproduccion)\b|\blista\s+\S"#)
    private static let albumLead = Rx.make(#"^(?:(?:the|el|un|an?)\s+)?(?:album|disco|lp)\s+(?:called\s+|named\s+|llamado\s+)?(?<q>.+)$"#)
    private static let songLead = Rx.make(#"^(?:(?:the|la|el|una?|an?)\s+)?(?:song|track|tune|cancion|tema|rola|single)\s+(?:called\s+|named\s+|llamada\s+)?(?<q>.+)$"#)
    private static let artistLead = Rx.make(#"^(?:(?:the|el|la|an?)\s+)?(?:artist|band|singer|musician|artista|banda|cantante|grupo)\s+(?<q>.+)$"#)
    private static let songsBy = Rx.make(#"^(?:(?:some|any|all|algo|alguna|todas|todo|unas|unos|las)\s+)?(?:songs?|music|tracks?|tunes?|something|anything|stuff|hits|canciones|musica|temas|exitos)\s+(?:by|from|of|de|del)\s+(?<q>.+)$"#)
    /// "shuffle my library", "play my music": there is no tool to play a whole library, so this must not become a search
    /// for a song called "my library".
    private static let wholeLibrary = Rx.make(#"^(?:(?:all|todo|toda)\s+)?(?:(?:my|the|mi|mis|la|el)\s+)?(?:(?:music|musica)\s+)?(?:library|biblioteca|collection|coleccion)$|^(?:all\s+)?(?:my|the|mi|mis)\s+(?:music|musica)$"#)
    private static let someOnly = Rx.make(#"^(?:some|any|algo de|un poco de|unas|unos)\s+(?:music|musica|songs|canciones|tunes)?$"#)
    private static let byArtist = Rx.make(#"^(?<q>.+?)\s+by\s+(?<artist>.+)$"#)

    func interpret(_ clause: Clause) -> [RuleResult] {
        var results: [RuleResult] = []
        var text = clause.text
        // Remove "on Apple Music" so the rest of the clause is just the request.
        for suffix in [Self.appSuffix, Self.appSuffixWithDe] {
            if let match = text.firstMatch(suffix), match.range.upperBound == text.count, match.range.lowerBound > 0 {
                text = text.slice(0..<match.range.lowerBound)
                break
            }
        }
        let base = Clause(text: text.collapsedWhitespace(), context: clause.context)
        let folded = base.folded
        guard !folded.isEmpty else { return [] }
        let mentionsAppleMusic = clause.folded.contains("apple music")

        // Transport controls.
        if base.whole(Self.pause, groups: []) != nil { results.append(.calls([ToolCall(tool: .musicPause)], confidence: 0.93)) }
        if base.whole(Self.stop, groups: []) != nil { results.append(.calls([ToolCall(tool: .musicStop)], confidence: 0.85)) }
        if base.whole(Self.next, groups: []) != nil || base.whole(Self.nounFirstNext, groups: []) != nil {
            results.append(.calls([ToolCall(tool: .musicNext)], confidence: 0.9))
        }
        if base.whole(Self.previous, groups: []) != nil || base.whole(Self.nounFirstPrevious, groups: []) != nil {
            results.append(.calls([ToolCall(tool: .musicPrevious)], confidence: 0.85))
        }
        if base.whole(Self.resume, groups: []) != nil {
            results.append(.calls([ToolCall(tool: .musicResume)], confidence: folded == "play" || folded == "dale" ? 0.6 : 0.88))
        }
        if base.whole(Self.mute, groups: []) != nil {
            results.append(.calls([ToolCall(tool: .musicSetVolume, arguments: ["level": 0])], confidence: 0.88))
        }

        // Volume.
        if let match = base.whole(Self.volumeSet, groups: ["level"]), let text = match.original("level"), let level = Int(text) {
            results.append(.calls([ToolCall(tool: .musicSetVolume, arguments: ["level": .int(min(max(level, 0), 100))])], confidence: 0.95))
        }
        if let match = base.whole(Self.volumeNamed, groups: ["word"]), let word = match.folded("word") {
            let level: Int
            switch word {
            case "max", "maximum", "full", "maximo", "maxima": level = 100
            case "half", "mitad": level = 50
            default: level = 0
            }
            results.append(.calls([ToolCall(tool: .musicSetVolume, arguments: ["level": .int(level)])], confidence: 0.93))
        }
        if let match = base.whole(Self.volumeUpDown, groups: ["dir", "n"]) ?? base.whole(Self.volumeVerb, groups: ["dir", "n"]) ?? base.whole(Self.louderQuieter, groups: ["dir"]) {
            let direction = match.folded("dir") ?? "up"
            let isUp = ["up", "increase", "raise", "boost", "sube", "subir", "aumenta", "aumentar", "louder", "mas fuerte", "mas alto"].contains(direction)
            let amount = match.original("n").flatMap(Int.init) ?? 10
            let confidence = direction == "up" || direction == "down" ? 0.8 : 0.93
            results.append(.calls([ToolCall(tool: .musicSetVolume, arguments: ["delta": .int(isUp ? amount : -amount)])], confidence: confidence))
        }

        // Information.
        if base.whole(Self.nowPlaying, groups: []) != nil {
            results.append(.calls([ToolCall(tool: .musicNowPlaying)], confidence: 0.93))
        }
        if base.whole(Self.listPlaylists, groups: []) != nil || base.whole(Self.whatPlaylists, groups: []) != nil {
            results.append(.calls([ToolCall(tool: .musicListPlaylists)], confidence: 0.92))
        }
        if let match = base.whole(Self.doIHave, groups: ["q"]), let query = match.original("q") {
            results.append(.calls([ToolCall(tool: .musicSearch, arguments: ["query": .string(query)])], confidence: 0.9))
        } else if let match = base.whole(Self.searchLibrary, groups: ["q"]), let query = match.original("q"),
                  (folded.contains("music") || folded.contains("musica") || folded.contains("library") || folded.contains("biblioteca") || mentionsAppleMusic) {
            results.append(.calls([ToolCall(tool: .musicSearch, arguments: ["query": .string(query)])], confidence: 0.85))
        }

        // Playlists.
        let hasPlaylistKeyword = base.find(Self.playlistKeyword) != nil
        if hasPlaylistKeyword {
            var matched: MatchedClause?
            for regex in [Self.playPlaylistFirst, Self.playPlaylistLast] {
                if let match = base.whole(regex, groups: ["name"]) { matched = match; break }
            }
            if matched == nil { matched = base.whole(Self.shufflePlaylist, groups: ["name"]) }
            if let matched, var name = matched.original("name") {
                name = TextCleanup.name(name)
                var shuffle = folded.hasPrefix("shuffle") || folded.hasPrefix("mezcla") || folded.contains(" shuffle") || folded.contains("aleatori")
                if let stripped = stripShuffleWords(name) { name = stripped.name; shuffle = shuffle || stripped.found }
                if !name.isEmpty {
                    var arguments: JSONObject = ["name": .string(name)]
                    if shuffle { arguments["shuffle"] = true }
                    results.append(.calls([ToolCall(tool: .musicPlayPlaylist, arguments: arguments)], confidence: 0.95))
                }
            }
        }

        // Songs, albums, artists.
        if !hasPlaylistKeyword, let match = base.whole(Self.playGeneric, groups: ["rest"]), let restRange = match.range("rest") {
            let rest = base.text.slice(restRange)
            if Clause(text: rest, context: base.context).whole(Self.wholeLibrary, groups: []) != nil { return results }
            if let call = playCall(for: rest, shuffle: folded.hasPrefix("shuffle")) {
                results.append(.calls([call], confidence: mentionsAppleMusic ? 0.8 : 0.62))
            }
        } else if !hasPlaylistKeyword, folded.hasPrefix("shuffle ") || folded.hasPrefix("mezcla ") {
            let rest = base.text.slice(folded.hasPrefix("shuffle ") ? 8..<base.text.count : 7..<base.text.count)
            if Clause(text: rest, context: base.context).whole(Self.wholeLibrary, groups: []) != nil { return results }
            if let call = playCall(for: rest, shuffle: true) { results.append(.calls([call], confidence: 0.6)) }
        }
        return results
    }

    // MARK: Helpers

    private func stripShuffleWords(_ name: String) -> (name: String, found: Bool)? {
        let regex = Rx.make(#"\s+(?:on\s+shuffle|en aleatorio|aleatori[oa]|shuffled)$"#, caseInsensitive: true)
        let range = NSRange(name.startIndex..., in: name)
        guard let match = regex.firstMatch(in: name, range: range), let swiftRange = Range(match.range, in: name) else { return nil }
        var copy = name
        copy.removeSubrange(swiftRange)
        return (copy.trimmingCharacters(in: .whitespaces), true)
    }

    /// "some", "a", "un poco de" … before a bare request ("play some Queen"); "the"/"my" stay because they can be part of a title.
    private static func stripLeadingFiller(_ text: String) -> String {
        let regex = Rx.make(#"^(?:some|a few|any|algo de|un poco de|unas|unos)\s+"#, caseInsensitive: true)
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range), let swiftRange = Range(match.range, in: text), swiftRange.upperBound != text.endIndex else { return text }
        return String(text[swiftRange.upperBound...])
    }

    /// Builds `music.play` from the text after the verb.
    private func playCall(for rest: FoldedText, shuffle: Bool) -> ToolCall? {
        let clause = Clause(text: rest, context: DateContext(now: Date(), calendar: Calendar(identifier: .gregorian), settings: JarvisSettings(), language: .en))
        if clause.whole(Self.someOnly, groups: []) != nil { return ToolCall(tool: .musicResume) }

        var kind = "any"
        var query: String?
        var artist: String?

        if let match = clause.whole(Self.albumLead, groups: ["q"]) {
            kind = "album"
            query = match.original("q")
        } else if let match = clause.whole(Self.songLead, groups: ["q"]) {
            kind = "song"
            query = match.original("q")
        } else if let match = clause.whole(Self.songsBy, groups: ["q"]) {
            kind = "artist"
            query = match.original("q")
        } else if let match = clause.whole(Self.artistLead, groups: ["q"]) {
            kind = "artist"
            query = match.original("q")
        } else {
            query = TextCleanup.name(Self.stripLeadingFiller(rest.original))
        }
        guard var query, !query.isEmpty else { return nil }

        // "<title> by <artist>" (English). Spanish "de" is ambiguous with titles, so the integration handles it.
        if kind != "artist" {
            let working = Clause(text: FoldedText(query), context: clause.context)
            if let match = working.whole(Self.byArtist, groups: ["q", "artist"]), let q = match.original("q"), let a = match.original("artist") {
                query = q
                artist = a
            }
        }
        query = TextCleanup.name(query)
        var arguments: JSONObject = ["query": .string(query)]
        if kind != "any" { arguments["kind"] = .string(kind) }
        if let artist { arguments["artist"] = .string(TextCleanup.name(artist)) }
        if shuffle { arguments["shuffle"] = true }
        return ToolCall(tool: .musicPlay, arguments: arguments)
    }
}
