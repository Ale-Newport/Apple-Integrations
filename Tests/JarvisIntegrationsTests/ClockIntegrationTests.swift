import XCTest
import JarvisCore
@testable import JarvisIntegrations

/// A stateful stand-in for the user's Jarvis shortcuts + the Clock app behind them.
actor FakeClock: ShortcutsRunning {
    var installed: Set<String>
    var alarms: [ClockAlarm] = []
    var timerRemaining: Int?
    var swallowCreate = false          // simulate a shortcut that "succeeds" without doing anything
    var failWith: ShortcutsError?
    private(set) var runs: [(name: String, input: String?)] = []
    private let names = ShortcutNames()

    init(installed: Set<String>? = nil) {
        self.installed = installed ?? Set(ClockShortcut.allCases.map { $0.name(in: ShortcutNames()) })
    }

    func setInstalled(_ value: Set<String>) { installed = value }
    func setAlarms(_ value: [ClockAlarm]) { alarms = value }
    func setSwallowCreate(_ value: Bool) { swallowCreate = value }
    func setTimer(_ value: Int?) { timerRemaining = value }
    func setFail(_ value: ShortcutsError?) { failWith = value }

    func installedShortcutNames() async throws -> Set<String> { installed }

    func run(name: String, input: String?, timeout: TimeInterval) async throws -> ShortcutRunOutput {
        runs.append((name, input))
        if let failWith { throw failWith }
        let json = input.flatMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
        switch name {
        case names.createAlarm:
            if !swallowCreate, let hour = json?["hour"]?.intValue, let minute = json?["minute"]?.intValue {
                alarms.append(ClockAlarm(hour: hour, minute: minute, isEnabled: true, label: json?["label"]?.stringValue ?? ""))
            }
            return ShortcutRunOutput(text: "OK")
        case names.listAlarms:
            return ShortcutRunOutput(text: alarms.map { "\($0.hour)|\($0.minute)|\($0.isEnabled ? "Yes" : "No")|\($0.label)" }.joined(separator: "\n"))
        case names.setAlarmEnabled:
            let hour = json?["hour"]?.intValue, minute = json?["minute"]?.intValue
            for index in alarms.indices where alarms[index].hour == hour && alarms[index].minute == minute {
                alarms[index].isEnabled = json?["state"]?.stringValue == "on"
            }
            return ShortcutRunOutput(text: "OK")
        case names.deleteAlarm:
            let hour = json?["hour"]?.intValue, minute = json?["minute"]?.intValue
            alarms.removeAll { $0.hour == hour && $0.minute == minute }
            return ShortcutRunOutput(text: "OK")
        case names.startTimer:
            timerRemaining = json?["seconds"]?.intValue
            return ShortcutRunOutput(text: "OK")
        case names.cancelTimer:
            timerRemaining = nil
            return ShortcutRunOutput(text: "OK")
        case names.getTimer:
            guard let timerRemaining else { throw ShortcutsError.failed(status: 1, message: "No timer") }
            return ShortcutRunOutput(text: String(format: "%.1f min", Double(timerRemaining) / 60).replacingOccurrences(of: ".", with: ","))
        default:
            throw ShortcutsError.notInstalled(name)
        }
    }
}

/// "Now" is Saturday 17 Oct 2026 13:08 BST, so the next 07:30 is tomorrow morning.
final class ClockIntegrationTests: XCTestCase {
    private let clock = FakeClock()

    private func registry(_ fake: FakeClock? = nil) -> ToolRegistry {
        ToolRegistry(integrations: [ClockIntegration(shortcuts: fake ?? clock, clockInstalled: { true })])
    }

    // MARK: Alarms

