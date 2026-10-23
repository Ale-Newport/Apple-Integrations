import Foundation
import JarvisCore

/// Apple Music through its AppleScript dictionary (Music.app has no EventKit-style API).
///
/// * Only music **in the user's library** can be played; a missing song is reported as such — never as success.
/// * Every playback command is verified by reading the player state back from Music.
/// * Albums and artists are played through one dedicated, clearly named queue playlist (see Settings) because
///   AppleScript cannot enqueue tracks without a playlist; nothing in the library is modified.
public struct MusicIntegration: AppIntegration {
    public let id = IntegrationID.music
    public let displayName = LocalizedText(en: "Apple Music", es: "Apple Music")
    public let summary = LocalizedText(
        en: "Play songs, albums and playlists from your library and control playback.",
        es: "Reproduce canciones, álbumes y listas de tu biblioteca y controla la reproducción."
    )
    public let symbolName = "music.note"

    static let bundleIdentifier = "com.apple.Music"

    private let scripts: any AppleScriptExecuting
    private let access: any AutomationAccess

    public init(scripts: any AppleScriptExecuting = OSAScriptRunner()) {
        self.init(scripts: scripts, access: SystemAutomationAccess(bundleIdentifier: Self.bundleIdentifier))
    }

    init(scripts: any AppleScriptExecuting, access: any AutomationAccess) {
        self.scripts = scripts
        self.access = access
    }

    // MARK: Discovery

    public let permissionRequirements: [PermissionRequirement] = [Self.requirement]

    static let requirement = PermissionRequirement.automation(
        appName: "Music", bundleIdentifier: bundleIdentifier,
        reason: LocalizedText(
            en: "Jarvis sends commands to the Music app (play, pause, search your library). macOS asks once.",
            es: "Jarvis envía comandos a la app Música (reproducir, pausar, buscar en tu biblioteca). macOS lo pregunta una sola vez."
        )
    )

    public var tools: [ToolDescriptor] {
        let id = self.id
        func tool(_ name: ToolName, _ title: String, _ summary: String, _ parameters: [ToolParameter] = [], _ constraints: [ToolConstraint] = [], safety: ToolSafety = .modifying, timeout: TimeInterval = 30, examples: [ToolExample] = []) -> ToolDescriptor {
            ToolDescriptor(name: name, integration: id, title: title, summary: summary, parameters: parameters, constraints: constraints, safety: safety, timeout: timeout, examples: examples)
        }
        return [
            tool(.musicPlay, "Play a song, album or artist", "Plays music from the user's Apple Music library that matches the query.", [
                .string("query", "Song, album or artist to play. Quote the title only, e.g. \"Bohemian Rhapsody\".", required: true, maxLength: 300),
                .choice("kind", ["any", "song", "album", "artist"], "What the query names.", default: "any"),
                .string("artist", "Artist to disambiguate a song or album.", maxLength: 200),
                .boolean("shuffle", "Shuffle albums/artists."),
                .string("track_id", "Exact persistent id of a track returned by music.search (skips ranking).", maxLength: 64),
            ], timeout: 45, examples: [
                ToolExample("Play Bohemian Rhapsody on Apple Music", arguments: ["query": "Bohemian Rhapsody"]),
                ToolExample("Play the album Abbey Road by The Beatles", arguments: ["query": "Abbey Road", "kind": "album", "artist": "The Beatles"]),
            ]),
            tool(.musicPlayPlaylist, "Play a playlist", "Plays one of the user's playlists by name.", [
                .string("name", "Playlist name.", required: true, maxLength: 200),
                .boolean("shuffle", "Play in shuffled order."),
                .string("playlist_id", "Exact persistent id of the playlist (skips name matching).", maxLength: 64),
            ], timeout: 45, examples: [ToolExample("Play my Study playlist", arguments: ["name": "Study"])]),
            tool(.musicPause, "Pause", "Pauses playback.", examples: [ToolExample("Pause the music", arguments: [:])]),
            tool(.musicResume, "Resume", "Resumes (or starts) playback.", examples: [ToolExample("Resume the music", arguments: [:])]),
            tool(.musicStop, "Stop", "Stops playback."),
            tool(.musicNext, "Next track", "Skips to the next track."),
            tool(.musicPrevious, "Previous track", "Returns to the previous track."),
            tool(.musicSearch, "Search the library", "Searches the user's Music library.", [
                .string("query", "Text to search for.", required: true, maxLength: 300),
                .choice("kind", ["any", "song", "album", "artist"], "Restrict the search.", default: "any"),
                .integer("limit", "Maximum results.", min: 1, max: 50, default: 10),
            ], safety: .readOnly, timeout: 45, examples: [ToolExample("Search my music for Radiohead", arguments: ["query": "Radiohead"])]),
            tool(.musicListPlaylists, "List playlists", "Lists the user's playlists.", [
                .integer("limit", "Maximum playlists to return.", min: 1, max: 500, default: 100),
            ], safety: .readOnly, timeout: 45),
            tool(.musicSetVolume, "Set or adjust the volume", "Sets Music's volume (0–100) or changes it by a relative amount.", [
                .integer("level", "Absolute volume, 0–100.", min: 0, max: 100),
                .integer("delta", "Relative change, -100…100.", min: -100, max: 100),
            ], [.exactlyOne(["level", "delta"])], examples: [ToolExample("Set the volume to 40", arguments: ["level": 40]), ToolExample("Turn it up", arguments: ["delta": 10])]),
            tool("music.set_shuffle", "Set shuffle", "Enables or disables Music shuffle.", [.boolean("enabled", "Shuffle enabled.", required: true)]),
            tool("music.set_repeat", "Set repeat", "Sets repeat mode: off, one track, or all.", [.choice("mode", ["off", "one", "all"], "Repeat mode.", required: true)]),
            tool(.musicNowPlaying, "Now playing", "Reads the current track and playback information.", safety: .readOnly, examples: [ToolExample("What's playing?", arguments: [:])]),
        ]
    }

