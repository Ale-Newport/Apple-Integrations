import Foundation
import JarvisCore

/// Apple Notes through its public AppleScript interface (never the private Notes database).
///
/// Safety rules implemented here:
/// * Existing content is preserved: appends re-read the note afterwards and are **rolled back** if the text is
///   not what was expected; notes with attachments or a password are refused rather than risk losing data.
/// * Deleting always asks first, and the note goes to “Recently Deleted” (recoverable).
/// * Accounts and folders are never guessed: if “Notes” exists in four accounts, the user chooses.
public struct NotesIntegration: AppIntegration {
    public let id = IntegrationID.notes
    public let displayName = LocalizedText(en: "Notes", es: "Notas")
    public let summary = LocalizedText(
        en: "Create, search, read, append to and delete notes in any of your accounts.",
        es: "Crea, busca, lee, añade texto y elimina notas en cualquiera de tus cuentas."
    )
    public let symbolName = "note.text"

    static let bundleIdentifier = "com.apple.Notes"

    private let scripts: any AppleScriptExecuting
    private let access: any AutomationAccess

    public init(scripts: any AppleScriptExecuting = OSAScriptRunner()) {
        self.init(scripts: scripts, access: SystemAutomationAccess(bundleIdentifier: Self.bundleIdentifier))
    }

    init(scripts: any AppleScriptExecuting, access: any AutomationAccess) {
        self.scripts = scripts
        self.access = access
    }

    // MARK: Discovery

    static let requirement = PermissionRequirement.automation(
        appName: "Notes", bundleIdentifier: bundleIdentifier,
        reason: LocalizedText(
            en: "Jarvis uses Notes' scripting interface to create, search and edit notes. macOS asks once.",
            es: "Jarvis usa la interfaz de scripts de Notas para crear, buscar y editar notas. macOS lo pregunta una sola vez."
        )
    )

    public let permissionRequirements: [PermissionRequirement] = [Self.requirement]

    public var tools: [ToolDescriptor] {
        let id = self.id
        func tool(_ name: ToolName, _ title: String, _ summary: String, _ parameters: [ToolParameter] = [], _ constraints: [ToolConstraint] = [], safety: ToolSafety = .modifying, timeout: TimeInterval = 60, deduplicate: Bool = false, examples: [ToolExample] = []) -> ToolDescriptor {
            ToolDescriptor(name: name, integration: id, title: title, summary: summary, parameters: parameters, constraints: constraints, safety: safety, timeout: timeout, deduplicate: deduplicate, examples: examples)
        }
        let selector: [ToolParameter] = [
            .string("id", "Exact note id (from notes.search / notes.list).", maxLength: 200),
            .string("title", "Title (or part of it) of the note.", maxLength: 300),
            .string("folder", "Restrict to this folder name.", maxLength: 200),
            .string("account", "Restrict to this account name (iCloud, Gmail…).", maxLength: 200),
        ]
        return [
            tool(.notesCreate, "Create a note", "Creates a note, optionally in a specific folder/account. The title becomes the first line.", [
                .string("title", "Title of the note.", maxLength: 300),
                .string("content", "Body text; line breaks become paragraphs.", maxLength: 100_000),
                .string("folder", "Destination folder name.", maxLength: 200),
                .string("account", "Destination account name.", maxLength: 200),
                .string("folder_id", "Exact folder id (skips name matching).", maxLength: 200),
                .string("account_id", "Exact account id.", maxLength: 200),
            ], [.atLeastOne(["title", "content"])], deduplicate: true, examples: [
                ToolExample("Create a note called Project Ideas with the following content: Build a robot", arguments: ["title": "Project Ideas", "content": "Build a robot"]),
            ]),
            tool(.notesList, "List notes", "Lists the most recently modified notes.", [
                .string("folder", "Only this folder.", maxLength: 200),
                .string("account", "Only this account.", maxLength: 200),
                .integer("limit", "Maximum notes.", min: 1, max: 200, default: 25),
            ], safety: .readOnly),
            tool(.notesListFolders, "List folders", "Lists the folders of every Notes account.", safety: .readOnly),
            tool(.notesSearch, "Search notes", "Searches note titles and (optionally) their text.", [
                .string("query", "Text to look for.", required: true, maxLength: 300),
                .choice("scope", ["title", "any"], "title = titles only (fast); any = titles and body text.", default: "any"),
                .string("folder", "Only this folder.", maxLength: 200),
                .string("account", "Only this account.", maxLength: 200),
                .integer("limit", "Maximum results.", min: 1, max: 100, default: 20),
            ], safety: .readOnly, timeout: 90, examples: [ToolExample("Search my notes for budget", arguments: ["query": "budget"])]),
            tool(.notesRead, "Read a note", "Returns the text of one note.", selector + [
                .integer("max_chars", "Maximum characters to return.", min: 100, max: 100_000, default: 6_000),
            ], [.atLeastOne(["id", "title"])], safety: .readOnly, examples: [ToolExample("Read my Project Ideas note", arguments: ["title": "Project Ideas"])]),
            tool(.notesAppend, "Append text to a note", "Adds text at the end of an existing note, preserving what is there.", selector + [
                .string("text", "Text to add.", required: true, maxLength: 100_000),
            ], [.atLeastOne(["id", "title"])], deduplicate: true, examples: [
                ToolExample("Append this paragraph to my Project Ideas note: more text", arguments: ["title": "Project Ideas", "text": "more text"]),
            ]),
            tool(.notesUpdate, "Update a note", "Replaces a note's text and/or renames it. The title line is kept unless a new title is given.", selector + [
                .string("new_content", "Replacement body text.", maxLength: 100_000),
                .string("new_title", "New title.", maxLength: 300),
            ], [.atLeastOne(["id", "title"]), .atLeastOne(["new_content", "new_title"])]),
            tool(.notesDelete, "Delete a note", "Moves a note to Recently Deleted after confirmation.", selector, [.atLeastOne(["id", "title"])], safety: .destructive),
        ]
    }

