import JarvisCore
import XCTest

@MainActor
final class AppModelTests: XCTestCase {
    private let create: ToolName = "stub.create"
    private let remove: ToolName = "stub.remove"

    private func makeModel(
        tools: [ToolDescriptor]? = nil,
        script: [String: [ToolCall]] = [:],
        handler: @escaping @Sendable (ValidatedToolCall, ExecutionContext) async throws -> ToolOutcome = { call, context in
            // Destructive tools ask first, exactly like the real integrations do.
            if call.descriptor.safety == .destructive, !context.isConfirmed {
                return .confirm(ConfirmationRequest(prompt: "Delete it?", call: call.call, destructive: true))
            }
            return .done(ToolOutput(message: "Done", verification: .verified("checked")))
        }
    ) throws -> (model: AppModel, integration: StubIntegration) {
        let integration = StubIntegration(tools: tools ?? [
            stubTool(create, safety: .modifying, parameters: [.string("title", "Title", required: true)]),
            stubTool(remove, safety: .destructive, parameters: [.string("id", "Id", required: true)]),
        ], handler: handler)
        let environment = AppEnvironment.isolated(integrations: [integration], interpreter: ScriptedInterpreter(script: script), directory: try temporaryDirectory())
        return (AppModel(environment: environment), integration)
    }

    // MARK: Commands

    func testSubmitRunsTheCommandAndShowsTheFinishedResponse() async throws {
        let (model, integration) = try makeModel(script: ["make it": [ToolCall(tool: create, arguments: ["title": "Milk"])]])
        model.input = "make it"
        model.submit()

        XCTAssertEqual(model.input, "", "the field is cleared as soon as the command is sent")
        XCTAssertEqual(model.messages.count, 1)
        await waitUntil("the command to finish") { model.messages.first?.response != nil }

        let response = try XCTUnwrap(model.messages.first?.response)
        XCTAssertEqual(response.status, .completed)
        XCTAssertEqual(response.results.first?.verification, .verified("checked"))
        XCTAssertEqual(integration.calls.all, ["stub.create"])
        XCTAssertFalse(model.hasRunningCommands)
    }

    func testBlankInputIsIgnored() throws {
        let (model, _) = try makeModel()
        model.input = "   \n "
        model.submit()
        XCTAssertTrue(model.messages.isEmpty)
    }

    func testAnIdenticalCommandThatIsStillRunningIsNotStartedTwice() async throws {
        let gate = Gate()
        let (model, integration) = try makeModel(script: ["make it": [ToolCall(tool: create, arguments: ["title": "Milk"])]]) { _, _ in
            await gate.wait()
            return .done(ToolOutput(message: "Done", verification: .verified("checked")))
        }
        model.submit("make it")
        model.submit("make it")
        XCTAssertEqual(model.messages.count, 1, "a double Return must not run the command twice")
        XCTAssertTrue(model.hasRunningCommands)

        await gate.open()
        await waitUntil("the command to finish") { !model.hasRunningCommands }
        XCTAssertEqual(integration.calls.all.count, 1)
    }

    func testStopCancelsARunningCommand() async throws {
        let (model, _) = try makeModel(script: ["slow": [ToolCall(tool: create, arguments: ["title": "x"])]]) { _, _ in
            try await Task.sleep(for: .seconds(30))
            return .done(ToolOutput(message: "never", verification: .notApplicable))
        }
        model.submit("slow")
        await waitUntil("the command to start") { model.messages.first.map { if case .running = $0.phase { return true } else { return false } } ?? false }

        model.cancelAll()
        await waitUntil("the command to be cancelled") { model.messages.first?.response != nil }
        XCTAssertEqual(model.messages.first?.response?.status, .cancelled)
    }

    func testUnrecognisedTextIsExplainedInTheHostLanguage() async throws {
        let (model, _) = try makeModel()
        model.submit("bla bla ble")
        await waitUntil("the reply") { model.messages.first?.response != nil }
        XCTAssertEqual(model.messages.first?.response?.status, .unrecognized)
    }

    // MARK: Confirmation

