import Carbon.HIToolbox
import XCTest

@MainActor
final class AppShellTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "jarvis.shell.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testDockAndMenuBarCannotBothBeHidden() {
        let shell = AppShell(defaults: makeDefaults())
        XCTAssertTrue(shell.showInDock)
        XCTAssertTrue(shell.showMenuBarIcon)

        shell.setShowInDock(false)
        XCTAssertFalse(shell.showInDock)
        shell.setShowMenuBarIcon(false)
        XCTAssertTrue(shell.showMenuBarIcon, "the last remaining entry point stays visible")

        shell.setShowInDock(true)
        shell.setShowMenuBarIcon(false)
        XCTAssertFalse(shell.showMenuBarIcon)
        shell.setShowInDock(false)
        XCTAssertTrue(shell.showInDock)
    }

    func testStoredStateThatWouldHideEverythingIsRepaired() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: PreferenceKey.showInDock)
        defaults.set(false, forKey: PreferenceKey.showMenuBarIcon)
        let shell = AppShell(defaults: defaults)
        XCTAssertTrue(shell.showInDock || shell.showMenuBarIcon)
    }

    func testPreferencesSurviveARestart() {
        let defaults = makeDefaults()
        let shell = AppShell(defaults: defaults)
        shell.setAppearance(.dark)
        shell.setShowMenuBarIcon(false)
        shell.setHotkeyEnabled(false)
        let combo = HotKeyCombo(keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(cmdKey | shiftKey), label: "J")
        shell.setHotkey(combo)

        let restarted = AppShell(defaults: defaults)
        XCTAssertEqual(restarted.appearance, .dark)
        XCTAssertFalse(restarted.showMenuBarIcon)
        XCTAssertFalse(restarted.hotkeyEnabled)
        XCTAssertEqual(restarted.hotkey, combo)
        XCTAssertEqual(restarted.hotkey.display, "⇧⌘J")
    }

    func testResettingTheShortcutRestoresControlOptionSpace() {
        let shell = AppShell(defaults: makeDefaults())
        shell.setHotkeyEnabled(false)
        shell.setHotkey(HotKeyCombo(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey), label: "K"))
        shell.resetHotkey()
        XCTAssertEqual(shell.hotkey, .default)
        XCTAssertEqual(HotKeyCombo.default.display, "⌃⌥Space")
    }

    func testAppearanceMapsToColorSchemes() {
        XCTAssertNil(AppearancePreference.system.colorScheme)
        XCTAssertEqual(AppearancePreference.light.colorScheme, .light)
        XCTAssertEqual(AppearancePreference.dark.colorScheme, .dark)
    }
}