    // MARK: Authorization

    public func status() async -> IntegrationStatus {
        let entry: (AuthorizationState) -> IntegrationStatus.PermissionEntry = { .init(requirement: Self.requirement, state: $0) }
        switch access.status() {
        case .unavailable:
            let reason = LocalizedText(en: "The Notes app is not available on this Mac.", es: "La app Notas no está disponible en este Mac.")
            return IntegrationStatus(state: .unavailable, detail: reason, permissions: [entry(.unavailable(reason))])
        case .granted:
            return IntegrationStatus(state: .ready, permissions: [entry(.authorized)])
        case .denied:
            return IntegrationStatus(state: .denied, detail: Self.requirement.rationale, permissions: [entry(.denied(Self.requirement))])
        case .notDetermined, .targetNotRunning:
            return IntegrationStatus(state: .needsPermission, detail: Self.requirement.rationale, permissions: [entry(.notDetermined(Self.requirement))])
        }
    }

    public func authorization(for tool: ToolDescriptor) async -> AuthorizationState {
        switch access.status() {
        case .unavailable: return .unavailable(LocalizedText(en: "The Notes app is not installed.", es: "La app Notas no está instalada."))
        case .granted: return .authorized
        case .denied: return .denied(Self.requirement)
        case .notDetermined, .targetNotRunning: return .notDetermined(Self.requirement)
        }
    }

    public func requestAuthorization(for tool: ToolDescriptor) async -> AuthorizationState {
        switch await access.request() {
        case .granted: return .authorized
        case .unavailable: return .unavailable(LocalizedText(en: "The Notes app is not installed.", es: "La app Notas no está instalada."))
        case .notDetermined, .targetNotRunning: return .notDetermined(Self.requirement)
        case .denied: return .denied(Self.requirement)
        }
    }

    // MARK: Execution

