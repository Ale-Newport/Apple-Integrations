import XCTest
import JarvisCore
@testable import JarvisIntegrations

private enum NFx {
    static func folder(_ account: String, _ accountName: String, _ id: String, _ name: String, count: Int = 3, defaultFolder: Bool = false, defaultAccount: Bool = false) -> String {
        Rec.fields(account, accountName, id, name, String(count), defaultFolder ? "true" : "false", defaultAccount ? "true" : "false")
    }

    static func note(_ account: String, _ accountName: String, _ folderID: String, _ folderName: String, _ id: String, _ title: String, modified: String = "2026-10-10T09:30:00", locked: Bool = false) -> String {
        Rec.fields(account, accountName, folderID, folderName, id, title, modified, locked ? "true" : "false")
    }

    static func raw(id: String, title: String, text: String, html: String, locked: Bool = false, attachments: Int = 0) -> String {
        Rec.records([Rec.fields(id, title, locked ? "true" : "false", "false", String(attachments), text), html])
    }

    /// iCloud (default) and Gmail both own a folder called "Notes", like the real accounts that motivated this test.
    static let folders = Rec.records([
        folder("acc-icloud", "iCloud", "f-icloud-notes", "Notes", count: 12, defaultFolder: true, defaultAccount: true),
        folder("acc-icloud", "iCloud", "f-icloud-trash", "Recently Deleted", count: 2),
        folder("acc-icloud", "iCloud", "f-icloud-work", "Work", count: 4),
        folder("acc-gmail", "Gmail", "f-gmail-notes", "Notes", count: 0, defaultFolder: true),
    ])
}

final class NotesIntegrationTests: XCTestCase {
    private let scripts = FakeScripts()

    private func registry(access: FakeAutomation = FakeAutomation()) -> ToolRegistry {
        ToolRegistry(integrations: [NotesIntegration(scripts: scripts, access: access)])
    }

    private func installFolders() { scripts.on(NotesScripts.folders, returns: NFx.folders) }

    // MARK: Create

    func testCreateNoteInTheDefaultAccountVerifiesWhatWasStored() async throws {
        installFolders()
        scripts.on(NotesScripts.create, returns: Rec.fields("note-1", "Project Ideas", "2026-10-17T13:00:00"))
        scripts.on(NotesScripts.raw, returns: NFx.raw(id: "note-1", title: "Project Ideas", text: "Project Ideas\nBuild a robot\nAdd lasers", html: "<div><h1>Project Ideas</h1></div>"))

        let outcome = try await registry().run(.notesCreate, ["title": "Project Ideas", "content": "Build a robot\nAdd lasers"])
        let output = try XCTUnwrap(outcome.output)
        XCTAssertEqual(output.message, "Created the note “Project Ideas” in iCloud › Notes.")
        XCTAssertTrue(output.verification.isVerified)

        let call = try XCTUnwrap(scripts.calls(to: NotesScripts.create).first)
        XCTAssertEqual(call.arguments[0], "acc-icloud")
        XCTAssertEqual(call.arguments[1], "f-icloud-notes")
        XCTAssertEqual(call.arguments[2], "<div><h1>Project Ideas</h1></div><div>Build a robot</div><div>Add lasers</div>")
    }

    func testNoteTextIsEscapedSoItCanNeverBecomeMarkup() async throws {
        installFolders()
        scripts.on(NotesScripts.create, returns: Rec.fields("n", "x", "2026-10-17T13:00:00"))
        scripts.on(NotesScripts.raw, returns: NFx.raw(id: "n", title: "x", text: "x <script>alert(1)</script> & more", html: ""))
        _ = try await registry().run(.notesCreate, ["title": "x", "content": "<script>alert(1)</script> & more"])
        let html = try XCTUnwrap(scripts.calls(to: NotesScripts.create).first?.arguments[2])
        XCTAssertTrue(html.contains("&lt;script&gt;alert(1)&lt;/script&gt; &amp; more"))
        XCTAssertFalse(html.contains("<script>"))
    }

    func testMismatchBetweenRequestedAndStoredTextIsReported() async throws {
        installFolders()
        scripts.on(NotesScripts.create, returns: Rec.fields("n", "Wrong", "2026-10-17T13:00:00"))
        scripts.on(NotesScripts.raw, returns: NFx.raw(id: "n", title: "Wrong", text: "Totally different", html: ""))
        do {
            _ = try await registry().run(.notesCreate, ["title": "Plan", "content": "Step one"])
            XCTFail("should have thrown")
        } catch JarvisError.verificationFailed {}
    }

