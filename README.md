# Jarvis Apple Integrations

A native **macOS app** that controls **Apple Music, Reminders, Notes, Calendar and Clock** from natural language, in
**English and Spanish** — including several actions in one sentence:

> *“Play my Chill playlist and remind me to study at 8 PM.”*  ·  *“Pon mi lista Chill y recuérdame estudiar a las 8 PM.”*

Every action is executed for real and **verified before Jarvis says it is done**: a reminder is re-read by its
identifier, a note is read back, playback state is queried. If something cannot be confirmed, Jarvis says so; if a
permission or a setup step is missing, it says exactly what to do. Nothing is faked and nothing is guessed when a name
is ambiguous.

* **Swift 6 / SwiftUI**, no third-party runtime dependencies, no cloud, no telemetry.
* **Reusable Action Engine** (no UI) with typed tool schemas, validation, permission checks, confirmations for
  deletions, duplicate protection, cancellation and history.
* **Works offline and without any AI** (deterministic EN/ES parser); an **AI interpreter can be plugged in** (Laya, a local
  model, any API) and can only ever produce validated tool calls.
* **Local control channel** (Unix socket + `jarvisctl`) so other programs can send commands and get structured results.
* Chat window, **menu bar** popover, **global shortcut** (⌃⌥Space), history with reuse, Settings, dark/light mode.

## Quick start

Requirements: **macOS 14+** (developed and tested on macOS 27.0.1 with Xcode 27.1), Xcode 16+ to build. XcodeGen is only
needed if you change `project.yml`.

```bash
git clone <this repository> && cd Apple-Integrations

scripts/build.sh Release            # → build/DerivedData/Build/Products/Release/Jarvis Apple Integrations.app
open "build/DerivedData/Build/Products/Release/Jarvis Apple Integrations.app"

scripts/install.sh                  # optional: copies the Release app into /Applications
```

Or open `JarvisAppleIntegrations.xcodeproj` in Xcode and run the **JarvisAppleIntegrations** scheme.

**Signing.** By default the app is signed ad-hoc so anyone can build it, but macOS then asks for permissions again after
every rebuild. To keep your permission grants, copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` (git-ignored)
and put your team id and `Apple Development` identity in it (`security find-identity -v -p codesigning`). The app uses the
Hardened Runtime and is **not** sandboxed (see [docs/PERMISSIONS.md](docs/PERMISSIONS.md) for why).

### First launch

1. Jarvis opens in the main window and adds a ✦ icon to the menu bar. **⌃⌥Space** shows it from anywhere.
2. Type a command, press **Return**. The first command that needs an Apple app makes macOS ask for permission (Music and
   Notes: *Automation*; Reminders and Calendar: *full access*). You can also press **Allow…** next to each integration
   in the sidebar or in **Settings ▸ Permissions**. Jarvis explains why before macOS asks, and works with whatever you
   allow.
3. **Alarms and timers** need a one-time setup (about two minutes): the Clock app has no scripting interface, so Jarvis
   uses a few small Shortcuts you create once. **Sidebar ▸ Clock** shows the exact steps and a ✓ for each shortcut that
   exists; they are also in [docs/SHORTCUTS_SETUP.md](docs/SHORTCUTS_SETUP.md). Until then Jarvis tells you it cannot
   create alarms — it never substitutes a reminder.

## Using it

| Where | How |
| --- | --- |
| **Chat** | Type, press **Return**. **Shift+Return** adds a line. **↑ / ↓** recall earlier commands. **Stop** cancels a running command. Buttons confirm, cancel or choose when Jarvis asks. |
| **Sidebar** | One page per integration: status, permissions (Allow / Open System Settings), example phrases, limitations. |
| **History** | Every command with its result; reuse in the input field or run again. Clear it any time (Settings ▸ Privacy can switch it off). |
| **Menu bar** | ✦ icon: command field, playback buttons, latest results. |
| **Global shortcut** | ⌃⌥Space (configurable in Settings ▸ General). No extra permission needed. |
| **Command line** | `jarvisctl "Add buy milk to my Shopping reminders list"` — see [docs/IPC.md](docs/IPC.md). |

Examples (see [docs/COMMANDS.md](docs/COMMANDS.md) for the full list):

```text
Play Bohemian Rhapsody on Apple Music          Pon mi lista de reproducción Estudio
Add buy milk to my Shopping reminders list     Recuérdame mañana a las 6 PM entregar mi tarea
Create a note called Project Ideas with the    Agenda una reunión con Daniel el viernes a las 3 PM por una hora
  following content: Build a robot             Pon una alarma a las 7:30 de la mañana
What's on my calendar tomorrow?                Mueve mi reunión del viernes a las 3 PM
```

## Documentation

| | |
| --- | --- |
| [docs/COMMANDS.md](docs/COMMANDS.md) | What you can say, per app, with limitations |
| [docs/TOOLS.md](docs/TOOLS.md) | Reference of all 39 tools (generated from the live registry) |
| [docs/PERMISSIONS.md](docs/PERMISSIONS.md) | Permissions, entitlements, `Info.plist` keys, security design |
| [docs/SHORTCUTS_SETUP.md](docs/SHORTCUTS_SETUP.md) | Exact manual steps for the Clock shortcuts |
| [docs/IPC.md](docs/IPC.md) | Local socket protocol and `jarvisctl` |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Pipeline, modules, how to add an integration or an AI interpreter |
| [docs/TESTING.md](docs/TESTING.md) | What is tested, how to run it, and what was verified on a real Mac vs. only with mocks |

## Build, test, project layout

```bash
scripts/build.sh [Debug|Release]    # xcodebuild with a short digest of errors/warnings
scripts/test.sh                     # swift test + xcodebuild test (470 tests, fake integrations)
scripts/live_tests.py               # real Apple apps; read-only by default (see docs/TESTING.md)
scripts/gen-tools-doc.py            # regenerates docs/TOOLS.md from the running app
xcodegen generate                   # regenerates the Xcode project from project.yml
```

```text
Package.swift        Swift package “JarvisKit”: JarvisCore · JarvisInterpreter · JarvisIntegrations · JarvisIPC · jarvisctl
Sources/             the engine, parser, integrations and IPC (≈ 12,900 lines)
App/                 the SwiftUI app: composition root, AppModel, views, menu bar, Settings, resources
Tests/               five test bundles (≈ 6,100 lines)
project.yml          XcodeGen spec → JarvisAppleIntegrations.xcodeproj
Config/              xcconfig files (signing overrides in the git-ignored Local.xcconfig)
scripts/             build, test, install, live tests, doc generation
docs/                documentation
```

## Known limitations

* **Clock** needs the one-time Shortcuts setup; repeating alarms, alarms on a later day, and timer labels are not
  possible through the Clock actions (Jarvis explains this instead of faking it).
* **Calendar invitations** cannot be sent or attendees added (Calendar's public API does not allow it); mentioned people
  are written in the event notes.
* **Repeating reminders** are created as one-time reminders (Jarvis says so).
* **Music** plays from your library only (the catalogue search needs MusicKit and a developer token); albums and artists
  play through a *Jarvis Queue* playlist.
* **Notes** with attachments or passwords are never edited (new notes work normally).
* The app is not notarized (no Developer ID certificate was available); signing is with your Apple Development identity.

See [docs/TESTING.md](docs/TESTING.md) for the honest list of what has and has not been verified on a real machine.