    public func execute(_ call: ValidatedToolCall, context: ExecutionContext) async throws -> ToolOutcome {
        switch call.descriptor.name {
        case .notesCreate: return try await create(call, context)
        case .notesList: return try await list(call, context)
        case .notesListFolders: return try await listFolders(context)
        case .notesSearch: return try await search(call, context)
        case .notesRead: return try await read(call, context)
        case .notesAppend: return try await append(call, context)
        case .notesUpdate: return try await update(call, context)
        case .notesDelete: return try await delete(call, context)
        default:
            throw JarvisError.failed("unknown_tool", en: "Notes does not provide \(call.descriptor.name).", es: "Notas no ofrece \(call.descriptor.name).")
        }
    }

    private func run(_ script: AppleScriptSource, _ arguments: [String] = [], timeout: TimeInterval = 40) async throws -> String {
        do {
            return try await scripts.run(script, arguments: arguments, timeout: timeout)
        } catch let failure as AppleScriptFailure {
            throw Self.map(failure)
        }
    }

    private static func map(_ failure: AppleScriptFailure) -> JarvisError {
        switch (failure.kind, failure.code) {
        case (.custom, 9001):
            return .notFound(code: "note_not_found", LocalizedText(en: "That note (or folder) no longer exists.", es: "Esa nota (o carpeta) ya no existe."))
        case (.custom, 9004):
            return .failed(code: "note_locked", LocalizedText(
                en: "That note is password-protected, so Jarvis cannot change it.",
                es: "Esa nota está protegida con contraseña, así que Jarvis no puede modificarla."
            ))
        default:
            return failure.jarvisError(app: "Notes", requirement: requirement)
        }
    }

    // MARK: Lookups

    private func loadFolders() async throws -> [NotesFolder] {
        let output = try await run(NotesScripts.folders)
        var seen = Set<String>()
        return ScriptRecords.parse(output).compactMap(NotesFolder.init(fields:)).filter { seen.insert($0.id).inserted }
    }

    private func loadNotes(folderID: String = "", timeZone: TimeZone) async throws -> [NoteRef] {
        let output = try await run(NotesScripts.notes, [folderID], timeout: 60)
        return ScriptRecords.parse(output).compactMap { NoteRef(fields: $0, timeZone: timeZone) }
    }

    private func raw(_ id: String) async throws -> RawNote {
        let output = try await run(NotesScripts.raw, [id])
        guard let note = RawNote(output: output) else {
            throw JarvisError.failed("unexpected_output", en: "Notes returned something Jarvis could not read.", es: "Notas devolvió algo que Jarvis no pudo interpretar.")
        }
        return note
    }

    /// Folders matching the user's words, honouring an optional account filter. Trash folders never match.
    private func matchFolders(_ all: [NotesFolder], folder: String?, account: String?) -> [NotesFolder] {
        var candidates = all.filter { !$0.isTrash }
        if let account {
            candidates = NameMatcher.bestMatches(candidates, query: account, minimumScore: 80) { $0.accountName }
        }
        if let folder {
            candidates = candidates.filter { NameMatcher.score(query: folder, candidate: $0.name) >= 85 }
        }
        return candidates
    }

    private static func placeName(_ folder: NotesFolder) -> String { "\(folder.accountName) › \(folder.name)" }

    // MARK: notes.create

