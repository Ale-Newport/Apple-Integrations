import XCTest
import JarvisCore
@testable import JarvisIntegrations

private enum Fx {
    static func state(_ player: String = "playing", volume: Int = 50, pid: String = "T1", name: String = "Bohemian Rhapsody", artist: String = "Queen", album: String = "A Night at the Opera", position: Int = 5) -> String {
        Rec.fields(player, String(volume), "false", "off", String(position), pid, name, artist, album, "355", "subscription", "file track")
    }

    static func track(_ pid: String, _ name: String, _ artist: String, _ album: String, disc: Int = 1, number: Int = 1, cloud: String = "purchased") -> String {
        Rec.fields(pid, name, artist, album, "200", cloud, "file track", String(disc), String(number), "1975")
    }

    static func playlistRow(_ pid: String, _ name: String, kind: String = "none", count: Int = 10) -> String {
        Rec.fields(pid, name, kind, "false", String(count), "")
    }

}

final class MusicIntegrationTests: XCTestCase {
    private let scripts = FakeScripts()

    private func registry(access: FakeAutomation = FakeAutomation()) -> ToolRegistry {
        ToolRegistry(integrations: [MusicIntegration(scripts: scripts, access: access)])
    }

    // MARK: Playing songs

    func testHostileTextTravelsOnlyAsData() async throws {
        scripts.on(MusicScripts.search, returns: "")
        let hostile = "Song\" & (do shell script \"touch /tmp/pwned\") & \""
        do {
            _ = try await registry().run(.musicPlay, ["query": .string(hostile)])
            XCTFail("should have thrown")
        } catch JarvisError.notFound {
            // nothing matched, so nothing played
        }
        // The text reached the script as an argv item, verbatim…
        XCTAssertEqual(scripts.calls(to: MusicScripts.search).first?.arguments.first, hostile)
        // …and no bundled script contains anything derived from it.
        for script in MusicScripts.all { XCTAssertFalse(script.text.contains("pwned"), script.name) }
    }

    func testPlaySongSuccess() async throws {
        scripts.on(MusicScripts.search, returns: Fx.track("T1", "Bohemian Rhapsody", "Queen", "A Night at the Opera"))
        scripts.on(MusicScripts.playTrack, returns: Fx.state())

        let outcome = try await registry().run(.musicPlay, ["query": "Bohemian Rhapsody"])
        let output = try XCTUnwrap(outcome.output)
        XCTAssertEqual(output.message, "Playing “Bohemian Rhapsody” by Queen.")
        XCTAssertTrue(output.verification.isVerified)
        XCTAssertEqual(output.data?["track"]?["name"], "Bohemian Rhapsody")
        XCTAssertEqual(scripts.calls(to: MusicScripts.playTrack).first?.arguments, ["T1", "Bohemian Rhapsody", "any"])
    }

    func testSpanishMessages() async throws {
        scripts.on(MusicScripts.search, returns: Fx.track("T1", "Bohemian Rhapsody", "Queen", "A Night at the Opera"))
        scripts.on(MusicScripts.playTrack, returns: Fx.state())
        let outcome = try await registry().run(.musicPlay, ["query": "Bohemian Rhapsody"], context: executionContext(language: .es))
        XCTAssertEqual(outcome.output?.message, "Reproduciendo «Bohemian Rhapsody» de Queen.")
    }

    func testSongMissingFromLibraryIsNeverReportedAsPlaying() async throws {
        scripts.on(MusicScripts.search, returns: "")
        do {
            _ = try await registry().run(.musicPlay, ["query": "Imaginary Song"])
            XCTFail("should have thrown")
        } catch JarvisError.notFound(let code, let text) {
            XCTAssertEqual(code, "music_not_in_library")
            XCTAssertTrue(text.en.contains("nothing was played"))
        }
        XCTAssertTrue(scripts.calls(to: MusicScripts.playTrack).isEmpty, "must not try to play anything")
    }

    func testMusicThatIsInTheLibraryButStillNotPlayingIsAnError() async throws {
        scripts.on(MusicScripts.search, returns: Fx.track("T1", "Bohemian Rhapsody", "Queen", "A Night at the Opera"))
        scripts.on(MusicScripts.playTrack, failsWith: AppleScriptFailure(kind: .custom, code: 9005, message: "NOT_PLAYING|" + Fx.state("stopped", pid: "")))
        do {
            _ = try await registry().run(.musicPlay, ["query": "Bohemian Rhapsody"])
            XCTFail("should have thrown")
        } catch JarvisError.failed(let code, let text) {
            XCTAssertEqual(code, "music_not_playing")
            XCTAssertTrue(text.en.contains("did not start playing"))
        }
    }

