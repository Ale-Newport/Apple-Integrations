import AppKit
import Carbon.HIToolbox
import Foundation
import JarvisCore
import SwiftUI

/// UserDefaults keys for preferences that belong to the app shell (not to the Action Engine).
enum PreferenceKey {
    static let showInDock = "pref.showInDock"
    static let showMenuBarIcon = "pref.showMenuBarIcon"
    static let hotkeyEnabled = "pref.hotkey.enabled"
    static let hotkeyKeyCode = "pref.hotkey.keyCode"
    static let hotkeyModifiers = "pref.hotkey.modifiers"
    static let hotkeyLabel = "pref.hotkey.label"
    static let appearance = "pref.appearance"
}

/// A global keyboard shortcut.
struct HotKeyCombo: Equatable {
    var keyCode: UInt32
    /// Carbon modifier mask (`cmdKey`, `optionKey`, `controlKey`, `shiftKey`).
    var modifiers: UInt32
    var label: String

    /// Control + Option + Space: unlikely to clash with Spotlight, Alfred, Raycast or app shortcuts.
    static let `default` = HotKeyCombo(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey), label: "Space")

    var display: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + label
    }

    static func load(_ defaults: UserDefaults = .standard) -> HotKeyCombo {
        guard defaults.object(forKey: PreferenceKey.hotkeyKeyCode) != nil else { return .default }
        return HotKeyCombo(
            keyCode: UInt32(defaults.integer(forKey: PreferenceKey.hotkeyKeyCode)),
            modifiers: UInt32(defaults.integer(forKey: PreferenceKey.hotkeyModifiers)),
            label: defaults.string(forKey: PreferenceKey.hotkeyLabel) ?? "?"
        )
    }

    func save(_ defaults: UserDefaults = .standard) {
        defaults.set(Int(keyCode), forKey: PreferenceKey.hotkeyKeyCode)
        defaults.set(Int(modifiers), forKey: PreferenceKey.hotkeyModifiers)
        defaults.set(label, forKey: PreferenceKey.hotkeyLabel)
    }

    /// Builds a combo from a key-down event, or `nil` when it has no modifier (a bare key would break typing everywhere).
    @MainActor
    static func from(_ event: NSEvent) -> HotKeyCombo? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        let functionKeys: Set<Int> = [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
            kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
        ]
        // A bare letter would break typing everywhere; function keys are safe on their own.
        guard modifiers != 0 || functionKeys.contains(Int(event.keyCode)) else { return nil }
        return HotKeyCombo(keyCode: UInt32(event.keyCode), modifiers: modifiers, label: keyLabel(for: event))
    }

    private static func keyLabel(for event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default: return (event.charactersIgnoringModifiers ?? "?").uppercased()
        }
    }
}