    private func create(_ call: ValidatedToolCall, _ context: ExecutionContext) async throws -> ToolOutcome {
        let language = context.language
        let title = call.string("title")
        let content = call.string("content")
        let folders = try await loadFolders()

        var accountID = call.string("account_id") ?? ""
        var folderID = call.string("folder_id") ?? ""
        var destination: NotesFolder?

        if folderID.isEmpty {
            let wantedFolder = call.string("folder") ?? (call.string("account") == nil && accountID.isEmpty ? context.settings.defaultNotesFolder : nil)
            let wantedAccount = call.string("account") ?? (accountID.isEmpty ? context.settings.defaultNotesAccount : nil)
            if let wantedFolder {
                let matches = matchFolders(folders, folder: wantedFolder, account: wantedAccount)
                switch matches.count {
                case 0:
                    let listing = Dictionary(grouping: folders.filter { !$0.isTrash }, by: \.accountName)
                        .sorted { $0.key < $1.key }
                        .map { "\($0.key): " + $0.value.map(\.name).joined(separator: ", ") }
                        .joined(separator: "; ")
                    throw JarvisError.notFound(code: "folder_not_found", LocalizedText(
                        en: "There is no folder called “\(wantedFolder)”\(wantedAccount.map { " in \($0)" } ?? ""). Available folders — \(listing).",
                        es: "No hay ninguna carpeta llamada «\(wantedFolder)»\(wantedAccount.map { " en \($0)" } ?? ""). Carpetas disponibles — \(listing)."
                    ))
                case 1:
                    destination = matches[0]
                default:
                    // The same folder name exists in several accounts — never guess.
                    let options = matches.map { candidate in
                        ClarificationOption(
                            label: Self.placeName(candidate),
                            detail: language.pick("\(candidate.noteCount) notes", "\(candidate.noteCount) notas"),
                            call: call.call.adding(["folder_id": .string(candidate.id), "account_id": .string(candidate.accountID)])
                        )
                    }
                    return .clarify(Clarification(
                        question: language.pick("“\(wantedFolder)” exists in several accounts. Where should the note go?", "«\(wantedFolder)» existe en varias cuentas. ¿Dónde debo guardar la nota?"),
                        options: options
                    ))
                }
            } else if let wantedAccount {
                let matches = NameMatcher.bestMatches(folders.filter { !$0.isTrash }, query: wantedAccount, minimumScore: 80) { $0.accountName }
                guard let first = matches.first else {
                    throw JarvisError.notFound("account_not_found", en: "There is no Notes account called “\(wantedAccount)”.", es: "No hay ninguna cuenta de Notas llamada «\(wantedAccount)».")
                }
                accountID = first.accountID
                destination = matches.first(where: \.isDefaultFolder) ?? first
            } else {
                destination = folders.first(where: { $0.isDefaultAccount && $0.isDefaultFolder })
            }
            if let destination { folderID = destination.id; accountID = destination.accountID }
        } else {
            destination = folders.first { $0.id == folderID }
        }

        let html = NoteHTML.newNote(title: title, content: content)
        let output = try await run(NotesScripts.create, [accountID, folderID, html], timeout: 40)
        let fields = ScriptRecords.fields(output)
        guard fields.count >= 3 else {
            throw JarvisError.failed("unexpected_output", en: "Notes returned something Jarvis could not read.", es: "Notas devolvió algo que Jarvis no pudo interpretar.")
        }
        let noteID = fields[0]

        // Verify: read the note back and compare the title and the first line of text.
        let stored = try await raw(noteID)
        let storedText = NoteHTML.normalized(stored.plainText)
        let expectedFirst = NoteHTML.normalized(title ?? content?.split(separator: "\n").first.map(String.init) ?? "")
        var verified = storedText.hasPrefix(expectedFirst)
        if verified, title != nil, let content, let firstContent = content.split(separator: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            verified = storedText.contains(NoteHTML.normalized(String(firstContent)))
        }
        guard verified else {
            throw JarvisError.verificationFailed(LocalizedText(
                en: "The note was created but its text does not match what was requested; please check Notes.",
                es: "La nota se creó, pero su texto no coincide con lo solicitado; revisa la app Notas."
            ))
        }

        let place = destination.map(Self.placeName) ?? language.pick("your default folder", "tu carpeta predeterminada")
        let shownTitle = fields[1].isEmpty ? (title ?? "") : fields[1]
        return .done(ToolOutput(
            message: language.pick("Created the note “\(shownTitle)” in \(place).", "Creé la nota «\(shownTitle)» en \(place)."),
            data: [
                "id": .string(noteID), "title": .string(shownTitle),
                "folder": destination.map { .string($0.name) } ?? .null, "account": destination.map { .string($0.accountName) } ?? .null,
            ],
            verification: .verified(language.pick("Read the note back from Notes; title and text match.", "Se volvió a leer la nota en Notas; título y texto coinciden."))
        ))
    }