    func testFolderNameThatExistsInSeveralAccountsAsksWhere() async throws {
        installFolders()
        let outcome = try await registry().run(.notesCreate, ["title": "Idea", "folder": "Notes"])
        let clarification = try XCTUnwrap(outcome.clarification)
        XCTAssertEqual(clarification.options.map(\.label), ["iCloud › Notes", "Gmail › Notes"])
        XCTAssertEqual(clarification.options[1].call.arguments["folder_id"], "f-gmail-notes")
        XCTAssertEqual(clarification.options[1].call.arguments["account_id"], "acc-gmail")
        XCTAssertTrue(scripts.calls(to: NotesScripts.create).isEmpty, "nothing is created until the user picks")
    }

    func testChoosingAnOptionCreatesTheNoteInThatFolder() async throws {
        installFolders()
        scripts.on(NotesScripts.create, returns: Rec.fields("n", "Idea", "2026-10-17T13:00:00"))
        scripts.on(NotesScripts.raw, returns: NFx.raw(id: "n", title: "Idea", text: "Idea", html: ""))
        let first = try await registry().run(.notesCreate, ["title": "Idea", "folder": "Notes"])
        let option = try XCTUnwrap(first.clarification?.options[1])
        let done = try await registry().run(.notesCreate, option.call.arguments)
        XCTAssertEqual(done.output?.data?["account"], "Gmail")
        XCTAssertEqual(scripts.calls(to: NotesScripts.create).first?.arguments.prefix(2).map { $0 }, ["acc-gmail", "f-gmail-notes"])
    }

    func testAccountNarrowsTheFolderChoice() async throws {
        installFolders()
        scripts.on(NotesScripts.create, returns: Rec.fields("n", "Idea", "2026-10-17T13:00:00"))
        scripts.on(NotesScripts.raw, returns: NFx.raw(id: "n", title: "Idea", text: "Idea", html: ""))
        let outcome = try await registry().run(.notesCreate, ["title": "Idea", "folder": "Notes", "account": "gmail"])
        XCTAssertNotNil(outcome.output)
        XCTAssertEqual(scripts.calls(to: NotesScripts.create).first?.arguments[1], "f-gmail-notes")
    }

    func testUnknownFolderListsTheAvailableOnes() async throws {
        installFolders()
        do {
            _ = try await registry().run(.notesCreate, ["title": "x", "folder": "Recipes"])
            XCTFail("should have thrown")
        } catch JarvisError.notFound(let code, let text) {
            XCTAssertEqual(code, "folder_not_found")
            XCTAssertTrue(text.en.contains("Work"))
            XCTAssertFalse(text.en.contains("Recently Deleted"), "the trash is not a destination")
        }
    }

    func testDefaultFolderSettingIsHonoured() async throws {
        installFolders()
        scripts.on(NotesScripts.create, returns: Rec.fields("n", "Idea", "2026-10-17T13:00:00"))
        scripts.on(NotesScripts.raw, returns: NFx.raw(id: "n", title: "Idea", text: "Idea", html: ""))
        var settings = JarvisSettings()
        settings.defaultNotesAccount = "iCloud"
        settings.defaultNotesFolder = "Work"
        _ = try await registry().run(.notesCreate, ["title": "Idea"], context: executionContext(settings: settings))
        XCTAssertEqual(scripts.calls(to: NotesScripts.create).first?.arguments[1], "f-icloud-work")
    }

    func testCreatingNeedsAtLeastATitleOrContent() async throws {
        do {
            _ = try await registry().run(.notesCreate, [:])
            XCTFail("should have thrown")
        } catch JarvisError.validation {}
    }

    // MARK: Search, list, folders

    private func installNotes() {
        scripts.on(NotesScripts.notes, returns: Rec.records([
            NFx.note("acc-icloud", "iCloud", "f-icloud-notes", "Notes", "n1", "Budget 2026", modified: "2026-10-12T10:00:00"),
            NFx.note("acc-icloud", "iCloud", "f-icloud-notes", "Notes", "n2", "Shopping list", modified: "2026-10-14T10:00:00"),
            NFx.note("acc-icloud", "iCloud", "f-icloud-work", "Work", "n3", "Project Ideas", modified: "2026-10-16T10:00:00"),
            NFx.note("acc-gmail", "Gmail", "f-gmail-notes", "Notes", "n4", "Project Ideas", modified: "2026-10-01T10:00:00"),
            NFx.note("acc-icloud", "iCloud", "f-icloud-trash", "Recently Deleted", "n5", "Old budget", modified: "2026-09-01T10:00:00"),
            NFx.note("acc-icloud", "iCloud", "f-icloud-notes", "Notes", "n6", "Secret", modified: "2026-10-02T10:00:00", locked: true),
        ]))
    }

