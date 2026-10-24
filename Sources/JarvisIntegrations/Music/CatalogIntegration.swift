import Foundation
import JarvisCore

/// Public iTunes Store metadata, separate from Music library persistent IDs and subscription playback.
public actor MusicCatalogCache {
    private let loader: any WeatherDataLoading
    private var entries: [URL: (Date, JSONValue)] = [:]
    private var requests: [Date] = []
    public init(loader: any WeatherDataLoading = WeatherURLLoader()) { self.loader = loader }
    func load(_ url: URL, now: Date) async throws -> JSONValue {
        if let (date, value) = entries[url], (0..<600).contains(now.timeIntervalSince(date)) { return value }
        requests.removeAll { now.timeIntervalSince($0) >= 60 || now < $0 }
        guard requests.count < 20 else {
            throw integrationFailure(
                "catalog_rate_limit", "Wait a minute before another catalog request.",
                "Espera un minuto antes de otra consulta al catálogo.")
        }
        requests.append(now)
        let value = try await loader.load(url)
        guard value["results"]?.arrayValue != nil else { throw URLError(.cannotParseResponse) }
        entries[url] = (now, value)
        if entries.count > 32, let oldest = entries.min(by: { $0.value.0 < $1.value.0 })?.key { entries[oldest] = nil }
        return value
    }
}

public struct CatalogIntegration: AppIntegration {
    public let id: IntegrationID = "catalog"
    public let displayName = LocalizedText(en: "Music catalog", es: "Catálogo musical")
    public let summary = LocalizedText(
        en:
            "Real iTunes Store song, album and artist metadata with Apple links. Storefront coverage varies; playback uses Music library tools.",
        es:
            "Metadatos reales de canciones, álbumes y artistas de iTunes Store con enlaces a Apple. La cobertura depende del país; la reproducción usa la biblioteca de Música."
    )
    public let symbolName = "music.magnifyingglass"
    public let permissionRequirements: [PermissionRequirement] = []
    private let cache: MusicCatalogCache
    public init(cache: MusicCatalogCache = MusicCatalogCache()) { self.cache = cache }
    public var tools: [ToolDescriptor] {
        let country = ToolParameter.string(
            "country", "Two-letter store country, for example GB or ES; defaults to the user's region, then US.",
            maxLength: 2)
        return [
            ToolDescriptor(
                name: "catalog.search", integration: id, title: "Search music catalog",
                summary:
                    "Searches Apple's public iTunes Store for actual songs, albums or artists. Use title/artist/release date metadata to disambiguate. No lyrics, similarity or global popularity data. Catalog IDs are NOT Music library IDs. Search the library before playback; returned store URLs may be opened with user confirmation, but opening is not playback.",
                parameters: [
                    .string("query", "Artist, album or song query.", required: true, maxLength: 300),
                    .choice("kind", ["song", "album", "artist"], "Kind of entity.", default: "song"), country,
                    .integer("limit", "Maximum matches.", min: 1, max: 50, default: 20),
                ], safety: .readOnly, timeout: 25),
            ToolDescriptor(
                name: "catalog.album_tracks", integration: id, title: "Read catalog album tracks",
                summary:
                    "Looks up an actual catalog collection_id and its songs in disc/track order. Does not add to the library or start playback.",
                parameters: [
                    .integer("collection_id", "Actual catalog album ID from search.", required: true, min: 1), country,
                ], safety: .readOnly, timeout: 25),
            ToolDescriptor(
                name: "catalog.artist_albums", integration: id, title: "Read catalog artist albums",
                summary:
                    "Looks up up to 50 albums for an actual artist_id and sorts returned albums by release date. A bounded storefront result is not a guarantee of a complete discography or a globally latest release.",
                parameters: [
                    .integer("artist_id", "Actual catalog artist ID from search.", required: true, min: 1), country,
                ], safety: .readOnly, timeout: 25),
        ]
    }
    public func status() async -> IntegrationStatus {
        IntegrationStatus(
            state: .ready,
            detail: LocalizedText(
                en: "Apple iTunes Search API · internet required",
                es: "API de búsqueda de iTunes de Apple · requiere internet"))
    }
    public func authorization(for tool: ToolDescriptor) async -> AuthorizationState { .authorized }
    public func requestAuthorization(for tool: ToolDescriptor) async -> AuthorizationState { .authorized }