    func testSetAnAlarmForTomorrowMorningAndReadItBack() async throws {
        let outcome = try await registry().run(.alarmsCreate, ["time": "07:30", "date": "2026-10-18", "label": "Gym"])
        let output = try XCTUnwrap(outcome.output)
        XCTAssertTrue(output.verification.isVerified)
        XCTAssertTrue(output.message.contains("07:30"))
        XCTAssertEqual(output.data?["next_ring"], "2026-10-18T07:30:00+01:00")
        let alarms = await clock.alarms
        XCTAssertEqual(alarms, [ClockAlarm(hour: 7, minute: 30, isEnabled: true, label: "Gym")])

        // The shortcut received exactly the documented JSON.
        let createRuns = await clock.runs
        let input = try XCTUnwrap(createRuns.first { $0.name == "Jarvis Create Alarm" }?.input)
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(input.utf8))
        XCTAssertEqual(json["hour"], 7)
        XCTAssertEqual(json["minute"], 30)
        XCTAssertEqual(json["iso"], "2026-10-18T07:30:00")
        XCTAssertEqual(json["label"], "Gym")
    }

    func testAlarmForTheNextOccurrenceNeedsNoDate() async throws {
        let outcome = try await registry().run(.alarmsCreate, ["time": "18:00"])
        XCTAssertEqual(outcome.output?.data?["next_ring"], "2026-10-17T18:00:00+01:00", "18:00 is still ahead today")
    }

    func testAlarmsCannotBePinnedToALaterDay() async throws {
        do {
            _ = try await registry().run(.alarmsCreate, ["time": "07:30", "date": "2026-10-20"])
            XCTFail("should have thrown")
        } catch JarvisError.failed(let code, let text) {
            XCTAssertEqual(code, "alarm_date_mismatch")
            XCTAssertTrue(text.en.contains("I didn't create it"))
        }
        let alarms = await clock.alarms
        XCTAssertTrue(alarms.isEmpty, "no misleading alarm was created")
    }

    func testRepeatingAlarmsAreHonestlyUnsupported() async throws {
        do {
            _ = try await registry().run(.alarmsCreate, ["time": "06:00", "repeat_days": ["mon", "tue"]])
            XCTFail("should have thrown")
        } catch JarvisError.unsupported(let text, let alternative) {
            XCTAssertTrue(text.en.contains("one-time"))
            XCTAssertNotNil(alternative)
        }
        let runs = await clock.runs
        XCTAssertTrue(runs.isEmpty)
    }

    func testWithoutTheCreateShortcutTheUserGetsExactInstructions() async throws {
        let fake = FakeClock(installed: [])
        do {
            _ = try await registry(fake).run(.alarmsCreate, ["time": "07:30"])
            XCTFail("should have thrown")
        } catch JarvisError.setupRequired(let instructions, let text) {
            XCTAssertTrue(text.en.contains("Jarvis Create Alarm"))
            XCTAssertTrue(instructions.steps.joined(separator: "\n").contains("Add Alarm"))
            XCTAssertTrue(instructions.steps.joined(separator: "\n").contains("Get Dictionary Value"))
            XCTAssertEqual(instructions.documentation, "docs/SHORTCUTS_SETUP.md")
        }
    }

    func testWithoutTheListShortcutTheAlarmIsCreatedButMarkedUnverified() async throws {
        let fake = FakeClock(installed: ["Jarvis Create Alarm"])
        let outcome = try await registry(fake).run(.alarmsCreate, ["time": "07:30"])
        let verification = try XCTUnwrap(outcome.output).verification
        guard case .unverified(let reason) = verification else { return XCTFail("should be unverified") }
        XCTAssertTrue(reason.contains("Jarvis List Alarms"))
    }

    func testAShortcutThatSilentlyDoesNothingIsCaught() async throws {
        await clock.setSwallowCreate(true)
        do {
            _ = try await registry().run(.alarmsCreate, ["time": "07:30"])
            XCTFail("should have thrown")
        } catch JarvisError.verificationFailed {}
    }

    func testShortcutFailuresAreExplained() async throws {
        await clock.setFail(.failed(status: 1, message: "The operation couldn’t be completed"))
        do {
            _ = try await registry().run(.alarmsCreate, ["time": "07:30"])
            XCTFail("should have thrown")
        } catch JarvisError.failed(let code, let text) {
            XCTAssertEqual(code, "shortcut_failed")
            XCTAssertTrue(text.en.contains("Jarvis "), "names the shortcut that failed: \(text.en)")
        }
        await clock.setFail(.timedOut)
        do {
            _ = try await registry().run(.alarmsCreate, ["time": "07:30"])
            XCTFail("should have thrown")
        } catch JarvisError.failed(let code, let text) {
            XCTAssertEqual(code, "shortcut_timeout")
            XCTAssertTrue(text.en.contains("Always Allow"))
        }
    }

    func testListAlarmsSortedWithOffOnesMarked() async throws {
        await clock.setAlarms([
            ClockAlarm(hour: 18, minute: 0, isEnabled: false, label: ""),
            ClockAlarm(hour: 7, minute: 30, isEnabled: true, label: "Gym"),
        ])
        let outcome = try await registry().run(.alarmsList, [:])
        let message = try XCTUnwrap(outcome.output).message
        XCTAssertTrue(message.contains("7:30 AM — Gym"))
        XCTAssertTrue(message.contains("6:00 PM (off)"))
        XCTAssertLessThan(message.range(of: "7:30 AM")!.lowerBound, message.range(of: "6:00 PM")!.lowerBound)
    }

    func testListParsingIsTolerantOfLocalisedBooleans() {
        let alarms = ClockAlarm.parse("7|30|Sí|Gym | early\n18|0|No|\nnot an alarm\n25|0|Yes|bad hour")
        XCTAssertEqual(alarms.count, 2)
        XCTAssertEqual(alarms[0], ClockAlarm(hour: 7, minute: 30, isEnabled: true, label: "Gym | early"))
        XCTAssertFalse(alarms[1].isEnabled)
    }

    func testTurnOffMyAlarm() async throws {
        await clock.setAlarms([ClockAlarm(hour: 7, minute: 30, isEnabled: true, label: "")])
        let outcome = try await registry().run(.alarmsSetEnabled, ["enabled": false, "time": "07:30"])
        XCTAssertTrue(try XCTUnwrap(outcome.output).verification.isVerified)
        let alarms = await clock.alarms
        XCTAssertFalse(alarms[0].isEnabled)

        let again = try await registry().run(.alarmsSetEnabled, ["enabled": false, "time": "07:30"])
        XCTAssertTrue(try XCTUnwrap(again.output).message.contains("already off"))
    }

    func testAnAmbiguousHourMatchesBothAMAndPMAndAsks() async throws {
        await clock.setAlarms([
            ClockAlarm(hour: 7, minute: 30, isEnabled: true, label: "Wake up"),
            ClockAlarm(hour: 19, minute: 30, isEnabled: true, label: "Dinner"),
        ])
        let outcome = try await registry().run(.alarmsSetEnabled, ["enabled": false, "time": "07:30", "time_is_ambiguous": true])
        let clarification = try XCTUnwrap(outcome.clarification)
        XCTAssertEqual(clarification.options.count, 2)
        let chosen = try await registry().run(.alarmsSetEnabled, clarification.options[1].call.arguments)
        XCTAssertNotNil(chosen.output)
        let alarms = await clock.alarms
        XCTAssertEqual(alarms.map(\.isEnabled), [true, false])
    }

    func testSelectingByLabel() async throws {
        await clock.setAlarms([ClockAlarm(hour: 7, minute: 30, isEnabled: true, label: "Gym"), ClockAlarm(hour: 8, minute: 0, isEnabled: true, label: "Work")])
        let outcome = try await registry().run(.alarmsSetEnabled, ["enabled": false, "label": "gym"])
        XCTAssertEqual(outcome.output?.data?["time"], "07:30")
    }

    func testUnknownAlarmListsTheExistingOnes() async throws {
        await clock.setAlarms([ClockAlarm(hour: 7, minute: 30, isEnabled: true, label: "")])
        do {
            _ = try await registry().run(.alarmsSetEnabled, ["enabled": false, "time": "09:00"])
            XCTFail("should have thrown")
        } catch JarvisError.notFound(let code, let text) {
            XCTAssertEqual(code, "alarm_not_found")
            XCTAssertTrue(text.en.contains("7:30 AM"))
        }
    }

    func testDeleteAnAlarmAsksFirst() async throws {
        await clock.setAlarms([ClockAlarm(hour: 7, minute: 30, isEnabled: true, label: "")])
        let first = try await registry().run(.alarmsDelete, ["time": "07:30"])
        let confirmation = try XCTUnwrap(first.confirmation)
        XCTAssertTrue(confirmation.destructive)
        let untouched = await clock.alarms
        XCTAssertEqual(untouched.count, 1)

        let done = try await registry().run(.alarmsDelete, confirmation.call.arguments, context: executionContext(confirmed: true))
        XCTAssertTrue(try XCTUnwrap(done.output).verification.isVerified)
        let remaining = await clock.alarms
        XCTAssertTrue(remaining.isEmpty)
    }

    func testDeletingWhenTwoAlarmsShareATimeIsRefused() async throws {
        await clock.setAlarms([ClockAlarm(hour: 7, minute: 30, isEnabled: true, label: "A"), ClockAlarm(hour: 7, minute: 30, isEnabled: true, label: "B")])
        let first = try await registry().run(.alarmsDelete, ["time": "07:30", "label": "A"])
        let confirmation = try XCTUnwrap(first.confirmation)
        do {
            _ = try await registry().run(.alarmsDelete, confirmation.call.arguments, context: executionContext(confirmed: true))
            XCTFail("should have thrown")
        } catch JarvisError.failed(let code, _) {
            XCTAssertEqual(code, "alarm_time_shared")
        }
        let alarms = await clock.alarms
        XCTAssertEqual(alarms.count, 2, "nothing was deleted")
    }

    // MARK: Timers

    func testStartATimerAndConfirmItIsRunning() async throws {
        let outcome = try await registry().run(.timersCreate, ["duration_seconds": 600])
        let output = try XCTUnwrap(outcome.output)
        XCTAssertEqual(output.message, "Timer started for 10 minutes.")
        XCTAssertTrue(output.verification.isVerified)
        let remaining = await clock.timerRemaining
        XCTAssertEqual(remaining, 600)
        let timerRuns = await clock.runs
        let input = try XCTUnwrap(timerRuns.first { $0.name == "Jarvis Start Timer" }?.input)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: Data(input.utf8))["seconds"], 600)
    }

    func testTimerLabelsAreNotPretendedToBeSaved() async throws {
        let outcome = try await registry().run(.timersCreate, ["duration_seconds": 1200, "label": "Pasta"])
        XCTAssertTrue(try XCTUnwrap(outcome.output).warnings.contains { $0.contains("cannot store a label") })
    }

    func testTimerWithoutTheGetShortcutIsUnverified() async throws {
        let fake = FakeClock(installed: ["Jarvis Start Timer"])
        let outcome = try await registry(fake).run(.timersCreate, ["duration_seconds": 60])
        guard case .unverified = try XCTUnwrap(outcome.output).verification else { return XCTFail("should be unverified") }
    }

    func testATimerThatIsNotActuallyRunningIsCaught() async throws {
        await clock.setTimer(nil)
        // A start shortcut that does nothing: emulate by swallowing through failWith on get… use a fake with no state change.
        let fake = FakeClock(installed: ["Jarvis Start Timer", "Jarvis Get Timer"])
        await fake.setFail(nil)
        let lying = LyingTimerShortcuts(base: fake)
        do {
            _ = try await ToolRegistry(integrations: [ClockIntegration(shortcuts: lying, clockInstalled: { true })]).run(.timersCreate, ["duration_seconds": 300])
            XCTFail("should have thrown")
        } catch JarvisError.verificationFailed {}
    }

    func testCancelTheTimer() async throws {
        await clock.setTimer(240)
        let outcome = try await registry().run(.timersCancel, [:])
        XCTAssertTrue(try XCTUnwrap(outcome.output).verification.isVerified)
        let remaining = await clock.timerRemaining
        XCTAssertNil(remaining)
    }

    // MARK: Parsing, status and instructions

    func testParsingRemainingTimeInManyFormats() {
        XCTAssertEqual(ClockIntegration.parseDuration("9.5 min"), 570)
        XCTAssertEqual(ClockIntegration.parseDuration("9,5 min"), 570)
        XCTAssertEqual(ClockIntegration.parseDuration("570 sec"), 570)
        XCTAssertEqual(ClockIntegration.parseDuration("1 hr 5 min"), 3900)
        XCTAssertEqual(ClockIntegration.parseDuration("9 minutos 30 segundos"), 570)
        XCTAssertEqual(ClockIntegration.parseDuration("00:09:30"), 570)
        XCTAssertEqual(ClockIntegration.parseDuration("09:30"), 570)
        XCTAssertNil(ClockIntegration.parseDuration(""))
        XCTAssertNil(ClockIntegration.parseDuration("no timer"))
        XCTAssertNil(ClockIntegration.parseDuration(nil))
    }

    func testStatusReflectsWhichShortcutsExist() async throws {
        let missing = ClockIntegration(shortcuts: FakeClock(installed: []), clockInstalled: { true })
        let needs = await missing.status()
        XCTAssertEqual(needs.state, .needsSetup)
        XCTAssertTrue(needs.detail?.en.contains("Jarvis Create Alarm") == true)

        let essentialOnly = ClockIntegration(shortcuts: FakeClock(installed: ["Jarvis Create Alarm", "Jarvis Start Timer"]), clockInstalled: { true })
        let partial = await essentialOnly.status()
        XCTAssertEqual(partial.state, .ready)
        XCTAssertTrue(partial.detail?.en.contains("Missing shortcuts") == true)

        let complete = await ClockIntegration(shortcuts: clock, clockInstalled: { true }).status()
        XCTAssertEqual(complete.state, .ready)
        XCTAssertNil(complete.detail)

        let noClock = await ClockIntegration(shortcuts: clock, clockInstalled: { false }).status()
        XCTAssertEqual(noClock.state, .unavailable)
    }

    func testEveryShortcutHasStepsInBothLanguages() {
        for shortcut in ClockShortcut.allCases {
            for language in Language.allCases {
                let steps = shortcut.steps(name: shortcut.name(in: ShortcutNames()), language: language)
                XCTAssertGreaterThanOrEqual(steps.count, 2, "\(shortcut) \(language)")
                XCTAssertTrue(steps[0].contains(shortcut.name(in: ShortcutNames())))
            }
            XCTAssertFalse(shortcut.inputExample.isEmpty)
        }
        let instructions = ClockShortcut.instructions(missing: [.createAlarm, .startTimer], names: ShortcutNames(), language: .es)
        XCTAssertTrue(instructions.steps.joined(separator: "\n").contains("Añadir alarma"))
        XCTAssertTrue(instructions.steps.joined(separator: "\n").contains("Iniciar temporizador"))
    }

    func testCustomShortcutNamesAreUsed() async throws {
        var settings = JarvisSettings()
        settings.shortcutNames.createAlarm = "Mi alarma"
        let fake = FakeClock(installed: ["Mi alarma", "Jarvis List Alarms"])
        let renamed = FakeRenamed(base: fake, mapping: ["Mi alarma": "Jarvis Create Alarm"])
        let outcome = try await ToolRegistry(integrations: [ClockIntegration(shortcuts: renamed, clockInstalled: { true })]).run(.alarmsCreate, ["time": "07:30"], context: executionContext(settings: settings))
        XCTAssertNotNil(outcome.output)
        let runs = await renamed.requested
        XCTAssertTrue(runs.contains("Mi alarma"))
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

/// Accepts "start timer" but never starts anything, like a mis-built shortcut.
private struct LyingTimerShortcuts: ShortcutsRunning {
    let base: FakeClock
    func installedShortcutNames() async throws -> Set<String> { try await base.installedShortcutNames() }
    func run(name: String, input: String?, timeout: TimeInterval) async throws -> ShortcutRunOutput {
        if name == "Jarvis Start Timer" { return ShortcutRunOutput(text: "OK") }
        return try await base.run(name: name, input: input, timeout: timeout)
    }
}

/// Maps user-chosen shortcut names to the fake's built-in ones.
private actor FakeRenamed: ShortcutsRunning {
    let base: FakeClock
    let mapping: [String: String]
    private(set) var requested: [String] = []
    init(base: FakeClock, mapping: [String: String]) { self.base = base; self.mapping = mapping }
    func installedShortcutNames() async throws -> Set<String> { try await base.installedShortcutNames() }
    func run(name: String, input: String?, timeout: TimeInterval) async throws -> ShortcutRunOutput {
        requested.append(name)
        return try await base.run(name: mapping[name] ?? name, input: input, timeout: timeout)
    }
}