    func testSearchByTitleIgnoresCaseAccentsAndTheTrash() async throws {
        installFolders(); installNotes()
        scripts.on(NotesScripts.bodySearch, returns: "")
        let outcome = try await registry().run(.notesSearch, ["query": "BUDGET", "scope": "title"])
        let ids = outcome.output?.data?["results"]?.arrayValue?.compactMap { $0["id"]?.stringValue }
        XCTAssertEqual(ids, ["n1"], "the trashed 'Old budget' is excluded")
        XCTAssertTrue(scripts.calls(to: NotesScripts.bodySearch).isEmpty, "title scope never scans note bodies")
    }

    func testSearchAlsoFindsTextInsideNotesAndSortsNewestFirst() async throws {
        installFolders(); installNotes()
        scripts.on(NotesScripts.bodySearch, returns: NFx.note("acc-icloud", "iCloud", "f-icloud-notes", "Notes", "n2", "Shopping list", modified: "2026-10-14T10:00:00"))
        let outcome = try await registry().run(.notesSearch, ["query": "milk"])
        XCTAssertEqual(outcome.output?.data?["results"]?.arrayValue?.compactMap { $0["id"]?.stringValue }, ["n2"])
        XCTAssertEqual(scripts.calls(to: NotesScripts.bodySearch).first?.arguments, ["milk"])
    }

    func testBodySearchFailureDegradesToTitlesWithAWarning() async throws {
        installFolders(); installNotes()
        scripts.on(NotesScripts.bodySearch, failsWith: AppleScriptFailure(kind: .timeout, code: -1712, message: "timed out"))
        let outcome = try await registry().run(.notesSearch, ["query": "budget"])
        let output = try XCTUnwrap(outcome.output)
        XCTAssertEqual(output.data?["count"], 1)
        XCTAssertFalse(output.warnings.isEmpty)
    }

    func testListShowsNewestFirstAndFlagsLockedNotes() async throws {
        installFolders(); installNotes()
        let outcome = try await registry().run(.notesList, [:])
        let message = try XCTUnwrap(outcome.output).message
        XCTAssertTrue(message.contains("Project Ideas — iCloud › Work"))
        XCTAssertTrue(message.contains("🔒"))
        XCTAssertFalse(message.contains("Old budget"))
        let firstLine = message.split(separator: "\n").dropFirst().first.map(String.init) ?? ""
        XCTAssertTrue(firstLine.contains("Project Ideas"), "most recently modified first")
    }

    func testListFoldersGroupsByAccountAndHidesTheTrash() async throws {
        installFolders()
        let outcome = try await registry().run(.notesListFolders, [:])
        let message = try XCTUnwrap(outcome.output).message
        XCTAssertTrue(message.contains("iCloud: Notes (12), Work (4)"))
        XCTAssertTrue(message.contains("Gmail: Notes (0)"))
        XCTAssertFalse(message.contains("Recently Deleted"))
    }

    // MARK: Read

    func testReadByTitleFindsTheNewestExactMatchOrAsks() async throws {
        installFolders(); installNotes()
        // "Project Ideas" exists in two accounts → ambiguous.
        let ask = try await registry().run(.notesRead, ["title": "Project Ideas"])
        let clarification = try XCTUnwrap(ask.clarification)
        XCTAssertEqual(clarification.options.map(\.detail), ["iCloud › Work", "Gmail › Notes"])
        XCTAssertEqual(clarification.options[0].call.arguments["id"], "n3")

        scripts.on(NotesScripts.read, returns: Rec.fields("n3", "Project Ideas", "2026-01-01T09:00:00", "2026-10-16T10:00:00", "false", "false", "0", "21", "Project Ideas\nBuild a robot"))
        let read = try await registry().run(.notesRead, clarification.options[0].call.arguments)
        let output = try XCTUnwrap(read.output)
        XCTAssertTrue(output.message.contains("Build a robot"))
        XCTAssertEqual(output.data?["truncated"], false)
    }

