import JarvisCore
import XCTest

@testable import JarvisIntegrations

private actor CatalogFixture: WeatherDataLoading {
    var requests: [URL] = []
    func load(_ url: URL) async throws -> JSONValue {
        requests.append(url)
        return [
            "results": [
                [
                    "wrapperType": "collection", "collectionId": 100, "artistId": 7, "artistName": "Queen",
                    "collectionName": "Album", "releaseDate": "1975-11-21T00:00:00Z",
                ],
                [
                    "wrapperType": "track", "kind": "song", "trackId": 102, "collectionId": 100, "artistId": 7,
                    "artistName": "Queen", "trackName": "Second", "discNumber": 1, "trackNumber": 2,
                    "previewUrl": "https://example.com/preview",
                    "trackViewUrl": "https://music.apple.com/gb/album/100?i=102",
                ],
                [
                    "wrapperType": "track", "kind": "song", "trackId": 101, "collectionId": 100, "artistId": 7,
                    "artistName": "Queen", "trackName": "First", "discNumber": 1, "trackNumber": 1,
                    "trackViewUrl": "https://attacker.example/song",
                ],
                [
                    "wrapperType": "track", "kind": "song", "trackId": 999, "collectionId": 900, "artistId": 8,
                    "artistName": "Other", "trackName": "Wrong album",
                ],
            ]
        ]
    }
}
final class CatalogIntegrationTests: XCTestCase {
    func testAlbumUsesVerifiedCollectionIDsAndTrackOrderAndCachesMetadataOnly() async throws {
        let fixture = CatalogFixture()
        let registry = ToolRegistry(integrations: [CatalogIntegration(cache: MusicCatalogCache(loader: fixture))])
        let args: JSONObject = ["collection_id": 100, "country": "GB"]
        let first = try await registry.run("catalog.album_tracks", args)
        let results = try XCTUnwrap(first.output?.data?["results"]?.arrayValue)
        XCTAssertEqual(results.compactMap { $0["trackId"]?.intValue }, [101, 102])
        XCTAssertNil(results[0]["trackViewUrl"])
        XCTAssertNil(results[1]["previewUrl"])
        XCTAssertEqual(first.output?.data?["catalog_ids_are_library_ids"], false)
        _ = try await registry.run("catalog.album_tracks", args)
        let requests = await fixture.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].host, "itunes.apple.com")
        XCTAssertTrue(requests[0].query?.contains("id=100") == true)
    }
    func testInvalidCountryNeverReachesNetworkAndRateLimitIsBounded() async throws {
        let fixture = CatalogFixture()
        let cache = MusicCatalogCache(loader: fixture)
        let registry = ToolRegistry(integrations: [CatalogIntegration(cache: cache)])
        do {
            _ = try await registry.run("catalog.search", ["query": "Queen", "country": "../"])
            XCTFail()
        } catch {}
        let before = await fixture.requests.count
        XCTAssertEqual(before, 0)
        for i in 0..<20 {
            _ = try await cache.load(
                URL(string: "https://itunes.apple.com/search?term=\(i)")!, now: Date(timeIntervalSince1970: 1000))
        }
        do {
            _ = try await cache.load(
                URL(string: "https://itunes.apple.com/search?term=21")!, now: Date(timeIntervalSince1970: 1001))
            XCTFail()
        } catch let error as JarvisError { XCTAssertEqual(error.code, "catalog_rate_limit") }
        let count = await fixture.requests.count
        XCTAssertEqual(count, 20)
    }
}
