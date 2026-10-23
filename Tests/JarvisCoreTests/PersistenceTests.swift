import XCTest
@testable import JarvisCore

final class SettingsTests: XCTestCase {
    func testDecodingOldOrPartialSettingsFillsInDefaults() throws {
        let partial = try JSONDecoder().decode(JarvisSettings.self, from: Data(#"{"defaultCalendar":"Work","conflictPolicy":"warn"}"#.utf8))
        XCTAssertEqual(partial.defaultCalendar, "Work")
        XCTAssertEqual(partial.conflictPolicy, .warn)
        XCTAssertEqual(partial.defaultEventDurationMinutes, 60)
        XCTAssertEqual(partial.musicQueuePlaylistName, "Jarvis Queue")
        XCTAssertEqual(partial.shortcutNames.createAlarm, "Jarvis Create Alarm")
        XCTAssertTrue(partial.saveHistory)
        let empty = try JSONDecoder().decode(JarvisSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, JarvisSettings())
    }

    func testSanitizingClampsHostileValues() {
        var settings = JarvisSettings()
        settings.defaultEventDurationMinutes = 100_000
        settings.morningHour = -5
        settings.nightHour = 99
        settings.duplicateWindowSeconds = 1e9
        settings.musicQueuePlaylistName = "   "
        let clean = settings.sanitized()
        XCTAssertEqual(clean.defaultEventDurationMinutes, 24 * 60)
        XCTAssertEqual(clean.morningHour, 0)
        XCTAssertEqual(clean.nightHour, 23)
        XCTAssertEqual(clean.duplicateWindowSeconds, 120)
        XCTAssertEqual(clean.musicQueuePlaylistName, "Jarvis Queue")
        settings.defaultEventDurationMinutes = 0
        XCTAssertEqual(settings.sanitized().defaultEventDurationMinutes, 5)
    }

    func testUserDefaultsStorePersistsAndIsolatesSuites() throws {
        let suite = "jarvis-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsSettingsStore(defaults: defaults)
        XCTAssertEqual(store.snapshot(), JarvisSettings())

        var changed = JarvisSettings()
        changed.defaultReminderList = "Shopping"
        changed.languagePreference = .spanish
        changed.shortcutNames.startTimer = "Mi temporizador"
        store.save(changed)
        XCTAssertEqual(store.snapshot().defaultReminderList, "Shopping")

        let reloaded = UserDefaultsSettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.snapshot().languagePreference, .spanish)
        XCTAssertEqual(reloaded.snapshot().shortcutNames.startTimer, "Mi temporizador")
    }

    func testCorruptStoredSettingsFallBackToDefaults() throws {
        let suite = "jarvis-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("not json".utf8), forKey: "jarvis.settings.v1")
        XCTAssertEqual(UserDefaultsSettingsStore(defaults: defaults).snapshot(), JarvisSettings())
    }

    func testInMemorySettingsAreThreadSafeAndSanitized() {
        let settings = InMemorySettings()
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            settings.update { $0.defaultEventDurationMinutes = index % 2 == 0 ? 30 : 90 }
            _ = settings.snapshot()
        }
        XCTAssertTrue([30, 90].contains(settings.snapshot().defaultEventDurationMinutes))
    }

    func testLanguagePreference() {
        XCTAssertNil(LanguagePreference.automatic.fixedLanguage)
        XCTAssertEqual(LanguagePreference.spanish.fixedLanguage, .es)
        XCTAssertEqual(LanguagePreference.english.fixedLanguage, .en)
    }
}