    func testReadingATruncatedNoteSaysSo() async throws {
        installFolders(); installNotes()
        scripts.on(NotesScripts.read, returns: Rec.fields("n1", "Budget 2026", "2026-01-01T09:00:00", "2026-10-12T10:00:00", "false", "false", "0", "5000", "First 10 chars"))
        let outcome = try await registry().run(.notesRead, ["title": "Budget 2026", "max_chars": 100])
        XCTAssertEqual(outcome.output?.data?["truncated"], true)
        XCTAssertTrue(try XCTUnwrap(outcome.output).message.contains("first 14 of 5000"))
        XCTAssertEqual(scripts.calls(to: NotesScripts.read).first?.arguments, ["n1", "100"])
    }

    func testLockedNotesCannotBeRead() async throws {
        installFolders(); installNotes()
        scripts.on(NotesScripts.read, returns: Rec.fields("n6", "Secret", "2026-01-01T09:00:00", "2026-10-02T10:00:00", "true", "false", "0", "0", ""))
        do {
            _ = try await registry().run(.notesRead, ["title": "Secret"])
            XCTFail("should have thrown")
        } catch JarvisError.failed(let code, _) {
            XCTAssertEqual(code, "note_locked")
        }
    }

    func testMissingNoteSuggestsSimilarOnes() async throws {
        installFolders(); installNotes()
        do {
            _ = try await registry().run(.notesRead, ["title": "Budget plans"])
            XCTFail("a note that does not exist must not be read")
        } catch let JarvisError.notFound(code, text) {
            XCTAssertEqual(code, "note_not_found")
            XCTAssertTrue(text.en.contains("Budget 2026"), "similar notes are suggested: \(text.en)")
            XCTAssertTrue(text.es.contains("Budget 2026"), "and in Spanish: \(text.es)")
        }
        // Any other error type propagates out of this throwing test and fails it.
    }

    // MARK: Append

    func testAppendPreservesTheExistingHTMLAndVerifies() async throws {
        installFolders(); installNotes()
        let originalHTML = "<div><h1>Project Ideas</h1></div><div>Build a robot</div>"
        scripts.on(NotesScripts.raw) { _, index in
            index == 0
                ? NFx.raw(id: "n3", title: "Project Ideas", text: "Project Ideas\nBuild a robot", html: originalHTML)
                : NFx.raw(id: "n3", title: "Project Ideas", text: "Project Ideas\nBuild a robot\nMore text here", html: originalHTML + "<div>More text here</div>")
        }
        scripts.on(NotesScripts.setBody, returns: "n3")

        let outcome = try await registry().run(.notesAppend, ["id": "n3", "text": "More text here"])
        XCTAssertTrue(try XCTUnwrap(outcome.output).verification.isVerified)
        let setCall = try XCTUnwrap(scripts.calls(to: NotesScripts.setBody).first)
        XCTAssertEqual(setCall.arguments, ["n3", originalHTML + "<div>More text here</div>"], "existing markup is kept byte for byte")
    }

    func testAppendIsRolledBackWhenTheNoteDoesNotLookRight() async throws {
        installFolders(); installNotes()
        let originalHTML = "<div><h1>Project Ideas</h1></div><div>Build a robot</div>"
        scripts.on(NotesScripts.raw) { _, index in
            index == 0
                ? NFx.raw(id: "n3", title: "Project Ideas", text: "Project Ideas\nBuild a robot", html: originalHTML)
                : NFx.raw(id: "n3", title: "Project Ideas", text: "", html: "")   // Notes lost the content!
        }
        scripts.on(NotesScripts.setBody, returns: "n3")
        do {
            _ = try await registry().run(.notesAppend, ["id": "n3", "text": "More"])
            XCTFail("should have thrown")
        } catch JarvisError.verificationFailed {}
        let writes = scripts.calls(to: NotesScripts.setBody)
        XCTAssertEqual(writes.count, 2, "the edit and then the rollback")
        XCTAssertEqual(writes.last?.arguments, ["n3", originalHTML])
    }

    func testNotesWithAttachmentsAreNeverRewritten() async throws {
        installFolders(); installNotes()
        scripts.on(NotesScripts.raw, returns: NFx.raw(id: "n3", title: "Photos", text: "Photos", html: "<div>Photos</div>", attachments: 2))
        do {
            _ = try await registry().run(.notesAppend, ["id": "n3", "text": "More"])
            XCTFail("should have thrown")
        } catch JarvisError.unsupported(let text, _) {
            XCTAssertTrue(text.en.contains("attachment"))
        }
        XCTAssertTrue(scripts.calls(to: NotesScripts.setBody).isEmpty)
    }