    func testWrongTrackPlayingIsCaughtByVerification() async throws {
        scripts.on(MusicScripts.search, returns: Fx.track("T1", "Bohemian Rhapsody", "Queen", "A Night at the Opera"))
        scripts.on(MusicScripts.playTrack, returns: Fx.state(pid: "OTHER", name: "Something else"))
        do {
            _ = try await registry().run(.musicPlay, ["query": "Bohemian Rhapsody"])
            XCTFail("should have thrown")
        } catch JarvisError.verificationFailed {
            // expected
        }
    }

    func testSongsWithTheSameTitleByDifferentArtistsAskWhichOne() async throws {
        scripts.on(MusicScripts.search, returns: Rec.records([
            Fx.track("A1", "Hello", "Adele", "25"), Fx.track("L1", "Hello", "Lionel Richie", "Can't Slow Down"), Fx.track("E1", "Hello", "Evanescence", "Fallen"),
        ]))
        scripts.on(MusicScripts.playTrack, returns: Fx.state(pid: "L1", name: "Hello", artist: "Lionel Richie"))

        let outcome = try await registry().run(.musicPlay, ["query": "Hello"])
        let clarification = try XCTUnwrap(outcome.clarification)
        XCTAssertEqual(clarification.options.count, 3)
        XCTAssertEqual(clarification.options.map(\.label), ["Hello — Adele", "Hello — Lionel Richie", "Hello — Evanescence"])
        XCTAssertTrue(scripts.calls(to: MusicScripts.playTrack).isEmpty, "nothing plays until the user chooses")

        // Choosing an option plays exactly that track.
        let chosen = clarification.options[1].call
        XCTAssertEqual(chosen.arguments["track_id"], "L1")
        let played = try await registry().run(.musicPlay, chosen.arguments)
        XCTAssertEqual(played.output?.data?["track"]?["artist"], "Lionel Richie")
    }

    func testArtistHintResolvesTheAmbiguity() async throws {
        scripts.on(MusicScripts.search, returns: Rec.records([Fx.track("A1", "Hello", "Adele", "25"), Fx.track("L1", "Hello", "Lionel Richie", "Can't Slow Down")]))
        scripts.on(MusicScripts.playTrack, returns: Fx.state(pid: "A1", name: "Hello", artist: "Adele"))
        let outcome = try await registry().run(.musicPlay, ["query": "Hello", "artist": "Adele"])
        XCTAssertEqual(outcome.output?.data?["track"]?["artist"], "Adele")
    }

    func testTitleByArtistIsRetriedAsTwoParts() async throws {
        scripts.on(MusicScripts.search) { arguments, _ in
            arguments[0] == "Hello by Adele" ? "" : Fx.track("A1", "Hello", "Adele", "25")
        }
        scripts.on(MusicScripts.playTrack, returns: Fx.state(pid: "A1", name: "Hello", artist: "Adele"))
        let outcome = try await registry().run(.musicPlay, ["query": "Hello by Adele"])
        XCTAssertNotNil(outcome.output)
        XCTAssertEqual(scripts.calls(to: MusicScripts.search).map { $0.arguments[0] }, ["Hello by Adele", "Hello"])
    }

    func testSpanishDeSeparatorIsHandledByTheIntegration() async throws {
        scripts.on(MusicScripts.search) { arguments, _ in
            arguments[0].contains(" de ") ? "" : Fx.track("R1", "La Bamba", "Ritchie Valens", "Ritchie Valens")
        }
        scripts.on(MusicScripts.playTrack, returns: Fx.state(pid: "R1", name: "La Bamba", artist: "Ritchie Valens"))
        let outcome = try await registry().run(.musicPlay, ["query": "La Bamba de Ritchie Valens"], context: executionContext(language: .es))
        XCTAssertNotNil(outcome.output)
    }