    // MARK: notes.list / list_folders

    private func list(_ call: ValidatedToolCall, _ context: ExecutionContext) async throws -> ToolOutcome {
        let language = context.language
        let limit = call.int("limit") ?? 25
        let folders = try await loadFolders()
        let wanted = call.string("folder") != nil || call.string("account") != nil
            ? matchFolders(folders, folder: call.string("folder"), account: call.string("account")) : folders.filter { !$0.isTrash }
        if wanted.isEmpty && (call.string("folder") != nil || call.string("account") != nil) {
            throw JarvisError.notFound("folder_not_found", en: "I couldn't find that folder.", es: "No encontré esa carpeta.")
        }
        let allowed = Set(wanted.map(\.id))
        let notes = try await loadNotes(timeZone: context.timeZone).filter { allowed.contains($0.folderID) }
        let sorted = notes.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        let shown = Array(sorted.prefix(limit))
        guard !shown.isEmpty else {
            return .done(ToolOutput(message: language.pick("No notes found.", "No se encontraron notas."), data: ["notes": [], "count": 0], verification: .notApplicable))
        }
        return .done(ToolOutput(
            message: language.pick("\(notes.count) notes (showing \(shown.count), newest first):\n", "\(notes.count) notas (mostrando \(shown.count), las más recientes primero):\n") + Formatting.bullets(shown.map { describe($0, context) }),
            data: ["notes": .array(shown.map { $0.json(timeZone: context.timeZone) }), "count": .int(notes.count)], verification: .notApplicable
        ))
    }

    private func describe(_ note: NoteRef, _ context: ExecutionContext) -> String {
        let lock = note.isLocked ? context.t(" 🔒 locked", " 🔒 bloqueada") : ""
        let date = note.modified.map { " · " + Formatting.dateTime($0, calendar: context.calendar, language: context.language, includeTime: false) } ?? ""
        return "\(note.title.isEmpty ? context.t("(untitled)", "(sin título)") : note.title) — \(note.accountName) › \(note.folderName)\(date)\(lock)"
    }

    private func listFolders(_ context: ExecutionContext) async throws -> ToolOutcome {
        let language = context.language
        let folders = try await loadFolders()
        let visible = folders.filter { !$0.isTrash }
        let grouped = Dictionary(grouping: visible, by: \.accountName).sorted { $0.key < $1.key }
        let lines = grouped.map { account, items in
            "\(account): " + items.map { "\($0.name) (\($0.noteCount))" }.joined(separator: ", ")
        }
        return .done(ToolOutput(
            message: language.pick("Your Notes folders:\n", "Tus carpetas de Notas:\n") + Formatting.bullets(lines),
            data: ["folders": .array(visible.map(\.json)), "count": .int(visible.count)], verification: .notApplicable
        ))
    }

    // MARK: notes.search

    private func search(_ call: ValidatedToolCall, _ context: ExecutionContext) async throws -> ToolOutcome {
        let language = context.language
        let query = call.string("query") ?? ""
        let scope = call.string("scope") ?? "any"
        let limit = call.int("limit") ?? 20
        let folders = try await loadFolders()
        let allowed = Set(matchFolders(folders, folder: call.string("folder"), account: call.string("account")).map(\.id))

        let everything = try await loadNotes(timeZone: context.timeZone).filter { allowed.contains($0.folderID) }
        var hits = everything.filter { note in
            NameMatcher.score(query: query, candidate: note.title) >= 50 || TextFolding.fold(note.title).contains(TextFolding.fold(query))
        }
        var warnings: [String] = []

        if scope == "any" {
            do {
                let output = try await run(NotesScripts.bodySearch, [query], timeout: 70)
                let bodyHits = ScriptRecords.parse(output).compactMap { NoteRef(fields: $0, timeZone: context.timeZone) }.filter { allowed.contains($0.folderID) }
                var known = Set(hits.map(\.id))
                for hit in bodyHits where known.insert(hit.id).inserted { hits.append(hit) }
            } catch let error as JarvisError {
                if case .permissionRequired = error { throw error }
                warnings.append(language.pick(
                    "Searching inside note text took too long or failed, so only titles were searched.",
                    "La búsqueda dentro del texto de las notas tardó demasiado o falló, así que solo se buscó en los títulos."
                ))
            }
        }

        let sorted = hits.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        let shown = Array(sorted.prefix(limit))
        guard !shown.isEmpty else {
            return .done(ToolOutput(
                message: language.pick("No notes match “\(query)”.", "Ninguna nota coincide con «\(query)»."),
                data: ["results": [], "count": 0], verification: .notApplicable, warnings: warnings
            ))
        }
        return .done(ToolOutput(
            message: language.pick("Found \(hits.count) note\(hits.count == 1 ? "" : "s") for “\(query)”:\n", "Encontré \(hits.count) nota\(hits.count == 1 ? "" : "s") para «\(query)»:\n") + Formatting.bullets(shown.map { describe($0, context) }),
            data: ["results": .array(shown.map { $0.json(timeZone: context.timeZone) }), "count": .int(hits.count)],
            verification: .notApplicable, warnings: warnings
        ))
    }