    // MARK: Authorization

    public func status() async -> IntegrationStatus {
        let entry: (AuthorizationState) -> IntegrationStatus.PermissionEntry = { .init(requirement: Self.requirement, state: $0) }
        switch access.status() {
        case .unavailable:
            let reason = LocalizedText(en: "The Music app is not available on this Mac.", es: "La app Música no está disponible en este Mac.")
            return IntegrationStatus(state: .unavailable, detail: reason, permissions: [entry(.unavailable(reason))])
        case .granted:
            return IntegrationStatus(state: .ready, permissions: [entry(.authorized)])
        case .denied:
            return IntegrationStatus(state: .denied, detail: Self.requirement.rationale, permissions: [entry(.denied(Self.requirement))])
        case .notDetermined, .targetNotRunning:
            return IntegrationStatus(state: .needsPermission, detail: Self.requirement.rationale, permissions: [entry(.notDetermined(Self.requirement))])
        }
    }

    public func authorization(for tool: ToolDescriptor) async -> AuthorizationState {
        switch access.status() {
        case .unavailable:
            return .unavailable(LocalizedText(en: "The Music app is not installed.", es: "La app Música no está instalada."))
        case .granted:
            return .authorized
        case .denied:
            return .denied(Self.requirement)
        case .notDetermined:
            return .notDetermined(Self.requirement)
        case .targetNotRunning:
            // Controls that only make sense while Music is playing must not launch it just to ask.
            return Self.neverLaunches.contains(tool.name) ? .authorized : .notDetermined(Self.requirement)
        }
    }

    public func requestAuthorization(for tool: ToolDescriptor) async -> AuthorizationState {
        switch await access.request() {
        case .granted: return .authorized
        case .unavailable: return .unavailable(LocalizedText(en: "The Music app is not installed.", es: "La app Música no está instalada."))
        case .notDetermined, .targetNotRunning: return .notDetermined(Self.requirement)
        case .denied: return .denied(Self.requirement)
        }
    }

    private static let neverLaunches: Set<ToolName> = [.musicPause, .musicStop, .musicNext, .musicPrevious, .musicNowPlaying, .musicSetVolume]

    // MARK: Execution

    public func execute(_ call: ValidatedToolCall, context: ExecutionContext) async throws -> ToolOutcome {
        switch call.descriptor.name {
        case .musicPlay: return try await play(call, context)
        case .musicPlayPlaylist: return try await playPlaylist(call, context)
        case .musicPause, .musicResume, .musicStop, .musicNext, .musicPrevious: return try await transport(call, context)
        case .musicSearch: return try await search(call, context)
        case .musicListPlaylists: return try await listPlaylists(call, context)
        case .musicSetVolume: return try await setVolume(call, context)
        case .musicNowPlaying: return try await nowPlaying(context)
        case "music.set_shuffle", "music.set_repeat":
            let mode = call.string("mode") ?? "off"
            let shuffle = call.bool("enabled") ?? false
            let result = try await state(MusicScripts.setPlaybackMode, [call.descriptor.name.rawValue, shuffle ? "true" : "false", mode])
            guard (call.descriptor.name.rawValue == "music.set_shuffle" ? result.shuffle == shuffle : result.repeatMode == mode) else {
                throw JarvisError.verificationFailed(LocalizedText(en: "Music did not keep the requested playback mode.", es: "Música no conservó el modo de reproducción solicitado."))
            }
            return .done(ToolOutput(message: context.language.pick("Playback mode updated.", "Modo de reproducción actualizado."), data: result.json, verification: .verified("Music read-back")))
        default:
            throw JarvisError.failed("unknown_tool", en: "Music does not provide \(call.descriptor.name).", es: "Música no ofrece \(call.descriptor.name).")
        }
    }

