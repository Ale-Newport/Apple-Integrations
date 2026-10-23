# Permissions and security

Jarvis asks macOS for **only** what each feature needs, **when** you first use that feature (or press **Allow** in
Settings ▸ Permissions), and it explains why before macOS shows its own prompt. It never edits privacy settings, never
reads the TCC database, and never uses private APIs or UI scripting.

## What is requested

| Feature | Mechanism | macOS permission | `Info.plist` key | Entitlement |
| --- | --- | --- | --- | --- |
| Apple Music | AppleScript through `/usr/bin/osascript` | Automation → *Music* | `NSAppleEventsUsageDescription` | `com.apple.security.automation.apple-events` |
| Notes | AppleScript through `/usr/bin/osascript` | Automation → *Notes* | `NSAppleEventsUsageDescription` | `com.apple.security.automation.apple-events` |
| Reminders | EventKit (`requestFullAccessToReminders`) | Reminders (full access) | `NSRemindersFullAccessUsageDescription` | `com.apple.security.personal-information.calendars` ¹ |
| Calendar | EventKit (`requestFullAccessToEvents`) | Calendars (full access) | `NSCalendarsFullAccessUsageDescription` | `com.apple.security.personal-information.calendars` |
| Contacts (optional) | Contacts framework | Contacts | `NSContactsUsageDescription` | `com.apple.security.personal-information.addressbook` |
| Clock | `shortcuts run` | none (Shortcuts may ask *Always Allow* per shortcut) | – | – |

¹ Hardened Runtime has no separate Reminders entitlement; EventKit access for Reminders and Calendar is covered by the
Calendar entitlement. See [TESTING.md](TESTING.md) for whether this was confirmed on a real Mac.

**Why full access for Reminders and Calendar?** Finding an existing reminder to complete, or an event to move or cancel,
and checking for conflicts all require reading existing data. Write-only access would not allow that.

**Why is the app not sandboxed?** Controlling Music and Notes through Apple Events from a sandboxed app needs
*temporary-exception* entitlements that the Mac App Store rejects, and `shortcuts run` needs to launch a child process.
Jarvis is therefore a Developer-ID-style, **Hardened Runtime** app distributed outside the App Store. The Hardened Runtime
is on (so macOS enforces the entitlements above); App Sandbox is off.

## How each state is handled

| State | What Jarvis does |
| --- | --- |
| **Not determined** | The command that needs it triggers the system prompt (Music/Notes launch quietly in the background first, because macOS can only ask on behalf of a running app). The command then continues if you allow. |
| **Granted** | Runs normally. |
| **Denied** | Nothing is attempted. The response says what is blocked and offers **Open System Settings** on the right pane (Privacy & Security ▸ Automation / Reminders / Calendars / Contacts). |
| **Restricted** (parental controls, MDM) | Reported as restricted; you cannot change it in System Settings, and Jarvis says so. |
| **App missing** | Reported as unavailable (for example if Music is not installed). |
| **Shortcut missing** (Clock) | `setup_required` with the exact steps; nothing else is created in its place. |

Status checks (the coloured dots, Settings ▸ Permissions) never show a prompt. While a system prompt is on screen the
command that triggered it waits, and can be cancelled with **Stop**.

## Resetting and re-asking

```bash
# Forget what you answered, then use the feature again to be re-asked (replace the id if you changed it):
tccutil reset AppleEvents com.alejandronewport.JarvisAppleIntegrations
tccutil reset Reminders   com.alejandronewport.JarvisAppleIntegrations
tccutil reset Calendar    com.alejandronewport.JarvisAppleIntegrations
tccutil reset AddressBook com.alejandronewport.JarvisAppleIntegrations
```

macOS ties a grant to the app's **code signature**. Builds signed with your Apple Development identity
(`Config/Local.xcconfig`, see the README) keep their grants across rebuilds; ad-hoc signed builds are asked again after
every rebuild.

## Security design

* **No arbitrary execution.** Natural language is turned into **typed tool calls** that are validated against a schema
  (unknown tools, unknown or malformed arguments and control characters are rejected). No shell command is ever built from
  user text.
* **AppleScript receives data, never code.** Scripts are fixed text compiled into the app; user values travel as
  separate `osascript` arguments (`--` then argv), so a note titled `"; do shell script "rm -rf ~"` is just a string. A
  test suite compiles every script against the installed Music/Notes dictionaries and another one feeds hostile strings
  through real `osascript` to prove they stay data.
* **Destructive actions need confirmation.** Deleting a reminder, event, note or alarm always returns a single-use,
  expiring token (10 minutes) that names exactly what will be deleted; nothing runs until it is confirmed, and a token
  cannot be reused.
* **Ambiguity is never guessed.** If a name matches several lists, calendars, folders, events or notes, Jarvis asks
  which one instead of picking.
* **Duplicates are suppressed.** An identical creation repeated within a few seconds (a double Return, a script retry)
  runs once and says so.
* **Verification before “done”.** Every result is read back (the reminder is re-fetched by its identifier, the note is
  re-read, the playback state is queried…) and is reported as *verified*, *unverified* (with the reason) or *not
  applicable*. A mocked or unverifiable effect is never reported as verified.
* **Local only.** The control socket is a Unix-domain socket in your user folder with mode `0600`; the server also
  checks the peer's user id. There is no network listener, no telemetry and no cloud service.
* **Private data.** History is a JSON file with mode `0600` in `~/Library/Application Support/JarvisAppleIntegrations/`
  (switchable off, clearable); logs use `os.Logger` with private interpolation, so titles, notes and commands never appear
  in plain text in system logs. Any API key for an optional AI interpreter belongs in the macOS Keychain
  (`KeychainSecretStore`), never in settings or files.
* **No third-party runtime dependencies.** Only Apple frameworks.
