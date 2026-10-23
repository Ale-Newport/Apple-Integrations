import Foundation

/// One remembered command. Only a truncated copy of the user's text is stored, in a file readable by
/// the current user alone; saving can be switched off in Settings.
public struct HistoryEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var date: Date
    public var text: String
    public var language: Language
    public var status: EngineResponse.Status
    public var summary: String
    public var tools: [String]
    public var source: String

    public init(id: UUID, date: Date, text: String, language: Language, status: EngineResponse.Status, summary: String, tools: [String], source: String) {
        self.id = id
        self.date = date
        self.text = text
        self.language = language
        self.status = status
        self.summary = summary
        self.tools = tools
        self.source = source
    }
}

public protocol HistoryRecording: Sendable {
    func record(_ entry: HistoryEntry) async
    /// Updates an earlier entry once a pending confirmation/clarification is resolved.
    func update(id: UUID, status: EngineResponse.Status, summary: String) async
}

/// Well-known on-disk locations.
public enum JarvisPaths {
    public static let folderName = "JarvisAppleIntegrations"

    public static func applicationSupportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(folderName, isDirectory: true)
    }

    public static func historyFile() -> URL {
        applicationSupportDirectory().appendingPathComponent("history.json")
    }

    /// The Unix domain socket other local apps connect to. Falls back to a short path in `/tmp` when the
    /// default would exceed the 104-byte `sockaddr_un` limit (very long user names).
    public static func socketFile() -> URL {
        let preferred = applicationSupportDirectory().appendingPathComponent("jarvis.sock")
        if preferred.path.utf8.count <= 100 { return preferred }
        return URL(fileURLWithPath: "/tmp/jarvis-apple-\(getuid()).sock")
    }

    /// Creates `directory` with owner-only permissions.
    @discardableResult
    public static func ensurePrivateDirectory(_ directory: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            return true
        } catch {
            return false
        }
    }
}

/// Command history persisted as a small JSON file (newest first, capped).
public actor HistoryStore: HistoryRecording {
    private let fileURL: URL
    private let limit: Int
    private var entries: [HistoryEntry] = []
    private var loaded = false

    public static let maxTextLength = 500
    public static let maxSummaryLength = 300

    public init(fileURL: URL = JarvisPaths.historyFile(), limit: Int = 500) {
        self.fileURL = fileURL
        self.limit = limit
    }

    public func all() -> [HistoryEntry] {
        loadIfNeeded()
        return entries
    }

    public func record(_ entry: HistoryEntry) {
        loadIfNeeded()
        var clean = entry
        clean.text = String(entry.text.prefix(Self.maxTextLength))
        clean.summary = String(entry.summary.prefix(Self.maxSummaryLength))
        entries.removeAll { $0.id == entry.id }
        entries.insert(clean, at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        save()
    }

    public func update(id: UUID, status: EngineResponse.Status, summary: String) {
        loadIfNeeded()
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].status = status
        entries[index].summary = String(summary.prefix(Self.maxSummaryLength))
        save()
    }

    public func delete(ids: Set<UUID>) {
        loadIfNeeded()
        entries.removeAll { ids.contains($0.id) }
        save()
    }

    public func clear() {
        entries = []
        loaded = true
        save()
    }

    // MARK: Persistence

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([HistoryEntry].self, from: data) {
            entries = decoded
        } else {
            // A corrupt file must never block the app: keep a copy for inspection and start fresh.
            let backup = fileURL.deletingPathExtension().appendingPathExtension("corrupt.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            JarvisLog.persistence.error("History file could not be decoded; starting with an empty history")
        }
    }

    private func save() {
        JarvisPaths.ensurePrivateDirectory(fileURL.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(entries)
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            JarvisLog.persistence.error("Could not save history: \(error.localizedDescription, privacy: .public)")
        }
    }
}