    // MARK: Running scripts

    private func run(_ script: AppleScriptSource, _ arguments: [String] = [], timeout: TimeInterval = 25) async throws -> String {
        do {
            return try await scripts.run(script, arguments: arguments, timeout: timeout)
        } catch let failure as AppleScriptFailure {
            throw failure.jarvisError(app: "Music", requirement: Self.requirement)
        }
    }

    private func state(_ script: AppleScriptSource = MusicScripts.state, _ arguments: [String] = []) async throws -> MusicState {
        let row = try await run(script, arguments)
        guard let state = MusicState(row: row) else {
            throw JarvisError.failed("unexpected_output", en: "Music returned something Jarvis could not read.", es: "Música devolvió algo que Jarvis no pudo interpretar.")
        }
        return state
    }

    private func searchLibrary(query: String, kind: String, limit: Int = 100, allowFuzzy: Bool = false) async throws -> [MusicTrack] {
        let output = try await run(MusicScripts.search, [query, kind, String(limit)], timeout: 40)
        let exact = ScriptRecords.parse(output).compactMap(MusicTrack.init(searchFields:))
        if !exact.isEmpty || !allowFuzzy { return exact }
        // Search actual library metadata before applying fuzzy ranking. Never invent a catalogue result.
        let words = TextFolding.tokens(query).filter { $0.count >= 4 }.sorted { $0.count > $1.count }
        var queries = Array(words.prefix(2))
        if let longest = words.first { queries.append(String(longest.prefix(max(4, longest.count / 2)))) }
        var candidates: [MusicTrack] = []
        var seen = Set<String>()
        for broad in queries where broad != TextFolding.fold(query) {
            let raw = try await run(MusicScripts.search, [broad, kind, String(limit)], timeout: 10)
            for track in ScriptRecords.parse(raw).compactMap(MusicTrack.init(searchFields:)) where seen.insert(track.id).inserted { candidates.append(track) }
        }
        return candidates
    }

    private func playlists() async throws -> [MusicPlaylist] {
        let output = try await run(MusicScripts.listPlaylists, [], timeout: 40)
        return ScriptRecords.parse(output).compactMap(MusicPlaylist.init(fields:))
    }

    // MARK: music.play