    func testUnavailableCloudTracksAreRefusedHonestly() async throws {
        scripts.on(MusicScripts.search, returns: Fx.track("T1", "Gone Song", "Someone", "Album", cloud: "removed"))
        do {
            _ = try await registry().run(.musicPlay, ["query": "Gone Song"])
            XCTFail("should have thrown")
        } catch JarvisError.failed(let code, _) {
            XCTAssertEqual(code, "track_unavailable")
        }
        XCTAssertTrue(scripts.calls(to: MusicScripts.playTrack).isEmpty)
    }

    // MARK: Albums and artists

    func testAlbumPlaysInDiscAndTrackOrderThroughTheQueuePlaylist() async throws {
        scripts.on(MusicScripts.search, returns: Rec.records([
            Fx.track("B", "Second", "Beatles", "Abbey Road", disc: 1, number: 2), Fx.track("A", "First", "Beatles", "Abbey Road", disc: 1, number: 1),
            Fx.track("C", "Disc Two", "Beatles", "Abbey Road", disc: 2, number: 1),
        ]))
        scripts.on(MusicScripts.playQueue, returns: Fx.state(pid: "A", name: "First", artist: "Beatles", album: "Abbey Road"))

        let outcome = try await registry().run(.musicPlay, ["query": "Abbey Road", "kind": "album", "artist": "Beatles"])
        let queueCall = try XCTUnwrap(scripts.calls(to: MusicScripts.playQueue).first)
        XCTAssertEqual(Array(queueCall.arguments.dropFirst(4)), ["A", "B", "C"], "ordered by disc, then track number")
        XCTAssertEqual(queueCall.arguments[0], "Jarvis Queue")
        XCTAssertEqual(outcome.output?.data?["queued_tracks"], 3)
        XCTAssertTrue(outcome.output?.verification.isVerified == true)
    }

    func testQueuePlaylistCanBeSwitchedOff() async throws {
        scripts.on(MusicScripts.search, returns: Rec.records([Fx.track("A", "First", "Beatles", "Abbey Road", number: 1), Fx.track("B", "Second", "Beatles", "Abbey Road", number: 2)]))
        scripts.on(MusicScripts.playTrack, returns: Fx.state(pid: "A", name: "First", artist: "Beatles", album: "Abbey Road"))
        var settings = JarvisSettings()
        settings.musicUsesQueuePlaylist = false
        let outcome = try await registry().run(.musicPlay, ["query": "Abbey Road", "kind": "album"], context: executionContext(settings: settings))
        XCTAssertTrue(scripts.calls(to: MusicScripts.playQueue).isEmpty)
        XCTAssertFalse(try XCTUnwrap(outcome.output).warnings.isEmpty)
    }

    // MARK: Playlists

    func testPlayPlaylistByName() async throws {
        scripts.on(MusicScripts.listPlaylists, returns: Rec.records([Fx.playlistRow("P1", "Study"), Fx.playlistRow("P2", "Chill"), Fx.playlistRow("F1", "Folder", kind: "folder")]))
        scripts.on(MusicScripts.playPlaylist, returns: Fx.state(pid: "S1", name: "Lo-fi beats", artist: "Various"))
        let outcome = try await registry().run(.musicPlayPlaylist, ["name": "study"])
        XCTAssertEqual(outcome.output?.message, "Playing your playlist “Study” — now “Lo-fi beats”.")
        XCTAssertEqual(scripts.calls(to: MusicScripts.playPlaylist).first?.arguments, ["P1", "false"])
    }

    func testUnknownPlaylistListsWhatExists() async throws {
        scripts.on(MusicScripts.listPlaylists, returns: Rec.records([Fx.playlistRow("P1", "Study"), Fx.playlistRow("P2", "Chill")]))
        do {
            _ = try await registry().run(.musicPlayPlaylist, ["name": "Workout"])
            XCTFail("should have thrown")
        } catch JarvisError.notFound(let code, let text) {
            XCTAssertEqual(code, "playlist_not_found")
            XCTAssertTrue(text.en.contains("Study"))
        }
        XCTAssertTrue(scripts.calls(to: MusicScripts.playPlaylist).isEmpty)
    }

    func testDuplicatePlaylistNamesAskWhichOne() async throws {
        scripts.on(MusicScripts.listPlaylists, returns: Rec.records([Fx.playlistRow("P1", "Chill", count: 12), Fx.playlistRow("P2", "Chill", count: 40)]))
        let outcome = try await registry().run(.musicPlayPlaylist, ["name": "Chill"])
        let clarification = try XCTUnwrap(outcome.clarification)
        XCTAssertEqual(clarification.options.map { $0.call.arguments["playlist_id"] }, ["P1", "P2"])
    }