    // MARK: Resolving a single note

    private enum Resolution {
        case found(NoteRef)
        case outcome(ToolOutcome)
    }

    /// Finds the one note a call refers to, or asks which one when several match.
    private func resolve(_ call: ValidatedToolCall, _ context: ExecutionContext) async throws -> Resolution {
        let language = context.language
        let folders = try await loadFolders()
        let allowed = Set(matchFolders(folders, folder: call.string("folder"), account: call.string("account")).map(\.id))
        let all = try await loadNotes(timeZone: context.timeZone).filter { allowed.contains($0.folderID) }

        if let id = call.string("id") {
            guard let note = all.first(where: { $0.id == id }) else {
                throw JarvisError.notFound("note_not_found", en: "That note no longer exists.", es: "Esa nota ya no existe.")
            }
            return .found(note)
        }
        let title = call.string("title") ?? ""
        let ranked = NameMatcher.rank(all, query: title, minimumScore: 60) { $0.title }
        guard let top = ranked.first else {
            let words = Set(TextFolding.tokens(title).filter { $0.count >= 3 })
            let similar = all.filter { !words.isDisjoint(with: TextFolding.tokens($0.title)) }.prefix(5).map(\.title)
            let hint = similar.isEmpty ? "" : language.pick(" Similar notes: \(similar.joined(separator: ", ")).", " Notas parecidas: \(similar.joined(separator: ", ")).")
            throw JarvisError.notFound(code: "note_not_found", LocalizedText(
                en: "I couldn't find a note called “\(title)”.\(hint)",
                es: "No encontré una nota llamada «\(title)».\(hint)"
            ))
        }
        let best = ranked.filter { $0.score == top.score }.map(\.item)
        if best.count == 1 { return .found(best[0]) }
        let options = best.prefix(6).map { note in
            ClarificationOption(
                label: note.title.isEmpty ? language.pick("(untitled)", "(sin título)") : note.title,
                detail: "\(note.accountName) › \(note.folderName)",
                call: ToolCall(tool: call.descriptor.name, arguments: Self.replacingSelector(call.arguments, with: note.id))
            )
        }
        return .outcome(.clarify(Clarification(
            question: language.pick("I found \(best.count) notes matching “\(title)”. Which one?", "Encontré \(best.count) notas que coinciden con «\(title)». ¿Cuál?"),
            options: Array(options)
        )))
    }

    private static func replacingSelector(_ arguments: JSONObject, with id: String) -> JSONObject {
        var copy = arguments
        for key in ["title", "folder", "account"] { copy[key] = nil }
        copy["id"] = .string(id)
        return copy
    }

    // MARK: notes.read

