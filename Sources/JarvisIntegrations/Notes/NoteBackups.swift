import Foundation
import JarvisCore

/// Owner-only bounded snapshots, containing original Notes HTML for undo. Injectable in-memory storage for tests.
actor NoteBackups {
    struct Entry: Codable, Sendable {
        let id: String
        let noteID: String
        let title: String
        let html: String
        let plainText: String?
        let date: Date
    }
    private let url: URL?
    private var entries: [Entry]?
    init(url: URL? = nil) { self.url = url }
    private func load() throws -> [Entry] {
        if let entries { return entries }
        let value: [Entry]
        if let url, FileManager.default.fileExists(atPath: url.path) {
            value = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: url))
        } else {
            value = []
        }
        entries = value
        return value
    }
    private func save(_ values: [Entry]) throws {
        if let url {
            guard JarvisPaths.ensurePrivateDirectory(url.deletingLastPathComponent()) else {
                throw CocoaError(.fileWriteNoPermission)
            }
            try JSONEncoder().encode(values).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        entries = values
    }
    func capture(_ note: RawNote, now: Date) throws -> String {
        guard note.html.utf8.count <= 1_000_000 else { throw CocoaError(.fileReadTooLarge) }
        var values = try load().filter { now.timeIntervalSince($0.date) < 30 * 86400 }
        let value = Entry(
            id: UUID().uuidString, noteID: note.id, title: note.title, html: note.html, plainText: note.plainText,
            date: now)
        values.insert(value, at: 0)
        try save(Array(values.prefix(30)))
        return value.id
    }
    func all(now: Date = Date()) throws -> [Entry] {
        let values = try load()
        let kept = values.filter { now.timeIntervalSince($0.date) < 30 * 86400 }
        if values.count != kept.count { try save(kept) }
        return kept
    }
    func clear() throws { try save([]) }
}
