import Foundation
import JarvisCore

struct MusicTrack: Sendable, Hashable {
    var id: String
    var name: String
    var artist: String
    var album: String
    var duration: Int
    var cloudStatus: String
    var kind: String
    var discNumber: Int
    var trackNumber: Int
    var year: Int

    init(id: String, name: String, artist: String, album: String, duration: Int = 0, cloudStatus: String = "", kind: String = "", discNumber: Int = 0, trackNumber: Int = 0, year: Int = 0) {
        self.id = id
        self.name = name
        self.artist = artist
        self.album = album
        self.duration = duration
        self.cloudStatus = cloudStatus
        self.kind = kind
        self.discNumber = discNumber
        self.trackNumber = trackNumber
        self.year = year
    }

    /// Parses a search record: id, name, artist, album, duration, cloud, class, disc, track, year.
    init?(searchFields f: [String]) {
        guard f.count >= 7, !f[0].isEmpty else { return nil }
        self.init(
            id: f[0], name: f[1], artist: f[2], album: f[3], duration: Int(f[4]) ?? 0, cloudStatus: f[5], kind: f[6],
            discNumber: f.count > 7 ? Int(f[7]) ?? 0 : 0, trackNumber: f.count > 8 ? Int(f[8]) ?? 0 : 0, year: f.count > 9 ? Int(f[9]) ?? 0 : 0
        )
    }

    var json: JSONValue {
        .object([
            "id": .string(id), "name": .string(name), "artist": .string(artist), "album": .string(album),
            "duration_seconds": .int(duration),
        ])
    }

    var display: String { artist.isEmpty ? name : "\(name) — \(artist)" }

    /// `true` when the track is known to be unplayable (removed from the catalogue, error, not eligible…).
    var isLikelyUnavailable: Bool {
        ["removed", "error", "no longer available", "not eligible", "ineligible"].contains(cloudStatus.lowercased())
    }
}

struct MusicState: Sendable, Equatable {
    var player: String
    var volume: Int
    var shuffle: Bool
    var repeatMode: String
    var position: Int
    var track: MusicTrack?

    /// Parses the 12-field state row produced by `stateRow()`.
    init?(fields f: [String]) {
        guard f.count >= 12 else { return nil }
        player = f[0]
        volume = Int(f[1]) ?? 0
        shuffle = f[2] == "true"
        repeatMode = f[3]
        position = Int(f[4]) ?? 0
        track = f[5].isEmpty ? nil : MusicTrack(id: f[5], name: f[6], artist: f[7], album: f[8], duration: Int(f[9]) ?? 0, cloudStatus: f[10], kind: f[11])
    }

    init?(row: String) { self.init(fields: ScriptRecords.fields(row)) }

    var isPlaying: Bool { player == "playing" }

    var json: JSONValue {
        var object: JSONObject = [
            "player_state": .string(player), "volume": .int(volume), "shuffle": .bool(shuffle),
            "repeat": .string(repeatMode), "position_seconds": .int(position),
        ]
        if let track {
            object["track"] = track.json
        }
        return .object(object)
    }
}

struct MusicPlaylist: Sendable, Hashable {
    var id: String
    var name: String
    var specialKind: String
    var isSmart: Bool
    var trackCount: Int
    var parent: String

    init?(fields f: [String]) {
        guard f.count >= 6, !f[0].isEmpty else { return nil }
        id = f[0]; name = f[1]; specialKind = f[2]; isSmart = f[3] == "true"; trackCount = Int(f[4]) ?? 0; parent = f[5]
    }

    /// Folder playlists and system playlists (Library, Music, Purchased…) cannot be played by name.
    var isPlayable: Bool { specialKind == "none" }

    var json: JSONValue {
        .object(["id": .string(id), "name": .string(name), "smart": .bool(isSmart), "track_count": .int(trackCount), "folder": parent.isEmpty ? .null : .string(parent)])
    }
}

/// Ranks library search results against what the user asked for.
enum MusicRanking {
    struct Candidate {
        var track: MusicTrack
        var score: Int
    }

    /// Scores tracks by title (strongest), artist and album. `query` is the user's text, `artist` an optional hint.
    static func rank(_ tracks: [MusicTrack], query: String, artist: String?) -> [Candidate] {
        var seen = Set<String>()
        var candidates: [Candidate] = []
        for track in tracks {
            // The same song on a compilation and its album is one result.
            let key = TextFolding.fold(track.name) + "|" + TextFolding.fold(track.artist)
            if !seen.insert(key).inserted { continue }
            var score = NameMatcher.score(query: query, candidate: track.name)
            if let artist, !artist.isEmpty {
                let artistScore = NameMatcher.score(query: artist, candidate: track.artist)
                guard artistScore >= 50 else { continue }
                score = score > 0 ? min(100, score + artistScore / 10) : 0
            }
            if score >= 50 { candidates.append(Candidate(track: track, score: score)) }
        }
        return candidates.sorted { $0.score > $1.score }
    }

    /// Splits "Hello by Adele" / "La Bamba de Ritchie Valens" / "Song - Artist" into possible (title, artist) pairs.
    static func titleArtistSplits(_ query: String) -> [(title: String, artist: String)] {
        var results: [(String, String)] = []
        let separators = [" by ", " de ", " del ", " - ", " – ", " — ", " from "]
        let lowered = query.lowercased()
        for separator in separators {
            var searchStart = lowered.startIndex
            while let range = lowered.range(of: separator, range: searchStart..<lowered.endIndex) {
                let title = String(query[query.startIndex..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                let artist = String(query[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !title.isEmpty, !artist.isEmpty { results.append((title, artist)) }
                searchStart = range.upperBound
            }
        }
        return results
    }
}
