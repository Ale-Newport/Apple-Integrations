import Foundation
import JarvisCore

struct NotesFolder: Sendable, Hashable {
    var accountID: String
    var accountName: String
    var id: String
    var name: String
    var noteCount: Int
    var isDefaultFolder: Bool
    var isDefaultAccount: Bool

    init?(fields f: [String]) {
        guard f.count >= 7, !f[2].isEmpty else { return nil }
        accountID = f[0]; accountName = f[1]; id = f[2]; name = f[3]
        noteCount = Int(f[4]) ?? 0
        isDefaultFolder = f[5] == "true"
        isDefaultAccount = f[6] == "true"
    }

    /// "Recently Deleted" in every language Notes ships in. Notes there is on its way to being erased.
    static let trashNames: Set<String> = [
        "recently deleted", "eliminadas recientemente", "eliminados recientemente", "borrados recientemente",
        "supprimés récemment", "supprimees recemment", "zuletzt gelöscht", "zuletzt geloscht", "eliminati di recente",
        "excluídos recentemente", "excluidos recentemente", "onlangs verwijderd", "nyligen raderade", "senest slettet",
        "недавно удалённые", "最近删除", "最近削除した項目", "최근 삭제된 항목", "recently deleted notes", "papelera", "trash",
    ]

    var isTrash: Bool { Self.trashNames.contains(name.lowercased()) || Self.trashNames.contains(TextFolding.fold(name)) }

    var json: JSONValue {
        .object(["id": .string(id), "name": .string(name), "account": .string(accountName), "account_id": .string(accountID), "note_count": .int(noteCount)])
    }
}

struct NoteRef: Sendable, Hashable {
    var accountID: String
    var accountName: String
    var folderID: String
    var folderName: String
    var id: String
    var title: String
    var modified: Date?
    var isLocked: Bool

    init?(fields f: [String], timeZone: TimeZone) {
        guard f.count >= 8, !f[4].isEmpty else { return nil }
        accountID = f[0]; accountName = f[1]; folderID = f[2]; folderName = f[3]
        id = f[4]; title = f[5]
        modified = ISODates.date(from: f[6], timeZone: timeZone)
        isLocked = f[7] == "true"
    }

    func json(timeZone: TimeZone) -> JSONValue {
        var object: JSONObject = [
            "id": .string(id), "title": .string(title), "folder": .string(folderName), "folder_id": .string(folderID),
            "account": .string(accountName), "locked": .bool(isLocked),
        ]
        if let modified { object["modified"] = .string(ISODates.string(from: modified, timeZone: timeZone)) }
        return .object(object)
    }
}

struct NoteContent: Sendable {
    var id: String
    var title: String
    var created: Date?
    var modified: Date?
    var isLocked: Bool
    var isShared: Bool
    var attachmentCount: Int
    var fullLength: Int
    var text: String

    init?(fields f: [String], timeZone: TimeZone) {
        guard f.count >= 9 else { return nil }
        id = f[0]; title = f[1]
        created = ISODates.date(from: f[2], timeZone: timeZone)
        modified = ISODates.date(from: f[3], timeZone: timeZone)
        isLocked = f[4] == "true"; isShared = f[5] == "true"
        attachmentCount = Int(f[6]) ?? 0
        fullLength = Int(f[7]) ?? 0
        // The text itself may (rarely) contain the field separator; rejoin whatever follows the 8th field.
        text = f[8...].joined(separator: String(ScriptRecords.fieldSeparator))
    }
}

struct RawNote: Sendable {
    var id: String
    var title: String
    var isLocked: Bool
    var isShared: Bool
    var attachmentCount: Int
    var plainText: String
    var html: String

    init?(output: String) {
        let records = output.split(separator: ScriptRecords.recordSeparator, maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let head = records.first else { return nil }
        let f = ScriptRecords.fields(head)
        guard f.count >= 6 else { return nil }
        id = f[0]; title = f[1]; isLocked = f[2] == "true"; isShared = f[3] == "true"
        attachmentCount = Int(f[4]) ?? 0
        plainText = f[5...].joined(separator: String(ScriptRecords.fieldSeparator))
        html = records.count > 1 ? records[1] : ""
    }
}