    func testDestructiveCommandsWaitForAConfirmationThatWorksOnce() async throws {
        let (model, integration) = try makeModel(script: ["delete it": [ToolCall(tool: remove, arguments: ["id": "42"])]])
        model.submit("delete it")
        await waitUntil("the confirmation question") { model.messages.first?.response != nil }

        let first = try XCTUnwrap(model.messages.first)
        XCTAssertEqual(first.response?.status, .needsConfirmation)
        XCTAssertTrue(integration.confirmedCalls.all.isEmpty, "nothing may be deleted before the user confirms")
        let token = try XCTUnwrap(first.response?.results.first?.confirmation?.token)

        model.resolve(in: first, token: token, decision: .confirm, label: "Confirm")
        model.resolve(in: first, token: token, decision: .confirm, label: "Confirm")
        XCTAssertEqual(model.messages.count, 2, "the second click on the same button is ignored")
        await waitUntil("the confirmed command to finish") { model.messages.last?.response != nil }

        XCTAssertEqual(model.messages.last?.response?.status, .completed)
        XCTAssertEqual(integration.confirmedCalls.all, ["stub.remove"], "deleted exactly once")
    }

    func testCancellingAConfirmationChangesNothing() async throws {
        let (model, integration) = try makeModel(script: ["delete it": [ToolCall(tool: remove, arguments: ["id": "42"])]])
        model.submit("delete it")
        await waitUntil("the confirmation question") { model.messages.first?.response != nil }
        let first = try XCTUnwrap(model.messages.first)
        let token = try XCTUnwrap(first.response?.results.first?.confirmation?.token)

        model.resolve(in: first, token: token, decision: .cancel, label: "Cancel")
        await waitUntil("the cancellation") { model.messages.last?.response != nil && model.messages.count == 2 }
        XCTAssertEqual(model.messages.last?.response?.status, .cancelled)
        XCTAssertTrue(integration.confirmedCalls.all.isEmpty)
    }

    // MARK: Conversation and history

    func testClearingTheConversationStopsAndEmptiesIt() async throws {
        let (model, _) = try makeModel(script: ["slow": [ToolCall(tool: create, arguments: ["title": "x"])]]) { _, _ in
            try await Task.sleep(for: .seconds(30))
            return .done(ToolOutput(message: "never", verification: .notApplicable))
        }
        model.submit("slow")
        model.clearConversation()
        XCTAssertTrue(model.messages.isEmpty)
    }

    func testRunToolShowsADirectToolCallInTheConversation() async throws {
        let (model, integration) = try makeModel(tools: [stubTool(.musicPause)]) { _, _ in .done(ToolOutput(message: "Paused", verification: .verified("state"))) }
        model.runTool(.musicPause, label: "Pause the music")
        XCTAssertEqual(model.messages.first?.text, "Pause the music")
        await waitUntil("the tool to finish") { model.messages.first?.response != nil }
        XCTAssertEqual(integration.calls.all, ["music.pause"])
        XCTAssertEqual(model.messages.first?.response?.message, "Paused")
    }

    func testHistoryRecordsCommandsAndTheUpArrowWalksThroughThem() async throws {
        let (model, _) = try makeModel(script: [
            "first": [ToolCall(tool: create, arguments: ["title": "1"])],
            "second": [ToolCall(tool: create, arguments: ["title": "2"])],
        ])
        model.submit("first")
        await waitUntil("the first command") { model.messages.count == 1 && model.messages[0].response != nil }
        model.submit("second")
        await waitUntil("history to hold both") { model.historyEntries.count == 2 }

        XCTAssertEqual(model.historyEntries.map(\.text), ["second", "first"], "newest first")
        model.recallPrevious()
        XCTAssertEqual(model.input, "second")
        model.recallPrevious()
        XCTAssertEqual(model.input, "first")
        model.recallPrevious()
        XCTAssertEqual(model.input, "first", "stops at the oldest entry")
        model.recallNext()
        XCTAssertEqual(model.input, "second")
        model.recallNext()
        XCTAssertEqual(model.input, "", "walking forward past the newest entry clears the field")
    }

    func testReusingAHistoryEntryFillsTheInputWithoutRunningIt() async throws {
        let (model, integration) = try makeModel(script: ["first": [ToolCall(tool: create, arguments: ["title": "1"])]])
        model.submit("first")
        await waitUntil("history") { model.historyEntries.count == 1 }
        model.selection = .history

        model.reuse(model.historyEntries[0])
        XCTAssertEqual(model.input, "first")
        XCTAssertEqual(model.selection, .chat)
        XCTAssertEqual(integration.calls.all.count, 1, "reusing must not run the command again")
    }

    func testDeletingAndClearingHistory() async throws {
        let (model, _) = try makeModel(script: [
            "first": [ToolCall(tool: create, arguments: ["title": "1"])],
            "second": [ToolCall(tool: create, arguments: ["title": "2"])],
        ])
        model.submit("first")
        await waitUntil("first") { model.messages.first?.response != nil }
        model.submit("second")
        await waitUntil("both entries") { model.historyEntries.count == 2 }

        model.deleteHistory([model.historyEntries[0].id])
        await waitUntil("one entry deleted") { model.historyEntries.count == 1 }
        XCTAssertEqual(model.historyEntries.first?.text, "first")

        model.clearHistory()
        await waitUntil("history cleared") { model.historyEntries.isEmpty }
    }