    func testEmptyPlaylistIsReported() async throws {
        scripts.on(MusicScripts.listPlaylists, returns: Fx.playlistRow("P1", "Empty", count: 0))
        scripts.on(MusicScripts.playPlaylist, failsWith: AppleScriptFailure(kind: .custom, code: 9006, message: "EMPTY|playlist"))
        do {
            _ = try await registry().run(.musicPlayPlaylist, ["name": "Empty"])
            XCTFail("should have thrown")
        } catch JarvisError.failed(let code, _) {
            XCTAssertEqual(code, "playlist_empty")
        }
    }

    func testFolderPlaylistsAreNotPlayable() async throws {
        scripts.on(MusicScripts.listPlaylists, returns: Fx.playlistRow("F1", "Workouts", kind: "folder"))
        do {
            _ = try await registry().run(.musicPlayPlaylist, ["name": "Workouts"])
            XCTFail("should have thrown")
        } catch JarvisError.notFound {
            // expected
        }
    }

    // MARK: Transport

    private func transport(before: String, after: String) -> String { Rec.records([before, after]) }

    func testPauseIsVerified() async throws {
        scripts.on(MusicScripts.transport, returns: transport(before: Fx.state("playing"), after: Fx.state("paused")))
        let outcome = try await registry().run(.musicPause, [:])
        XCTAssertEqual(outcome.output?.message, "Paused “Bohemian Rhapsody”.")
        XCTAssertEqual(scripts.calls(to: MusicScripts.transport).first?.arguments, ["pause"])
    }

    func testPauseThatDidNotHappenIsAnError() async throws {
        scripts.on(MusicScripts.transport, returns: transport(before: Fx.state("playing"), after: Fx.state("playing")))
        do {
            _ = try await registry().run(.musicPause, [:])
            XCTFail("should have thrown")
        } catch JarvisError.verificationFailed {}
    }

    func testPausingWhenMusicIsNotRunningDoesNotLaunchIt() async throws {
        let outcome = try await registry(access: FakeAutomation(running: false)).run(.musicPause, [:])
        XCTAssertTrue(try XCTUnwrap(outcome.output).message.contains("isn't running"))
        XCTAssertTrue(scripts.calls.isEmpty, "no script may run (it would launch Music)")
    }

    func testSkippingWhenMusicIsNotRunningFails() async throws {
        do {
            _ = try await registry(access: FakeAutomation(running: false)).run(.musicNext, [:])
            XCTFail("should have thrown")
        } catch JarvisError.failed(let code, _) {
            XCTAssertEqual(code, "music_not_running")
        }
    }

    func testNextTrackMustChangeTheTrack() async throws {
        scripts.on(MusicScripts.transport, returns: transport(before: Fx.state(pid: "T1", name: "One"), after: Fx.state(pid: "T2", name: "Two", artist: "Band")))
        let outcome = try await registry().run(.musicNext, [:])
        XCTAssertEqual(outcome.output?.message, "Skipped to “Two” — Band.")

        scripts.on(MusicScripts.transport, returns: transport(before: Fx.state(pid: "T1"), after: Fx.state(pid: "T1")))
        do {
            _ = try await registry().run(.musicNext, [:])
            XCTFail("should have thrown")
        } catch JarvisError.verificationFailed {}
    }

    func testResumeWithNothingQueuedExplainsWhat() async throws {
        scripts.on(MusicScripts.transport, returns: transport(before: Fx.state("stopped", pid: ""), after: Fx.state("stopped", pid: "")))
        do {
            _ = try await registry().run(.musicResume, [:])
            XCTFail("should have thrown")
        } catch JarvisError.failed(let code, let text) {
            XCTAssertEqual(code, "music_not_playing")
            XCTAssertTrue(text.en.contains("nothing seems to be queued"))
        }
    }

    // MARK: Volume and now playing