    private func play(_ call: ValidatedToolCall, _ context: ExecutionContext) async throws -> ToolOutcome {
        let rawQuery = call.string("query") ?? ""
        let builtInAliases = ["the weekend": "The Weeknd"]
        let explicitAlias = context.settings.preferenceMemoryEnabled ? context.settings.aliases.first(where: { TextFolding.fold($0.key) == TextFolding.fold(rawQuery) })?.value : nil
        let query = explicitAlias ?? builtInAliases[TextFolding.fold(rawQuery)] ?? rawQuery
        let kind = call.string("kind") ?? "any"
        let artist = call.string("artist")
        let shuffle = call.bool("shuffle") ?? false
        let language = context.language

        // 1. Find candidates. A bare query is searched as typed; "X by Y" / "X de Y" is retried as title + artist.
        var tracks = try await searchLibrary(query: query, kind: kind == "artist" || kind == "album" ? kind : (kind == "song" ? "song" : "any"))
        var effectiveArtist = artist
        var effectiveQuery = query
        if tracks.isEmpty, kind != "artist", kind != "album" {
            for split in MusicRanking.titleArtistSplits(query) {
                let attempt = try await searchLibrary(query: split.title, kind: kind == "song" ? "song" : "any")
                let filtered = attempt.filter { NameMatcher.score(query: split.artist, candidate: $0.artist) >= 50 }
                if !filtered.isEmpty {
                    tracks = attempt
                    effectiveQuery = split.title
                    effectiveArtist = split.artist
                    break
                }
            }
        }
        if tracks.isEmpty { tracks = try await searchLibrary(query: query, kind: kind == "song" ? "song" : kind == "album" ? "album" : kind == "artist" ? "artist" : "any", allowFuzzy: true) }
        guard !tracks.isEmpty else { throw Self.notInLibrary(query, language) }

        // 2. Play an exact track when the caller already chose one (clarification option).
        if let trackID = call.string("track_id") {
            guard let track = tracks.first(where: { $0.id == trackID }) else { throw Self.notInLibrary(query, language) }
            return try await playSingle(track, searchQuery: effectiveQuery, kind: kind == "song" ? "song" : "any", context: context)
        }

        // 3. Decide what the user meant.
        switch kind {
        case "album":
            let matching = tracks.filter { FuzzyNameMatcher.score(query: query, candidate: $0.album) >= 60 && (artist == nil || NameMatcher.score(query: artist ?? "", candidate: $0.artist) >= 50) }
            return try await playCollection(matching, query: query, kind: "album", artist: artist, shuffle: shuffle, context: context)
        case "artist":
            let matching = tracks.filter { FuzzyNameMatcher.score(query: query, candidate: $0.artist) >= 60 }
            return try await playCollection(matching, query: query, kind: "artist", artist: nil, shuffle: shuffle, context: context)
        default:
            break
        }

        let ranked = MusicRanking.rank(tracks, query: effectiveQuery, artist: effectiveArtist)
        if let top = ranked.first, top.score >= 85 || kind == "song" {
            let best = ranked.filter { $0.score >= top.score - 3 }
            let artists = Set(best.map { TextFolding.fold($0.track.artist) })
            if best.count > 1, (artists.count > 1 && effectiveArtist == nil) || Set(best.map { TextFolding.fold($0.track.name) }).count > 1 {
                // Several different songs with the same title: ask instead of guessing.
                let options = best.prefix(5).map { candidate in
                    ClarificationOption(
                        label: candidate.track.display,
                        detail: candidate.track.album.isEmpty ? nil : candidate.track.album,
                        call: ToolCall(tool: .musicPlay, arguments: ["query": .string(effectiveQuery), "kind": "song", "track_id": .string(candidate.track.id)])
                    )
                }
                return .clarify(Clarification(
                    question: language.pick("I found several songs called “\(effectiveQuery)”. Which one?", "Encontré varias canciones llamadas «\(effectiveQuery)». ¿Cuál?"),
                    options: Array(options)
                ))
            }
            if top.score < 85 {
                return .clarify(Clarification(question: language.pick("Did you mean “\(top.track.display)”?", "¿Te refieres a «\(top.track.display)»?"), options: [ClarificationOption(label: top.track.display, call: call.call.adding(["track_id": .string(top.track.id)]))]))
            }
            return try await playSingle(top.track, searchQuery: effectiveQuery, kind: kind == "song" ? "song" : "any", context: context)
        }

        // 4. No song title matched well: the text may name an artist or an album.
        let artistMatches = tracks.filter { FuzzyNameMatcher.score(query: query, candidate: $0.artist) >= 75 }
        if !artistMatches.isEmpty {
            return try await playCollection(artistMatches, query: query, kind: "artist", artist: nil, shuffle: shuffle, context: context)
        }
        let albumMatches = tracks.filter { FuzzyNameMatcher.score(query: query, candidate: $0.album) >= 75 }
        if !albumMatches.isEmpty {
            return try await playCollection(albumMatches, query: query, kind: "album", artist: artist, shuffle: shuffle, context: context)
        }
        throw Self.notInLibrary(query, language)
    }

    private func playCollection(_ tracks: [MusicTrack], query: String, kind: String, artist: String?, shuffle: Bool, context: ExecutionContext) async throws -> ToolOutcome {
        let groups = Dictionary(grouping: tracks) { track in
            TextFolding.fold(track.artist) + (kind == "album" ? "|" + TextFolding.fold(track.album) : "")
        }
        guard !groups.isEmpty else { throw Self.notInLibrary(query, context.language) }
        if groups.count > 1 {
            let options = groups.keys.sorted().prefix(8).compactMap { key -> ClarificationOption? in
                guard let track = groups[key]?.first else { return nil }
                let label = kind == "album" ? "\(track.album) — \(track.artist)" : track.artist
                let name = kind == "album" ? track.album : track.artist
                var args: JSONObject = ["query": .string(name), "kind": .string(kind), "shuffle": .bool(shuffle)]
                if kind == "album" { args["artist"] = .string(track.artist) }
                return ClarificationOption(label: label, call: ToolCall(tool: .musicPlay, arguments: args))
            }
            return .clarify(Clarification(question: context.language.pick("Which \(kind) did you mean?", "¿A qué \(kind == "album" ? "álbum" : "artista") te refieres?"), options: options))
        }
        let label = kind == "album" ? tracks[0].album : tracks[0].artist
        return try await playQueue(tracks, label: label, searchQuery: query, kind: kind, shuffle: shuffle, orderByAlbum: true, context: context)
    }

