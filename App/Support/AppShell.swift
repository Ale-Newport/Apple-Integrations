import AppKit
import Foundation
import Observation
import SwiftUI

enum AppearancePreference: String, CaseIterable {
    case system, light, dark

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// Preferences of the app *shell*: how Jarvis presents itself on the Mac (Dock, menu bar, global shortcut,
/// appearance). Everything that changes what commands do lives in `JarvisSettings` instead.
@MainActor
@Observable
final class AppShell {
    private(set) var showInDock: Bool
    private(set) var showMenuBarIcon: Bool
    private(set) var hotkeyEnabled: Bool
    private(set) var hotkey: HotKeyCombo
    private(set) var hotkeyError: String?
    private(set) var appearance: AppearancePreference

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var onHotKey: (() -> Void)?
    @ObservationIgnored private var isStarted = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var dock = defaults.object(forKey: PreferenceKey.showInDock) as? Bool ?? true
        let menuBar = defaults.object(forKey: PreferenceKey.showMenuBarIcon) as? Bool ?? true
        // Never leave the app without a visible entry point.
        if !dock && !menuBar { dock = true }
        showInDock = dock
        showMenuBarIcon = menuBar
        hotkeyEnabled = defaults.object(forKey: PreferenceKey.hotkeyEnabled) as? Bool ?? true
        hotkey = HotKeyCombo.load(defaults)
        appearance = AppearancePreference(rawValue: defaults.string(forKey: PreferenceKey.appearance) ?? "") ?? .system
    }

    /// Applies the stored preferences. `onHotKey` runs on the main actor whenever the global shortcut is pressed.
    func start(onHotKey: @escaping () -> Void) {
        self.onHotKey = onHotKey
        isStarted = true
        applyActivationPolicy()
        applyHotKey()
    }

    // MARK: Dock and menu bar

    func setShowInDock(_ value: Bool) {
        guard value || showMenuBarIcon else { return }
        showInDock = value
        defaults.set(value, forKey: PreferenceKey.showInDock)
        if isStarted { applyActivationPolicy() }
    }

    func setShowMenuBarIcon(_ value: Bool) {
        guard value || showInDock else { return }
        showMenuBarIcon = value
        defaults.set(value, forKey: PreferenceKey.showMenuBarIcon)
    }

    private func applyActivationPolicy() {
        NSApplication.shared.setActivationPolicy(showInDock ? .regular : .accessory)
    }

    // MARK: Appearance

    func setAppearance(_ value: AppearancePreference) {
        appearance = value
        defaults.set(value.rawValue, forKey: PreferenceKey.appearance)
    }

    // MARK: Global shortcut

    func setHotkeyEnabled(_ value: Bool) {
        hotkeyEnabled = value
        defaults.set(value, forKey: PreferenceKey.hotkeyEnabled)
        applyHotKey()
    }

    func setHotkey(_ combo: HotKeyCombo) {
        let previous = hotkey
        hotkey = combo
        combo.save(defaults)
        applyHotKey()
        if hotkeyError != nil, hotkeyEnabled {
            // The system refused the new combination: go back to the previous one so the shortcut keeps working.
            let message = hotkeyError
            hotkey = previous
            previous.save(defaults)
            applyHotKey()
            hotkeyError = message
        }
    }

    func resetHotkey() { setHotkey(.default) }

    private func applyHotKey() {
        guard hotkeyEnabled, let onHotKey else {
            GlobalHotKey.shared.unregister()
            hotkeyError = nil
            return
        }
        if GlobalHotKey.shared.register(hotkey, onPress: onHotKey) {
            hotkeyError = nil
        } else {
            hotkeyError = GlobalHotKey.shared.lastError
        }
    }
}