    func testSetVolumeLevelAndDelta() async throws {
        scripts.on(MusicScripts.state, returns: Fx.state(volume: 50))
        scripts.on(MusicScripts.volume) { arguments, _ in
            let mode = arguments[0]
            let value = Int(arguments[1]) ?? 0
            return Fx.state(volume: mode == "level" ? value : 50 + value)
        }
        let level = try await registry().run(.musicSetVolume, ["level": 30])
        XCTAssertEqual(level.output?.message, "Volume set to 30%.")
        let up = try await registry().run(.musicSetVolume, ["delta": 10])
        XCTAssertEqual(up.output?.message, "Volume raised to 60%.")
        let down = try await registry().run(.musicSetVolume, ["delta": -20])
        XCTAssertEqual(down.output?.message, "Volume lowered to 30%.")
    }

    func testVolumeMismatchIsDetected() async throws {
        scripts.on(MusicScripts.state, returns: Fx.state(volume: 50))
        scripts.on(MusicScripts.volume, returns: Fx.state(volume: 50))
        do {
            _ = try await registry().run(.musicSetVolume, ["level": 80])
            XCTFail("should have thrown")
        } catch JarvisError.verificationFailed {}
    }

    func testVolumeRequiresExactlyOneArgument() async throws {
        do {
            _ = try await registry().run(.musicSetVolume, [:])
            XCTFail("should have thrown")
        } catch JarvisError.validation {}
        do {
            _ = try await registry().run(.musicSetVolume, ["level": 10, "delta": 5])
            XCTFail("should have thrown")
        } catch JarvisError.validation {}
        do {
            _ = try await registry().run(.musicSetVolume, ["level": 140])
            XCTFail("should have thrown")
        } catch JarvisError.validation {}
    }

    func testNowPlayingDescribesTheTrack() async throws {
        scripts.on(MusicScripts.state, returns: Fx.state(position: 83))
        let outcome = try await registry().run(.musicNowPlaying, [:])
        let message = try XCTUnwrap(outcome.output).message
        XCTAssertTrue(message.contains("Playing “Bohemian Rhapsody” by Queen"))
        XCTAssertTrue(message.contains("1:23 / 5:55"))
        XCTAssertTrue(message.contains("volume 50%"))
    }

    func testNowPlayingWithNothingLoaded() async throws {
        scripts.on(MusicScripts.state, returns: Fx.state("stopped", pid: "", name: "", artist: "", album: ""))
        let outcome = try await registry().run(.musicNowPlaying, [:])
        XCTAssertEqual(outcome.output?.message, "Nothing is playing.")
    }

    func testSearchAndListPlaylists() async throws {
        scripts.on(MusicScripts.search, returns: Rec.records([Fx.track("1", "Karma Police", "Radiohead", "OK Computer"), Fx.track("2", "Creep", "Radiohead", "Pablo Honey")]))
        let found = try await registry().run(.musicSearch, ["query": "Radiohead", "limit": 1])
        XCTAssertEqual(found.output?.data?["count"], 2)
        XCTAssertEqual(found.output?.data?["results"]?.arrayValue?.count, 1)

        scripts.on(MusicScripts.listPlaylists, returns: Rec.records([Fx.playlistRow("P1", "Study", count: 12)]))
        let lists = try await registry().run(.musicListPlaylists, [:])
        XCTAssertTrue(try XCTUnwrap(lists.output).message.contains("Study — 12 songs"))
    }

    // MARK: Permissions and failures

    func testAuthorizationMapping() async throws {
        let music = MusicIntegration(scripts: scripts, access: FakeAutomation(state: .denied))
        let play = try XCTUnwrap(music.tools.first { $0.name == .musicPlay })
        let denied = await music.authorization(for: play)
        guard case .denied(let requirement) = denied else { return XCTFail("expected denied, got \(denied)") }
        XCTAssertEqual(requirement.settingsURL, AutomationPermission.settingsURL)

        let undetermined = MusicIntegration(scripts: scripts, access: FakeAutomation(state: .notDetermined))
        let state = await undetermined.authorization(for: play)
        guard case .notDetermined = state else { return XCTFail("expected notDetermined, got \(state)") }

        let missing = MusicIntegration(scripts: scripts, access: FakeAutomation(state: .unavailable, installed: false))
        let unavailable = await missing.authorization(for: play)
        guard case .unavailable = unavailable else { return XCTFail("expected unavailable, got \(unavailable)") }
    }