    func testLockedNotesAreNeverEdited() async throws {
        installFolders(); installNotes()
        scripts.on(NotesScripts.raw, returns: NFx.raw(id: "n6", title: "Secret", text: "", html: "", locked: true))
        do {
            _ = try await registry().run(.notesAppend, ["id": "n6", "text": "More"])
            XCTFail("should have thrown")
        } catch JarvisError.failed(let code, _) {
            XCTAssertEqual(code, "note_locked")
        }
        XCTAssertTrue(scripts.calls(to: NotesScripts.setBody).isEmpty)
    }

    // MARK: Update

    func testReplacingContentKeepsTheTitleLine() async throws {
        installFolders(); installNotes()
        scripts.on(NotesScripts.raw) { _, index in
            index == 0
                ? NFx.raw(id: "n2", title: "Shopping list", text: "Shopping list\nold", html: "<div><h1>Shopping list</h1></div><div>old</div>")
                : NFx.raw(id: "n2", title: "Shopping list", text: "Shopping list\nmilk, eggs", html: "")
        }
        scripts.on(NotesScripts.setBody, returns: "n2")
        let outcome = try await registry().run(.notesUpdate, ["id": "n2", "new_content": "milk, eggs"])
        XCTAssertNotNil(outcome.output)
        XCTAssertEqual(scripts.calls(to: NotesScripts.setBody).first?.arguments, ["n2", "<div><h1>Shopping list</h1></div><div>milk, eggs</div>"])
    }

    func testRenameUsesTheRenameScript() async throws {
        installFolders(); installNotes()
        scripts.on(NotesScripts.raw) { _, index in
            index == 0
                ? NFx.raw(id: "n2", title: "Shopping list", text: "Shopping list\nold", html: "<div>x</div>")
                : NFx.raw(id: "n2", title: "Groceries", text: "Groceries\nold", html: "")
        }
        scripts.on(NotesScripts.rename, returns: "n2")
        let outcome = try await registry().run(.notesUpdate, ["id": "n2", "new_title": "Groceries"])
        XCTAssertNotNil(outcome.output)
        XCTAssertEqual(scripts.calls(to: NotesScripts.rename).first?.arguments, ["n2", "Groceries"])
        XCTAssertTrue(scripts.calls(to: NotesScripts.setBody).isEmpty)
    }

    // MARK: Delete

    func testDeleteAsksFirstAndOnlyThenMovesTheNoteToRecentlyDeleted() async throws {
        installFolders(); installNotes()
        scripts.on(NotesScripts.delete, returns: "true")

        let first = try await registry().run(.notesDelete, ["title": "Shopping list"])
        let confirmation = try XCTUnwrap(first.confirmation)
        XCTAssertTrue(confirmation.destructive)
        XCTAssertTrue(confirmation.prompt.contains("Shopping list"))
        XCTAssertEqual(confirmation.call.arguments["id"], "n2")
        XCTAssertTrue(scripts.calls(to: NotesScripts.delete).isEmpty, "nothing is deleted before the user confirms")

        let confirmed = try await registry().run(.notesDelete, confirmation.call.arguments, context: executionContext(confirmed: true))
        XCTAssertTrue(try XCTUnwrap(confirmed.output).verification.isVerified)
        XCTAssertEqual(scripts.calls(to: NotesScripts.delete).first?.arguments, ["n2", "f-icloud-notes"])
    }

    func testDeleteThatLeavesTheNoteBehindIsAnError() async throws {
        installFolders(); installNotes()
        scripts.on(NotesScripts.delete, returns: "false")
        do {
            _ = try await registry().run(.notesDelete, ["id": "n2"], context: executionContext(confirmed: true))
            XCTFail("should have thrown")
        } catch JarvisError.verificationFailed {}
    }

    // MARK: Permissions

    func testPermissionStates() async throws {
        let denied = NotesIntegration(scripts: scripts, access: FakeAutomation(state: .denied))
        let tool = try XCTUnwrap(denied.tools.first)
        guard case .denied = await denied.authorization(for: tool) else { return XCTFail("expected denied") }
        let status = await denied.status()
        XCTAssertEqual(status.state, .denied)

        let ready = NotesIntegration(scripts: scripts, access: FakeAutomation(state: .granted))
        let readyStatus = await ready.status()
        XCTAssertEqual(readyStatus.state, .ready)
    }

    func testEveryToolHasAnExampleThatValidates() throws {
        let registry = registry()
        for descriptor in registry.descriptors {
            for example in descriptor.examples {
                XCTAssertNoThrow(try registry.validate(ToolCall(tool: descriptor.name, arguments: example.arguments)), "\(descriptor.name): \(example.phrase)")
            }
        }
    }
}