    private func read(_ call: ValidatedToolCall, _ context: ExecutionContext) async throws -> ToolOutcome {
        let language = context.language
        let note: NoteRef
        switch try await resolve(call, context) {
        case .found(let found): note = found
        case .outcome(let outcome): return outcome
        }
        let maxChars = call.int("max_chars") ?? 6_000
        let output = try await run(NotesScripts.read, [note.id, String(maxChars)])
        guard let content = NoteContent(fields: ScriptRecords.fields(output), timeZone: context.timeZone) else {
            throw JarvisError.failed("unexpected_output", en: "Notes returned something Jarvis could not read.", es: "Notas devolvió algo que Jarvis no pudo interpretar.")
        }
        if content.isLocked {
            throw JarvisError.failed("note_locked", en: "“\(content.title)” is password-protected; Notes does not let other apps read it.", es: "«\(content.title)» está protegida con contraseña; Notas no permite que otras apps la lean.")
        }
        let truncated = content.fullLength > content.text.count
        var message = language.pick("“\(content.title)” (\(note.accountName) › \(note.folderName)):\n\n", "«\(content.title)» (\(note.accountName) › \(note.folderName)):\n\n") + content.text
        if truncated { message += language.pick("\n\n… (showing the first \(content.text.count) of \(content.fullLength) characters)", "\n\n… (mostrando los primeros \(content.text.count) de \(content.fullLength) caracteres)") }
        var data: JSONObject = [
            "id": .string(content.id), "title": .string(content.title), "text": .string(content.text), "truncated": .bool(truncated),
            "length": .int(content.fullLength), "folder": .string(note.folderName), "account": .string(note.accountName),
            "attachments": .int(content.attachmentCount), "shared": .bool(content.isShared),
        ]
        if let modified = content.modified { data["modified"] = .string(ISODates.string(from: modified, timeZone: context.timeZone)) }
        if let created = content.created { data["created"] = .string(ISODates.string(from: created, timeZone: context.timeZone)) }
        return .done(ToolOutput(message: message, data: .object(data), verification: .notApplicable))
    }

    // MARK: notes.append / update

    private func refuseUnsafeEdit(_ note: RawNote, language: Language) throws {
        if note.isLocked {
            throw JarvisError.failed("note_locked", en: "“\(note.title)” is password-protected, so Jarvis cannot change it.", es: "«\(note.title)» está protegida con contraseña, así que Jarvis no puede modificarla.")
        }
        if note.attachmentCount > 0 {
            throw JarvisError.unsupported(
                LocalizedText(
                    en: "“\(note.title)” contains \(note.attachmentCount) attachment(s) (images, scans, files). Notes' scripting interface rewrites the whole note when it is edited, which could lose them, so Jarvis will not edit this note.",
                    es: "«\(note.title)» contiene \(note.attachmentCount) adjunto(s) (imágenes, escaneos, archivos). La interfaz de scripts de Notas reescribe toda la nota al editarla y podría perderlos, así que Jarvis no editará esta nota."
                ),
                alternative: LocalizedText(en: "I can create a new note instead.", es: "Puedo crear una nota nueva en su lugar.")
            )
        }
    }

    private func append(_ call: ValidatedToolCall, _ context: ExecutionContext) async throws -> ToolOutcome {
        let language = context.language
        let note: NoteRef
        switch try await resolve(call, context) {
        case .found(let found): note = found
        case .outcome(let outcome): return outcome
        }
        let text = call.string("text") ?? ""
        let before = try await raw(note.id)
        try refuseUnsafeEdit(before, language: language)

        let newHTML = before.html + NoteHTML.paragraphs(text)
        _ = try await run(NotesScripts.setBody, [note.id, newHTML])

        // Verify, and undo if the note does not look right.
        let after = try await raw(note.id)
        let beforeText = NoteHTML.normalized(before.plainText)
        let afterText = NoteHTML.normalized(after.plainText)
        let expectedTail = NoteHTML.normalized(text)
        let keptOriginal = afterText.hasPrefix(String(beforeText.prefix(max(20, beforeText.count / 2))))
        if !(afterText.contains(expectedTail) && keptOriginal) {
            _ = try? await run(NotesScripts.setBody, [note.id, before.html])
            throw JarvisError.verificationFailed(LocalizedText(
                en: "After adding the text, “\(before.title)” did not look right, so Jarvis restored the original content. Nothing was changed.",
                es: "Tras añadir el texto, «\(before.title)» no se veía bien, así que Jarvis restauró el contenido original. No se cambió nada."
            ))
        }
        return .done(ToolOutput(
            message: language.pick("Added the text to “\(after.title)”.", "Añadí el texto a «\(after.title)»."),
            data: ["id": .string(note.id), "title": .string(after.title), "folder": .string(note.folderName), "account": .string(note.accountName), "added_characters": .int(text.count)],
            verification: .verified(language.pick("Read the note back: the new text is there and the original text is intact.", "Se volvió a leer la nota: el texto nuevo está y el original sigue intacto."))
        ))
    }