    private func playSingle(_ track: MusicTrack, searchQuery: String, kind: String, context: ExecutionContext) async throws -> ToolOutcome {
        let language = context.language
        if track.isLikelyUnavailable {
            throw JarvisError.failed("track_unavailable", en: "“\(track.name)” is in your library but Apple Music reports it as unavailable (\(track.cloudStatus)).", es: "«\(track.name)» está en tu biblioteca pero Apple Music indica que no está disponible (\(track.cloudStatus)).")
        }
        let row: String
        do {
            row = try await scripts.run(MusicScripts.playTrack, arguments: [track.id, searchQuery, kind], timeout: 30)
        } catch let failure as AppleScriptFailure {
            throw Self.playbackError(failure, track: track, language: language)
        }
        guard let state = MusicState(row: row), state.isPlaying, state.track?.id == track.id else {
            throw JarvisError.verificationFailed(LocalizedText(
                en: "Music did not confirm that “\(track.name)” is playing.",
                es: "Música no confirmó que «\(track.name)» esté sonando."
            ))
        }
        let message = track.artist.isEmpty
            ? language.pick("Playing “\(track.name)”.", "Reproduciendo «\(track.name)».")
            : language.pick("Playing “\(track.name)” by \(track.artist).", "Reproduciendo «\(track.name)» de \(track.artist).")
        return .done(ToolOutput(
            message: message, data: state.json,
            verification: .verified(language.pick("Music reports “playing” with this track as the current track.", "Música indica «sonando» con esta pista como actual."))
        ))
    }

    private func playQueue(_ matches: [MusicTrack], label: String, searchQuery: String, kind: String, shuffle: Bool, orderByAlbum: Bool, context: ExecutionContext) async throws -> ToolOutcome {
        let language = context.language
        guard !matches.isEmpty else { throw Self.notInLibrary(searchQuery, language) }
        let playable = matches.filter { !$0.isLikelyUnavailable }
        guard !playable.isEmpty else {
            throw JarvisError.failed("track_unavailable", en: "None of the matching songs are available to play right now.", es: "Ninguna de las canciones encontradas está disponible para reproducir ahora.")
        }
        // Album order: disc, then track number; artists: by album then track.
        let ordered = playable.sorted { left, right in
            if left.album != right.album { return left.album.localizedCaseInsensitiveCompare(right.album) == .orderedAscending }
            if left.discNumber != right.discNumber { return left.discNumber < right.discNumber }
            return left.trackNumber < right.trackNumber
        }.prefix(200)

        guard context.settings.musicUsesQueuePlaylist else {
            let first = ordered[ordered.startIndex]
            let single = try await playSingle(first, searchQuery: searchQuery, kind: kind == "artist" ? "artist" : (kind == "album" ? "album" : "any"), context: context)
            guard case .done(var output) = single else { return single }
            output.warnings.append(language.pick(
                "Queue playlists are switched off in Settings, so only the first matching song was played.",
                "Las listas de cola están desactivadas en Ajustes, así que solo se reprodujo la primera canción encontrada."
            ))
            return .done(output)
        }

        let queueName = context.settings.musicQueuePlaylistName
        let arguments = [queueName, searchQuery, kind, shuffle ? "true" : "false"] + ordered.map(\.id)
        let row: String
        do {
            row = try await scripts.run(MusicScripts.playQueue, arguments: arguments, timeout: 45)
        } catch let failure as AppleScriptFailure {
            throw Self.playbackError(failure, track: ordered[ordered.startIndex], language: language)
        }
        guard let state = MusicState(row: row), state.isPlaying, let current = state.track, ordered.contains(where: { $0.id == current.id }) else {
            throw JarvisError.verificationFailed(LocalizedText(
                en: "Music did not confirm that “\(label)” is playing.",
                es: "Música no confirmó que «\(label)» esté sonando."
            ))
        }
        let what = kind == "artist" ? language.pick("songs by \(label)", "canciones de \(label)") : language.pick("the album “\(label)”", "el álbum «\(label)»")
        let message = language.pick(
            "Playing \(what) (\(ordered.count) songs) — now “\(current.name)”.",
            "Reproduciendo \(what) (\(ordered.count) canciones) — ahora «\(current.name)»."
        )
        var data = state.json.objectValue ?? [:]
        data["queued_tracks"] = .int(ordered.count)
        data["queue_playlist"] = .string(queueName)
        return .done(ToolOutput(
            message: message, data: .object(data),
            verification: .verified(language.pick("Music reports “playing” and the current track belongs to the queued songs.", "Música indica «sonando» y la pista actual pertenece a las canciones en cola."))
        ))
    }

    private static func notInLibrary(_ query: String, _ language: Language) -> JarvisError {
        .notFound(code: "music_not_in_library", LocalizedText(
            en: "I couldn't find “\(query)” in your Apple Music library, so nothing was played. Jarvis can only play music that is in your library — add it in the Music app first.",
            es: "No encontré «\(query)» en tu biblioteca de Apple Music, así que no se reprodujo nada. Jarvis solo puede reproducir música que esté en tu biblioteca; agrégala primero en la app Música."
        ))
    }

