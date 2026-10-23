import AppKit
import Carbon.HIToolbox
import Foundation
import JarvisCore

/// Registers one system-wide keyboard shortcut with the Carbon Event Manager (`RegisterEventHotKey`).
///
/// This is the one API that works from a sandboxed *or* unsandboxed app **without** the Accessibility or Input
/// Monitoring permission: macOS delivers only the registered key combination, never other keystrokes.
@MainActor
final class GlobalHotKey {
    static let shared = GlobalHotKey()

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var onPress: (() -> Void)?
    private(set) var registeredCombo: HotKeyCombo?
    private(set) var lastError: String?

    private static let signature: OSType = {
        // 'JRVS'
        var value: OSType = 0
        for scalar in "JRVS".unicodeScalars { value = (value << 8) | OSType(scalar.value) }
        return value
    }()

    private init() {}

    /// Registers `combo`, replacing any earlier registration. Returns `false` (and sets `lastError`) when the system
    /// refuses, typically because another app already owns that shortcut.
    @discardableResult
    func register(_ combo: HotKeyCombo, onPress: @escaping () -> Void) -> Bool {
        unregister()
        self.onPress = onPress
        lastError = nil

        if handlerRef == nil {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                // Carbon delivers hot-key events on the main thread.
                MainActor.assumeIsolated { GlobalHotKey.shared.fire() }
                return noErr
            }, 1, &eventType, nil, &handlerRef)
            guard status == noErr else {
                lastError = "InstallEventHandler failed (\(status))"
                return false
            }
        }

        let identifier = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, identifier, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr else {
            hotKeyRef = nil
            lastError = status == OSStatus(eventHotKeyExistsErr)
                ? "That shortcut is already used by another app."
                : "RegisterEventHotKey failed (\(status))"
            JarvisLog.app.error("Could not register global shortcut: \(self.lastError ?? "", privacy: .public)")
            return false
        }
        registeredCombo = combo
        return true
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        registeredCombo = nil
    }

    private func fire() {
        onPress?()
    }
}
