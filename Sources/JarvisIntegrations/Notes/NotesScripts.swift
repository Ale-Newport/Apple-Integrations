import Foundation

/// AppleScript programs for the Notes integration. Same rules as `MusicScripts`: constants only, data via `argv`,
/// results as unit/record-separated text, script-defined errors as `error "TAG|detail" number 90xx`.
///
/// Notes quirks these scripts account for (observed on macOS 27): password-protected notes report an empty
/// body; `container of note` is not reliably readable (so folders are tracked while iterating); several accounts
/// can each own a folder called "Notes"; "Recently Deleted" is a normal folder; dates must be converted with
/// `«class isot»` because locale-dependent text (and decimal commas) cannot be parsed reliably.
enum NotesScripts {
    private static func make(_ name: String, _ body: String) -> AppleScriptSource {
        AppleScriptSource(name: "notes.\(name)", text: ScriptPrelude.handlers + "\n" + isoHandler + "\n" + body)
    }

    private static let isoHandler = #"""
        on isoDate(d)
        return (d as «class isot») as string
        end isoDate
        """#

    /// Records: account id, account name, folder id, folder name, note count, is default folder, is default account.
    static let folders = make(
        "folders",
        #"""
        on run argv
        set rows to {}
        tell application "Notes"
        set defaultAccountId to ""
        try
        set defaultAccountId to id of default account
        end try
        repeat with acct in every account
        set acctId to id of acct
        set acctName to my oneLine(name of acct)
        set defaultFolderId to ""
        try
        set defaultFolderId to id of default folder of acct
        end try
        repeat with f in every folder of acct
        set noteCount to "0"
        try
        set noteCount to (count of notes of f) as text
        end try
        set isDefaultFolder to "false"
        if (id of f) is defaultFolderId then set isDefaultFolder to "true"
        set isDefaultAccount to "false"
        if acctId is defaultAccountId then set isDefaultAccount to "true"
        set end of rows to my joinFields({acctId, acctName, id of f, my oneLine(name of f), noteCount, isDefaultFolder, isDefaultAccount})
        end repeat
        end repeat
        end tell
        return my joinRecords(rows)
        end run
        """#)

    /// argv: folder id filter ("" for every folder). Records: account id, account name, folder id, folder name,
    /// note id, title, modified (ISO local), locked.
    static let notes = make(
        "notes",
        #"""
        on run argv
        set filterId to item 1 of argv
        set rows to {}
        tell application "Notes"
        repeat with acct in every account
        set acctId to id of acct
        set acctName to my oneLine(name of acct)
        repeat with f in every folder of acct
        set fid to id of f
        if filterId is "" or fid is filterId then
        set fname to my oneLine(name of f)
        set noteIds to id of every note of f
        if (count of noteIds) > 0 then
        set noteNames to name of every note of f
        set noteMods to modification date of every note of f
        set noteLocks to password protected of every note of f
        repeat with i from 1 to count of noteIds
        set end of rows to my joinFields({acctId, acctName, fid, fname, item i of noteIds, my oneLine(item i of noteNames), my isoDate(item i of noteMods), (item i of noteLocks) as text})
        end repeat
        end if
        end if
        end repeat
        end repeat
        end tell
        return my joinRecords(rows)
        end run
        """#)

    /// argv: search text. Same record shape as `notes`, but only notes whose body contains the text.
    static let bodySearch = make(
        "body_search",
        #"""
        on run argv
        set q to item 1 of argv
        set rows to {}
        tell application "Notes"
        repeat with acct in every account
        set acctId to id of acct
        set acctName to my oneLine(name of acct)
        repeat with f in every folder of acct
        set fid to id of f
        set fname to my oneLine(name of f)
        set hits to (every note of f whose plaintext contains q)
        repeat with n in hits
        set end of rows to my joinFields({acctId, acctName, fid, fname, id of n, my oneLine(name of n), my isoDate(modification date of n), (password protected of n) as text})
        end repeat
        end repeat
        end repeat
        end tell
        return my joinRecords(rows)
        end run
        """#)

    /// argv: note id, max characters. Returns one record: id, title, created, modified, locked, shared,
    /// attachment count, full length, then the (possibly truncated) plain text.
    static let read = make(
        "read",
        #"""
        on run argv
        set noteId to item 1 of argv
        set maxChars to (item 2 of argv) as integer
        tell application "Notes"
        try
        set n to note id noteId
        set nm to name of n
        on error
        error "NOT_FOUND|note" number 9001
        end try
        set isLocked to (password protected of n) as text
        set isShared to "false"
        try
        set isShared to (shared of n) as text
        end try
        set attachmentCount to "0"
        try
        set attachmentCount to (count of attachments of n) as text
        end try
        set createdOn to my isoDate(creation date of n)
        set modifiedOn to my isoDate(modification date of n)
        set pt to ""
        if isLocked is "false" then set pt to plaintext of n
        end tell
        set fullLength to count of characters of pt
        if fullLength > maxChars then set pt to text 1 thru maxChars of pt
        return my joinFields({noteId, my oneLine(nm), createdOn, modifiedOn, isLocked, isShared, attachmentCount, fullLength as text, pt})
        end run
        """#)

    /// argv: note id. Two records: [id, title, locked, shared, attachment count, plain text] and [HTML body].
    static let raw = make(
        "raw",
        #"""
        on run argv
        set noteId to item 1 of argv
        tell application "Notes"
        try
        set n to note id noteId
        set nm to name of n
        on error
        error "NOT_FOUND|note" number 9001
        end try
        set isLocked to (password protected of n) as text
        set isShared to "false"
        try
        set isShared to (shared of n) as text
        end try
        set attachmentCount to "0"
        try
        set attachmentCount to (count of attachments of n) as text
        end try
        set pt to ""
        set htmlBody to ""
        if isLocked is "false" then
        set pt to plaintext of n
        set htmlBody to body of n
        end if
        end tell
        return my joinRecords({my joinFields({noteId, my oneLine(nm), isLocked, isShared, attachmentCount, pt}), htmlBody})
        end run
        """#)

    /// argv: account id ("" = default account), folder id ("" = account's default folder), HTML body.
    /// Returns: note id, title, created (ISO).
    static let create = make(
        "create",
        #"""
        on run argv
        set acctId to item 1 of argv
        set folderId to item 2 of argv
        set htmlBody to item 3 of argv
        tell application "Notes"
        try
        if folderId is not "" then
        set targetFolder to folder id folderId
        else if acctId is not "" then
        set targetFolder to default folder of (account id acctId)
        else
        set targetFolder to default folder of default account
        end if
        on error
        error "NOT_FOUND|folder" number 9001
        end try
        set n to make new note at targetFolder with properties {body:htmlBody}
        set nid to id of n
        set nm to name of n
        set createdOn to creation date of n
        end tell
        return my joinFields({nid, my oneLine(nm), my isoDate(createdOn)})
        end run
        """#)

    /// argv: note id, HTML body. Replaces the body (used by append/update; the Swift side verifies and rolls back).
    static let setBody = make(
        "set_body",
        #"""
        on run argv
        set noteId to item 1 of argv
        set htmlBody to item 2 of argv
        tell application "Notes"
        try
        set n to note id noteId
        on error
        error "NOT_FOUND|note" number 9001
        end try
        if (password protected of n) then error "LOCKED|note" number 9004
        if count of argv >= 3 then
        if body of n is not item 3 of argv then error "CHANGED|note" number 9003
        end if
        set body of n to htmlBody
        end tell
        return noteId
        end run
        """#)

    /// argv: note id, new title. Renames the note (Notes derives the title from the first line).
    static let rename = make(
        "rename",
        #"""
        on run argv
        set noteId to item 1 of argv
        set newTitle to item 2 of argv
        tell application "Notes"
        try
        set n to note id noteId
        on error
        error "NOT_FOUND|note" number 9001
        end try
        if (password protected of n) then error "LOCKED|note" number 9004
        set name of n to newTitle
        end tell
        return noteId
        end run
        """#)

    /// argv: note id, folder id. Deletes the note (Notes moves it to "Recently Deleted") and reports whether it left the folder.
    static let delete = make(
        "delete",
        #"""
        on run argv
        set noteId to item 1 of argv
        set folderId to item 2 of argv
        tell application "Notes"
        try
        set n to note id noteId
        on error
        error "NOT_FOUND|note" number 9001
        end try
        delete n
        set remaining to {}
        try
        set remaining to id of every note of (folder id folderId)
        end try
        end tell
        if remaining contains noteId then return "false"
        return "true"
        end run
        """#)

    static let createFolder = make(
        "create_folder",
        #"""
        on run argv
        tell application "Notes"
        set a to account id (item 1 of argv)
        set found to folders of a whose name is (item 2 of argv)
        if count of found > 0 then error "EXISTS|folder" number 9003
        set f to make new folder at a with properties {name:(item 2 of argv)}
        return id of f
        end tell
        end run
        """#)
    static let move = make(
        "move",
        #"""
        on run argv
        tell application "Notes"
        set n to note id (item 1 of argv)
        set f to folder id (item 2 of argv)
        move n to f
        return item 1 of argv
        end tell
        end run
        """#)
    static let all: [AppleScriptSource] = [
        folders, notes, bodySearch, read, raw, create, setBody, rename, delete, createFolder, move,
    ]
}