final class HistoryStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-history-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private var fileURL: URL { directory.appendingPathComponent("history.json") }

    private func entry(_ text: String, status: EngineResponse.Status = .completed, id: UUID = UUID()) -> HistoryEntry {
        HistoryEntry(id: id, date: Date(), text: text, language: .en, status: status, summary: "done", tools: ["music.pause"], source: "app")
    }

    func testRecordsNewestFirstAndPersistsAcrossInstances() async {
        let store = HistoryStore(fileURL: fileURL)
        await store.record(entry("first"))
        await store.record(entry("second"))
        let all = await store.all()
        XCTAssertEqual(all.map(\.text), ["second", "first"])

        let reopened = HistoryStore(fileURL: fileURL)
        let again = await reopened.all()
        XCTAssertEqual(again.map(\.text), ["second", "first"])
    }

    func testUpdatesDeletesAndClears() async {
        let store = HistoryStore(fileURL: fileURL)
        let id = UUID()
        await store.record(entry("delete my note", status: .needsConfirmation, id: id))
        await store.update(id: id, status: .completed, summary: "Moved to Recently Deleted")
        var all = await store.all()
        XCTAssertEqual(all.first?.status, .completed)
        XCTAssertEqual(all.first?.summary, "Moved to Recently Deleted")

        await store.record(entry("other"))
        await store.delete(ids: [id])
        all = await store.all()
        XCTAssertEqual(all.map(\.text), ["other"])
        await store.clear()
        let cleared = await store.all()
        XCTAssertTrue(cleared.isEmpty)
        let onDisk = HistoryStore(fileURL: fileURL)
        let reloaded = await onDisk.all()
        XCTAssertTrue(reloaded.isEmpty)
    }

    func testIsCappedAndTruncatesLongText() async {
        let store = HistoryStore(fileURL: fileURL, limit: 5)
        for index in 0..<12 { await store.record(entry("command \(index)")) }
        let all = await store.all()
        XCTAssertEqual(all.count, 5)
        XCTAssertEqual(all.first?.text, "command 11")

        await store.record(entry(String(repeating: "x", count: 5_000)))
        let long = await store.all()
        XCTAssertEqual(long.first?.text.count, HistoryStore.maxTextLength, "private note content is not kept in full")
    }

    func testTheHistoryFileIsPrivate() async throws {
        let store = HistoryStore(fileURL: fileURL)
        await store.record(entry("secret"))
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let folder = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual((folder[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testACorruptFileIsSetAsideAndTheStoreStillWorks() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{ definitely not json".utf8).write(to: fileURL)
        let store = HistoryStore(fileURL: fileURL)
        let initial = await store.all()
        XCTAssertTrue(initial.isEmpty)
        await store.record(entry("fresh start"))
        let after = await store.all()
        XCTAssertEqual(after.map(\.text), ["fresh start"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("history.corrupt.json").path), "kept for inspection")
    }

    func testDefaultLocationsAreUnderApplicationSupport() {
        XCTAssertTrue(JarvisPaths.historyFile().path.contains("Application Support/JarvisAppleIntegrations"))
        XCTAssertTrue(JarvisPaths.socketFile().path.hasSuffix(".sock"))
        XCTAssertLessThanOrEqual(JarvisPaths.socketFile().path.utf8.count, 103)
    }
}

final class SecretStoreTests: XCTestCase {
    func testInMemoryStoreRoundTrip() throws {
        let store = InMemorySecretStore()
        XCTAssertNil(try store.secret(for: "laya"))
        try store.set("sk-123", for: "laya")
        XCTAssertEqual(try store.secret(for: "laya"), "sk-123")
        try store.removeSecret(for: "laya")
        XCTAssertNil(try store.secret(for: "laya"))
    }

    func testKeychainRoundTrip() throws {
        let store = KeychainSecretStore(service: "com.newportdiaz.JarvisAppleIntegrations.tests.\(UUID().uuidString)")
        let account = "test-provider"
        do {
            try store.set("first", for: account)
        } catch SecretStoreError.keychain(let status) {
            throw XCTSkip("The keychain is not available in this environment (status \(status))")
        }
        defer { try? store.removeSecret(for: account) }
        XCTAssertEqual(try store.secret(for: account), "first")
        try store.set("second", for: account)
        XCTAssertEqual(try store.secret(for: account), "second", "updates replace, they do not duplicate")
        try store.removeSecret(for: account)
        XCTAssertNil(try store.secret(for: account))
        XCTAssertNoThrow(try store.removeSecret(for: account), "removing a missing secret is not an error")
    }
}