    private func update(_ call: ValidatedToolCall, _ context: ExecutionContext) async throws -> ToolOutcome {
        let language = context.language
        let note: NoteRef
        switch try await resolve(call, context) {
        case .found(let found): note = found
        case .outcome(let outcome): return outcome
        }
        let newContent = call.string("new_content")
        let newTitle = call.string("new_title")
        let before = try await raw(note.id)
        try refuseUnsafeEdit(before, language: language)

        if let newContent {
            let title = newTitle ?? before.title
            _ = try await run(NotesScripts.setBody, [note.id, NoteHTML.newNote(title: title, content: newContent)])
        } else if let newTitle {
            _ = try await run(NotesScripts.rename, [note.id, newTitle])
        }

        let after = try await raw(note.id)
        let afterText = NoteHTML.normalized(after.plainText)
        var ok = true
        if let newTitle { ok = ok && NoteHTML.normalized(after.title) == NoteHTML.normalized(newTitle) }
        if let newContent, let firstLine = newContent.split(separator: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            ok = ok && afterText.contains(NoteHTML.normalized(String(firstLine)))
        }
        if !ok {
            _ = try? await run(NotesScripts.setBody, [note.id, before.html])
            throw JarvisError.verificationFailed(LocalizedText(
                en: "The note did not end up as requested, so Jarvis restored the original content.",
                es: "La nota no quedó como se pidió, así que Jarvis restauró el contenido original."
            ))
        }
        return .done(ToolOutput(
            message: language.pick("Updated “\(after.title)”.", "Actualicé «\(after.title)»."),
            data: ["id": .string(note.id), "title": .string(after.title)],
            verification: .verified(language.pick("Read the note back; it matches the requested change.", "Se volvió a leer la nota; coincide con el cambio solicitado."))
        ))
    }

    // MARK: notes.delete

    private func delete(_ call: ValidatedToolCall, _ context: ExecutionContext) async throws -> ToolOutcome {
        let language = context.language
        let note: NoteRef
        switch try await resolve(call, context) {
        case .found(let found): note = found
        case .outcome(let outcome): return outcome
        }
        if !context.isConfirmed {
            return .confirm(ConfirmationRequest(
                prompt: language.pick(
                    "Delete the note “\(note.title)” (\(note.accountName) › \(note.folderName))? It will go to Recently Deleted.",
                    "¿Eliminar la nota «\(note.title)» (\(note.accountName) › \(note.folderName))? Irá a Eliminadas recientemente."
                ),
                call: ToolCall(tool: .notesDelete, arguments: ["id": .string(note.id)]), destructive: true
            ))
        }
        let output = try await run(NotesScripts.delete, [note.id, note.folderID])
        guard output == "true" else {
            throw JarvisError.verificationFailed(LocalizedText(en: "The note is still in its folder after deleting it.", es: "La nota sigue en su carpeta después de eliminarla."))
        }
        return .done(ToolOutput(
            message: language.pick("Moved “\(note.title)” to Recently Deleted.", "Moví «\(note.title)» a Eliminadas recientemente."),
            data: ["id": .string(note.id), "title": .string(note.title), "deleted": true],
            verification: .verified(language.pick("The note is no longer in its folder.", "La nota ya no está en su carpeta."))
        ))
    }
}