    static func metadata(_ value: JSONValue) -> JSONValue? {
        let keys = [
            "wrapperType", "kind", "artistId", "collectionId", "trackId", "artistName", "collectionName", "trackName",
            "releaseDate", "primaryGenreName", "trackTimeMillis", "discNumber", "trackNumber", "trackCount", "country",
            "trackExplicitness",
        ]
        guard value["artistName"]?.stringValue != nil else { return nil }
        var result: JSONObject = [:]
        for key in keys { result[key] = value[key] }
        for key in ["trackViewUrl", "collectionViewUrl", "artistViewUrl"] {
            if let raw = value[key]?.stringValue, let url = URL(string: raw), url.scheme == "https",
                let host = url.host?.lowercased(), ["music.apple.com", "itunes.apple.com"].contains(host),
                url.user == nil, url.password == nil
            {
                result[key] = .string(url.absoluteString)
            }
        }
        // Promotional previews and artwork are deliberately neither exposed nor played.
        return .object(result)
    }
    public func execute(_ call: ValidatedToolCall, context: ExecutionContext) async throws -> ToolOutcome {
        let country = (call.string("country") ?? Locale.current.region?.identifier ?? "US").uppercased()
        guard country.utf8.count == 2, country.utf8.allSatisfy({ (65...90).contains($0) }) else {
            throw integrationFailure(
                "catalog_country", "Use a two-letter store country.", "Usa un país de dos letras para la tienda.")
        }
        let operation = call.descriptor.name.rawValue
        var url = URLComponents(
            string: "https://itunes.apple.com/" + (operation == "catalog.search" ? "search" : "lookup"))!
        var query = [URLQueryItem(name: "country", value: country), URLQueryItem(name: "media", value: "music")]
        if operation == "catalog.search" {
            let kind = call.string("kind") ?? "song"
            query += [
                URLQueryItem(name: "term", value: call.string("query")),
                URLQueryItem(name: "entity", value: kind == "artist" ? "musicArtist" : kind),
                URLQueryItem(name: "limit", value: String(call.int("limit") ?? 20)),
            ]
        } else {
            query += [
                URLQueryItem(
                    name: "id",
                    value: String(call.int(operation == "catalog.album_tracks" ? "collection_id" : "artist_id") ?? 0)),
                URLQueryItem(name: "entity", value: operation == "catalog.album_tracks" ? "song" : "album"),
                URLQueryItem(name: "limit", value: operation == "catalog.album_tracks" ? "200" : "50"),
            ]
            if operation == "catalog.artist_albums" { query.append(URLQueryItem(name: "sort", value: "recent")) }
        }
        url.queryItems = query
        let response = try await cache.load(url.url!, now: context.now)
        var items = (response["results"]?.arrayValue ?? []).prefix(201).compactMap(Self.metadata)
        if operation == "catalog.album_tracks" {
            items = items.filter {
                $0["kind"]?.stringValue == "song" && $0["collectionId"]?.intValue == call.int("collection_id")
            }.sorted {
                (($0["discNumber"]?.intValue ?? 0), ($0["trackNumber"]?.intValue ?? 0)) < (
                    ($1["discNumber"]?.intValue ?? 0), ($1["trackNumber"]?.intValue ?? 0)
                )
            }
        } else if operation == "catalog.artist_albums" {
            items = items.filter {
                $0["wrapperType"]?.stringValue == "collection" && $0["artistId"]?.intValue == call.int("artist_id")
            }.sorted { ($0["releaseDate"]?.stringValue ?? "") > ($1["releaseDate"]?.stringValue ?? "") }
        }
        let description = items.prefix(20).map { item in
            [
                item["trackName"]?.stringValue ?? item["collectionName"]?.stringValue ?? "",
                item["artistName"]?.stringValue ?? "", item["releaseDate"]?.stringValue ?? "",
            ].filter { !$0.isEmpty }.joined(separator: " · ")
        }.joined(separator: "\n")
        return .done(
            ToolOutput(
                message: description.isEmpty
                    ? context.language.pick("No store matches found.", "No encontré coincidencias en la tienda.")
                    : description,
                data: [
                    "results": .array(items), "country": .string(country), "source": "Apple iTunes Search API",
                    "retrieved_at": .string(ISODates.string(from: context.now, timeZone: context.timeZone)),
                    "subscription_playback": false, "catalog_ids_are_library_ids": false,
                ], verification: .verified("Retrieved actual Apple catalog metadata; no playback was requested.")))
    }
}