    private static func playbackError(_ failure: AppleScriptFailure, track: MusicTrack, language: Language) -> JarvisError {
        switch (failure.kind, failure.code) {
        case (.custom, 9001):
            return .notFound(code: "music_not_found", LocalizedText(en: "That item is no longer in your library.", es: "Ese elemento ya no está en tu biblioteca."))
        case (.custom, 9005):
            let state = failure.detail.split(separator: "\u{1F}").first.map(String.init) ?? "?"
            return .failed(code: "music_not_playing", LocalizedText(
                en: "Music did not start playing “\(track.name)” (player state: \(state), cloud status: \(track.cloudStatus.isEmpty ? "unknown" : track.cloudStatus)). The song may be unavailable offline, or Music is waiting for you to respond to a dialog.",
                es: "Música no empezó a reproducir «\(track.name)» (estado: \(state), estado en la nube: \(track.cloudStatus.isEmpty ? "desconocido" : track.cloudStatus)). La canción puede no estar disponible sin conexión, o Música espera que respondas a un diálogo."
            ))
        case (.custom, 9006):
            return .failed(code: "music_empty", LocalizedText(en: "That playlist is empty.", es: "Esa lista está vacía."))
        default:
            return failure.jarvisError(app: "Music", requirement: requirement)
        }
    }

    // MARK: music.play_playlist

    private func playPlaylist(_ call: ValidatedToolCall, _ context: ExecutionContext) async throws -> ToolOutcome {
        let language = context.language
        let name = call.string("name") ?? ""
        let shuffle = call.bool("shuffle") ?? false
        let all = try await playlists().filter(\.isPlayable)

        let chosen: MusicPlaylist
        if let id = call.string("playlist_id") {
            guard let found = all.first(where: { $0.id == id }) else { throw Self.playlistNotFound(name, all, language) }
            chosen = found
        } else {
            let matches = NameMatcher.bestMatches(all, query: name, minimumScore: 60) { $0.name }
            switch matches.count {
            case 0:
                throw Self.playlistNotFound(name, all, language)
            case 1:
                chosen = matches[0]
            default:
                let options = matches.prefix(5).map { playlist in
                    ClarificationOption(
                        label: playlist.name, detail: language.pick("\(playlist.trackCount) songs", "\(playlist.trackCount) canciones"),
                        call: ToolCall(tool: .musicPlayPlaylist, arguments: ["name": .string(playlist.name), "playlist_id": .string(playlist.id), "shuffle": .bool(shuffle)])
                    )
                }
                return .clarify(Clarification(
                    question: language.pick("You have several playlists matching “\(name)”. Which one?", "Tienes varias listas que coinciden con «\(name)». ¿Cuál?"),
                    options: Array(options)
                ))
            }
        }

        let row: String
        do {
            row = try await scripts.run(MusicScripts.playPlaylist, arguments: [chosen.id, shuffle ? "true" : "false"], timeout: 30)
        } catch let failure as AppleScriptFailure {
            switch (failure.kind, failure.code) {
            case (.custom, 9006):
                throw JarvisError.failed("playlist_empty", en: "The playlist “\(chosen.name)” is empty.", es: "La lista «\(chosen.name)» está vacía.")
            case (.custom, 9001):
                throw Self.playlistNotFound(name, all, language)
            case (.custom, 9005):
                throw JarvisError.failed("music_not_playing", en: "Music did not start playing “\(chosen.name)”. Songs may be unavailable offline, or Music is waiting for you to respond to a dialog.", es: "Música no empezó a reproducir «\(chosen.name)». Las canciones pueden no estar disponibles sin conexión, o Música espera que respondas a un diálogo.")
            default:
                throw failure.jarvisError(app: "Music", requirement: Self.requirement)
            }
        }
        guard let state = MusicState(row: row), state.isPlaying else {
            throw JarvisError.verificationFailed(LocalizedText(en: "Music did not confirm that “\(chosen.name)” is playing.", es: "Música no confirmó que «\(chosen.name)» esté sonando."))
        }
        var data = state.json.objectValue ?? [:]
        data["playlist"] = .string(chosen.name)
        data["playlist_id"] = .string(chosen.id)
        let now = state.track.map { language.pick(" — now “\($0.name)”", " — ahora «\($0.name)»") } ?? ""
        return .done(ToolOutput(
            message: language.pick("Playing your playlist “\(chosen.name)”\(now).", "Reproduciendo tu lista «\(chosen.name)»\(now)."),
            data: .object(data),
            verification: .verified(language.pick("Music reports “playing”.", "Música indica «sonando»."))
        ))
    }

    private static func playlistNotFound(_ name: String, _ all: [MusicPlaylist], _ language: Language) -> JarvisError {
        let sample = all.prefix(8).map(\.name).joined(separator: ", ")
        let hint = sample.isEmpty ? "" : language.pick(" Your playlists include: \(sample).", " Tus listas incluyen: \(sample).")
        return .notFound(code: "playlist_not_found", LocalizedText(
            en: "I couldn't find a playlist called “\(name)”.\(hint)",
            es: "No encontré una lista llamada «\(name)».\(hint)"
        ))
    }