    // MARK: Settings

    func testSettingsChangesAreClampedAndPersisted() throws {
        let (model, _) = try makeModel()
        model.update { $0.morningHour = 99 }
        XCTAssertEqual(model.settings.morningHour, 23)
        XCTAssertEqual(model.environment.settingsStore.snapshot().morningHour, 23)

        let binding = model.binding(\.defaultReminderList)
        binding.wrappedValue = "Shopping"
        XCTAssertEqual(model.settings.defaultReminderList, "Shopping")
        XCTAssertEqual(model.environment.settingsStore.snapshot().defaultReminderList, "Shopping")
    }

    func testLanguageFollowsTheSettingAndFallsBackToTheSystem() throws {
        let (model, _) = try makeModel()
        model.update { $0.languagePreference = .spanish }
        XCTAssertEqual(model.language, .es)
        XCTAssertEqual(model.t("Hello", "Hola"), "Hola")
        model.update { $0.languagePreference = .english }
        XCTAssertEqual(model.t("Hello", "Hola"), "Hello")
        model.update { $0.languagePreference = .automatic }
        XCTAssertEqual(model.language, AppModel.systemLanguage)
    }

    // MARK: Choices for the Settings pickers

    func testChoicesAreReadFromTheIntegrationAndReadOnlyCalendarsAreSkipped() async throws {
        let (model, integration) = try makeModel(tools: [stubTool(.calendarListCalendars, integration: "stub")]) { _, _ in
            .done(ToolOutput(message: "ok", data: ["calendars": [
                ["name": "Home", "account": "iCloud", "writable": true],
                ["name": "Holidays", "account": "Subscribed", "writable": false],
            ]], verification: .notApplicable))
        }
        model.loadChoices(.calendars)
        await waitUntil("choices") { model.choices[.calendars]?.isLoaded == true }

        XCTAssertEqual(model.choices[.calendars]?.items.map(\.name), ["Home"])
        XCTAssertNil(model.choices[.calendars]?.problem)
        XCTAssertEqual(integration.calls.all, ["calendar.list_calendars"])
        XCTAssertTrue(model.historyEntries.isEmpty, "housekeeping reads are not user commands")
        let history = await model.environment.history.all()
        XCTAssertTrue(history.isEmpty)
    }

    func testLoadingChoicesNeverShowsAPermissionPromptUnlessAsked() async throws {
        let (model, integration) = try makeModel(tools: [stubTool(.remindersListLists)]) { _, _ in
            .done(ToolOutput(message: "ok", data: ["lists": [["name": "Shopping", "account": "iCloud"]]], verification: .notApplicable))
        }
        integration.authorization = .notDetermined(StubIntegration.requirement)

        model.loadChoices(.reminderLists)
        await waitUntil("the check") { model.choices[.reminderLists]?.isLoaded == true }
        XCTAssertNotNil(model.choices[.reminderLists]?.problem, "explains that access is needed")
        XCTAssertTrue(model.choices[.reminderLists]?.items.isEmpty ?? false)
        XCTAssertTrue(integration.requests.all.isEmpty, "opening Settings must not trigger a system prompt")
        XCTAssertTrue(integration.calls.all.isEmpty)

        // The user pressed the button: now asking is fine, and the list loads once access is granted.
        integration.authorization = .authorized
        model.loadChoices(.reminderLists, force: true, allowPrompt: true)
        await waitUntil("the reload") { model.choices[.reminderLists]?.items.isEmpty == false }
        XCTAssertEqual(model.choices[.reminderLists]?.items.map(\.name), ["Shopping"])
    }

    func testDeniedAccessIsExplainedWithoutRunningAnything() async throws {
        let (model, integration) = try makeModel(tools: [stubTool(.remindersListLists)])
        integration.authorization = .denied(StubIntegration.requirement)
        model.loadChoices(.reminderLists, allowPrompt: true)
        await waitUntil("the check") { model.choices[.reminderLists]?.isLoaded == true }
        XCTAssertNotNil(model.choices[.reminderLists]?.problem)
        XCTAssertTrue(integration.calls.all.isEmpty)
        XCTAssertTrue(integration.requests.all.isEmpty, "a denial cannot be re-prompted")
    }
}
