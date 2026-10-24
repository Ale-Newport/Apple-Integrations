import AppKit
import XCTest

@testable import JarvisIntegrations

/// Compiles every bundled AppleScript program against the installed app dictionaries. Compilation sends no Apple
/// events, so it needs no permission and touches no user data — but it catches syntax and terminology mistakes
/// (including changes in newer macOS versions) before a user ever runs a command.
final class ScriptCompilationTests: XCTestCase {
    private func compile(
        _ script: AppleScriptSource, requiring bundleIdentifier: String, file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil else {
            throw XCTSkip("\(bundleIdentifier) is not installed")
        }
        // NSAppleScript wants a single source string; osascript receives the same text line by line.
        guard let apple = NSAppleScript(source: script.text) else {
            return XCTFail("Could not create \(script.name)", file: file, line: line)
        }
        var error: NSDictionary?
        let ok = apple.compileAndReturnError(&error)
        XCTAssertTrue(
            ok,
            "\(script.name) failed to compile: \(error?[NSAppleScript.errorMessage] ?? "unknown") (\(error?[NSAppleScript.errorNumber] ?? "?"))",
            file: file, line: line)
    }

    func testNotesScriptsCompile() throws {
        for script in NotesScripts.all {
            try compile(script, requiring: "com.apple.Notes")
        }
    }

    func testMusicScriptsCompile() throws {
        for script in MusicScripts.all {
            try compile(script, requiring: "com.apple.Music")
        }
    }
    func testCommunicationScriptsCompile() throws {
        for script in MailScripts.all { try compile(script, requiring: "com.apple.mail") }
        for script in MessagesScripts.all { try compile(script, requiring: "com.apple.MobileSMS") }
    }
    func testBrowserScriptsCompile() throws {
        for script in BrowserScripts.all {
            try compile(script, requiring: script.name.contains("chrome") ? "com.google.Chrome" : "com.apple.Safari")
        }
    }
    func testSystemVolumeScriptCompiles() throws {
        try compile(SystemIntegration.volumeScript, requiring: "com.apple.finder")
    }

}