    // MARK: Transport

    private func transport(_ call: ValidatedToolCall, _ context: ExecutionContext) async throws -> ToolOutcome {
        let language = context.language
        let name = call.descriptor.name
        let action: String
        switch name {
        case .musicPause: action = "pause"
        case .musicResume: action = "resume"
        case .musicStop: action = "stop"
        case .musicNext: action = "next"
        default: action = "previous"
        }

        // Do not launch Music just to pause it.
        if !access.isRunning, Self.neverLaunches.contains(name) {
            let message = language.pick("Music isn't running, so nothing is playing.", "Música no está abierta, así que no hay nada sonando.")
            switch name {
            case .musicPause, .musicStop:
                return .done(ToolOutput(message: message, data: ["player_state": "not_running"], verification: .verified(language.pick("Music is not running.", "Música no está abierta."))))
            default:
                throw JarvisError.failed("music_not_running", en: message, es: message)
            }
        }

        let output = try await run(MusicScripts.transport, [action], timeout: 25)
        let records = ScriptRecords.parse(output)
        guard records.count == 2, let before = MusicState(fields: records[0]), let after = MusicState(fields: records[1]) else {
            throw JarvisError.failed("unexpected_output", en: "Music returned something Jarvis could not read.", es: "Música devolvió algo que Jarvis no pudo interpretar.")
        }

        switch name {
        case .musicPause:
            guard !after.isPlaying else {
                throw JarvisError.verificationFailed(LocalizedText(en: "Music is still playing.", es: "Música sigue sonando."))
            }
            let what = (before.track ?? after.track).map { Formatting.quoted($0.name, language) }
            return .done(ToolOutput(
                message: before.isPlaying
                    ? language.pick("Paused\(what.map { " " + $0 } ?? "").", "Pausado\(what.map { " " + $0 } ?? "").")
                    : language.pick("Music was already paused.", "Música ya estaba en pausa."),
                data: after.json, verification: .verified(language.pick("Music reports “\(after.player)”.", "Música indica «\(after.player)».")))
            )
        case .musicStop:
            guard after.player == "stopped" else {
                throw JarvisError.verificationFailed(LocalizedText(en: "Music did not stop.", es: "Música no se detuvo."))
            }
            return .done(ToolOutput(message: language.pick("Stopped playback.", "Reproducción detenida."), data: after.json, verification: .verified(language.pick("Music reports “stopped”.", "Música indica «detenido»."))))
        case .musicResume:
            guard after.isPlaying else {
                throw JarvisError.failed("music_not_playing", en: "Music didn't start playing — nothing seems to be queued. Try “play my <playlist> playlist” or “play <song>”.", es: "Música no empezó a reproducir: parece que no hay nada en cola. Prueba «pon mi lista <nombre>» o «pon <canción>».")
            }
            let what = after.track.map { " " + Formatting.quoted($0.name, language) } ?? ""
            return .done(ToolOutput(message: language.pick("Playing\(what).", "Reproduciendo\(what)."), data: after.json, verification: .verified(language.pick("Music reports “playing”.", "Música indica «sonando»."))))
        default:
            let changed = after.track?.id != before.track?.id
            let restarted = name == .musicPrevious && after.position <= 3
            guard after.isPlaying, changed || restarted else {
                throw JarvisError.verificationFailed(LocalizedText(
                    en: "Music did not move to another track (is anything playing?).",
                    es: "Música no cambió de pista (¿hay algo reproduciéndose?)."
                ))
            }
            let now = after.track.map { $0.artist.isEmpty ? Formatting.quoted($0.name, language) : "\(Formatting.quoted($0.name, language)) — \($0.artist)" } ?? ""
            return .done(ToolOutput(
                message: name == .musicNext ? language.pick("Skipped to \(now).", "Saltó a \(now).") : language.pick("Back to \(now).", "Volvió a \(now)."),
                data: after.json, verification: .verified(language.pick("The current track changed and Music reports “playing”.", "La pista actual cambió y Música indica «sonando»."))
            ))
        }
    }

    // MARK: Volume, now playing, search, playlists