    func testNotRunningMusicDoesNotNeedPermissionToBeAskedForPause() async throws {
        let music = MusicIntegration(scripts: scripts, access: FakeAutomation(state: .targetNotRunning, running: false))
        let pause = try XCTUnwrap(music.tools.first { $0.name == .musicPause })
        let play = try XCTUnwrap(music.tools.first { $0.name == .musicPlay })
        let pauseState = await music.authorization(for: pause)
        let playState = await music.authorization(for: play)
        XCTAssertTrue(pauseState.isAuthorized)
        guard case .notDetermined = playState else { return XCTFail("playing may launch Music and ask") }
    }

    func testRequestingAuthorizationReturnsTheNewState() async throws {
        let music = MusicIntegration(scripts: scripts, access: FakeAutomation(state: .notDetermined, afterRequest: .granted))
        let play = try XCTUnwrap(music.tools.first { $0.name == .musicPlay })
        let granted = await music.requestAuthorization(for: play)
        XCTAssertTrue(granted.isAuthorized)
    }

    func testAutomationDeniedByMacOSBecomesPermissionRequired() async throws {
        scripts.on(MusicScripts.listPlaylists, failsWith: AppleScriptFailure(kind: .notAuthorized, code: -1743, message: "Not authorized"))
        do {
            _ = try await registry().run(.musicListPlaylists, [:])
            XCTFail("should have thrown")
        } catch JarvisError.permissionRequired(let requirement) {
            XCTAssertEqual(requirement.id, "automation.com.apple.Music")
        }
    }

    func testTimeoutsExplainThatAnAppMayBeWaitingOnADialog() async throws {
        scripts.on(MusicScripts.listPlaylists, failsWith: AppleScriptFailure(kind: .timeout, code: -1712, message: "timed out"))
        do {
            _ = try await registry().run(.musicListPlaylists, [:])
            XCTFail("should have thrown")
        } catch JarvisError.failed(let code, let text) {
            XCTAssertEqual(code, "app_timeout")
            XCTAssertTrue(text.en.contains("dialog"))
        }
    }

    func testEveryToolHasAnExampleThatValidates() throws {
        let registry = registry()
        for descriptor in registry.descriptors {
            for example in descriptor.examples {
                XCTAssertNoThrow(try registry.validate(ToolCall(tool: descriptor.name, arguments: example.arguments)), "\(descriptor.name): \(example.phrase)")
            }
        }
    }
    func testMisspelledSongSearchesRealCandidatesBeforePlayingVerifiedID() async throws {
        scripts.on(MusicScripts.search) { args, _ in
            args[0] == "Bohemian" || args[0] == "bohemian" ? Fx.track("T1", "Bohemian Rhapsody", "Queen", "A Night at the Opera") : ""
        }
        scripts.on(MusicScripts.playTrack, returns: Fx.state())
        let result = try await registry().run(.musicPlay, ["query": "Bohemian Rapsody"])
        XCTAssertEqual(result.output?.data?["track"]?["id"], "T1")
        XCTAssertTrue(scripts.calls(to: MusicScripts.search).count > 1)
    }
    func testSameAlbumTitleByDifferentArtistsRequiresChoice() async throws {
        scripts.on(MusicScripts.search, returns: Rec.records([Fx.track("T1", "Song One", "Queen", "Greatest Hits"), Fx.track("T2", "Song Two", "ABBA", "Greatest Hits")]))
        let result = try await registry().run(.musicPlay, ["query": "Greatest Hits", "kind": "album"])
        XCTAssertEqual(result.clarification?.options.count, 2)
        XCTAssertTrue(scripts.calls(to: MusicScripts.playQueue).isEmpty)
    }
    func testShuffleAndRepeatAreVerifiedByReadBack() async throws {
        scripts.on(MusicScripts.setPlaybackMode) { args, _ in
            let shuffle = args[0] == "music.set_shuffle" ? args[1] : "false"
            let repeatMode = args[0] == "music.set_repeat" ? args[2] : "off"
            return Rec.fields("playing", "50", shuffle, repeatMode, "5", "T1", "Song", "Queen", "Album", "355", "purchased", "file track")
        }
        let shuffle = try await registry().run("music.set_shuffle", ["enabled": true])
        XCTAssertEqual(shuffle.output?.data?["shuffle"], true)
        let repeating = try await registry().run("music.set_repeat", ["mode": "one"])
        XCTAssertEqual(repeating.output?.data?["repeat"], "one")
    }

}
