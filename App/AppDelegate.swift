import AppKit
import CoreServices
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var model: AppModel?
    /// True when macOS started Jarvis as a login item, in which case the main window stays closed.
    static var launchedAsLoginItem = false
    private static var handledLoginLaunch = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        if event?.eventID == AEEventID(kAEOpenApplication),
           event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem) {
            AppDelegate.launchedAsLoginItem = true
        }
    }

    /// Called when the main window first appears: a login-item launch closes it again so Jarvis starts quietly.
    static func closeMainWindowIfLaunchedAtLogin() {
        guard launchedAsLoginItem, !handledLoginLaunch else { return }
        handledLoginLaunch = true
        NSApp.windows.first { $0.identifier?.rawValue.contains("main") == true }?.close()
    }

    /// Clicking the Dock icon with no window open brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { AppDelegate.model?.showMainWindow() }
        return true
    }

    /// Jarvis keeps running in the menu bar (and keeps its global shortcut) after the window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        AppDelegate.model?.environment.ipc.stop()
    }
}