    private func setVolume(_ call: ValidatedToolCall, _ context: ExecutionContext) async throws -> ToolOutcome {
        let language = context.language
        if !access.isRunning {
            throw JarvisError.failed("music_not_running", en: "Music isn't running; open it first to change its volume.", es: "Música no está abierta; ábrela primero para cambiar su volumen.")
        }
        let (mode, value): (String, Int) = call.int("level").map { ("level", $0) } ?? ("delta", call.int("delta") ?? 0)
        let before = try await state()
        let after = try await state(MusicScripts.volume, [mode, String(value)])
        let expected = mode == "level" ? value : min(100, max(0, before.volume + value))
        guard abs(after.volume - expected) <= 1 else {
            throw JarvisError.verificationFailed(LocalizedText(en: "Music's volume is \(after.volume)% instead of \(expected)%.", es: "El volumen de Música es \(after.volume)% en lugar de \(expected)%."))
        }
        let message: String
        if mode == "level" {
            message = language.pick("Volume set to \(after.volume)%.", "Volumen al \(after.volume)%.")
        } else if value >= 0 {
            message = language.pick("Volume raised to \(after.volume)%.", "Volumen subido al \(after.volume)%.")
        } else {
            message = language.pick("Volume lowered to \(after.volume)%.", "Volumen bajado al \(after.volume)%.")
        }
        return .done(ToolOutput(message: message, data: after.json, verification: .verified(language.pick("Read the volume back from Music.", "Se volvió a leer el volumen de Música."))))
    }

    private func nowPlaying(_ context: ExecutionContext) async throws -> ToolOutcome {
        let language = context.language
        guard access.isRunning else {
            return .done(ToolOutput(message: language.pick("Music isn't running, so nothing is playing.", "Música no está abierta, así que no hay nada sonando."), data: ["player_state": "not_running"], verification: .notApplicable))
        }
        let state = try await state()
        guard let track = state.track else {
            return .done(ToolOutput(message: language.pick("Nothing is playing.", "No hay nada sonando."), data: state.json, verification: .notApplicable))
        }
        let position = "\(Formatting.clock(state.position)) / \(Formatting.clock(track.duration))"
        let by = track.artist.isEmpty ? "" : language.pick(" by \(track.artist)", " de \(track.artist)")
        let album = track.album.isEmpty ? "" : " (\(track.album))"
        let verb: String
        switch state.player {
        case "playing": verb = language.pick("Playing", "Sonando")
        case "paused": verb = language.pick("Paused on", "En pausa:")
        default: verb = language.pick("Stopped at", "Detenido en")
        }
        return .done(ToolOutput(
            message: "\(verb) \(Formatting.quoted(track.name, language))\(by)\(album) — \(position), " + language.pick("volume \(state.volume)%", "volumen \(state.volume)%"),
            data: state.json, verification: .notApplicable
        ))
    }

    private func search(_ call: ValidatedToolCall, _ context: ExecutionContext) async throws -> ToolOutcome {
        let language = context.language
        let query = call.string("query") ?? ""
        let kind = call.string("kind") ?? "any"
        let limit = call.int("limit") ?? 10
        let found = try await searchLibrary(query: query, kind: kind, limit: max(limit, 50), allowFuzzy: true)
        let tracks = found.filter { track in
            let names = kind == "album" ? [track.album] : kind == "artist" ? [track.artist] : kind == "song" ? [track.name] : [track.name, track.artist, track.album]
            return names.contains { FuzzyNameMatcher.score(query: query, candidate: $0) >= 50 }
        }
        let shown = Array(tracks.prefix(limit))
        guard !shown.isEmpty else {
            return .done(ToolOutput(message: language.pick("No songs matching “\(query)” in your library.", "No hay canciones que coincidan con «\(query)» en tu biblioteca."), data: ["results": [], "count": 0], verification: .notApplicable))
        }
        let lines = shown.map { track -> String in
            let album = track.album.isEmpty ? "" : " · \(track.album)"
            return "\(track.display)\(album)"
        }
        return .done(ToolOutput(
            message: language.pick("Found \(tracks.count) match\(tracks.count == 1 ? "" : "es") for “\(query)”:\n", "Encontré \(tracks.count) coincidencia\(tracks.count == 1 ? "" : "s") para «\(query)»:\n") + Formatting.bullets(lines),
            data: ["results": .array(shown.map(\.json)), "count": .int(tracks.count)], verification: .notApplicable
        ))
    }

    private func listPlaylists(_ call: ValidatedToolCall, _ context: ExecutionContext) async throws -> ToolOutcome {
        let language = context.language
        let limit = call.int("limit") ?? 100
        let all = try await playlists().filter(\.isPlayable)
        let shown = Array(all.prefix(limit))
        guard !shown.isEmpty else {
            return .done(ToolOutput(message: language.pick("You don't have any playlists yet.", "Todavía no tienes listas de reproducción."), data: ["playlists": [], "count": 0], verification: .notApplicable))
        }
        let lines = shown.map { language.pick("\($0.name) — \($0.trackCount) songs", "\($0.name) — \($0.trackCount) canciones") }
        return .done(ToolOutput(
            message: language.pick("You have \(all.count) playlists:\n", "Tienes \(all.count) listas de reproducción:\n") + Formatting.bullets(lines),
            data: ["playlists": .array(shown.map(\.json)), "count": .int(all.count)], verification: .notApplicable
        ))
    }
}
