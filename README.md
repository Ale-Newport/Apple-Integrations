# Jarvis Apple Integrations

A native **macOS app** that controls **Apple Music, Reminders, Notes, Calendar and Clock**, with weather, calculations and persistent Jarvis timers from natural language, in
**English and Spanish** — including several actions in one sentence:

> *“Play my Chill playlist and remind me to study at 8 PM.”*  ·  *“Pon mi lista Chill y recuérdame estudiar a las 8 PM.”*

Every action is executed for real and **verified before Jarvis says it is done**: a reminder is re-read by its
identifier, a note is read back, playback state is queried. If something cannot be confirmed, Jarvis says so; if a
permission or a setup step is missing, it says exactly what to do. Nothing is faked and nothing is guessed when a name
is ambiguous.

* **Swift 6 / SwiftUI**, no third-party runtime dependencies, no telemetry. Local by default; optional configured model and weather requests use the network.
* **Reusable Action Engine** (no UI) with typed tool schemas, validation, permission checks, confirmations for
  deletions, duplicate protection, cancellation and history.
* **Works offline and without any AI** (deterministic EN/ES parser); enable the **configurable AI agent** (Ollama, llama.cpp or any OpenAI-compatible API) in Settings ▸ Intelligence for iterative workflows and contextual requests. Model proposals pass the same tool validation and permissions.
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
3. **Native Clock alarms and timers** need a one-time setup (about two minutes): the Clock app has no scripting interface, so Jarvis
   uses a few small Shortcuts you create once. **Sidebar ▸ Clock** shows the exact steps and a ✓ for each shortcut that
   exists; they are also in [docs/SHORTCUTS_SETUP.md](docs/SHORTCUTS_SETUP.md). Until then Jarvis tells you it cannot
   create alarms — it never substitutes a reminder.

## Intelligence upgrade (23 October 2026)

In **Settings ▸ Intelligence**, enable a model, enter its name and an API base URL, then test the connection.
For Ollama use `http://localhost:11434/v1`; llama.cpp's compatible server typically uses
`http://127.0.0.1:8080/v1`. Remote APIs require HTTPS. No model, account, key or paid service is bundled or enabled
by default. API keys are optional for local servers and are saved in macOS Keychain.

When enabled, the configured provider receives the current request, bounded recent session context and tool results.
The agent reads real app data, chooses a next batch, observes results and replans (eight rounds by default). Independent
reads may run concurrently; each modifying batch contains one action. Failures stop the workflow and preserve the
completed steps. Confirmations pause it and resume only after the user's decision. Retrieved notes and tool results
are explicitly untrusted data; model output never becomes code or shell commands.

Session context stays in memory and can be disabled or cleared. Explicit aliases are optional, editable local
preferences; Jarvis does not silently learn contacts or sensitive facts. Existing command history remains independently
controlled in Privacy settings.

New capabilities include verified fuzzy library music search, shuffle/repeat controls, daily/weekly/monthly/yearly
reminder recurrence, list-first reminder extraction, separate shopping items, conservative reminder follow-ups,
calendar free-slot/overlap analysis, seven-day Open-Meteo forecasts, numeric expressions and unit conversion.
**Jarvis timers** use persisted deadlines and macOS notifications, and can be listed, paused, resumed, extended or
cancelled. They remain separate from native Clock alarms; notification delivery depends on macOS Focus and sleep.

```text
En la lista Compra, añade comprar huevos
Añade comprar leche, huevos y pan a la compra
Pon Bohemian Rapsody
Quita el shuffle
Busca un hueco de dos horas para estudiar el viernes
¿Va a llover mañana en Londres?
Calcula el 17,5% de 2.450
Convierte 10 km a mi
Pon un temporizador de Jarvis de 25 minutos
```

Advanced examples require a configured capable model, such as reading reminders and creating a summary note, or
finding calendar conflicts and then saving the actual conflicts in Notes. Quality depends on the selected model;
the deterministic fallback supports common local commands, not arbitrary reasoning.

See [the upgrade report](docs/UPGRADE.md) for verification evidence, provider documentation, permissions and limitations.

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
| [docs/UPGRADE.md](docs/UPGRADE.md) | Intelligence upgrade, configuration, verified capabilities and explicit limits |
| [docs/TESTING.md](docs/TESTING.md) | What is tested, how to run it, and what was verified on a real Mac vs. only with mocks |

## Build, test, project layout

```bash
scripts/build.sh [Debug|Release]    # xcodebuild with a short digest of errors/warnings
scripts/test.sh                     # swift test + xcodebuild test (523 tests; app data uses fake integrations)
scripts/live_tests.py               # real Apple apps; read-only by default (see docs/TESTING.md)
scripts/gen-tools-doc.py            # regenerates docs/TOOLS.md from the running app
xcodegen generate                   # regenerates the Xcode project from project.yml
```

```text
Package.swift        Swift package “JarvisKit”: JarvisCore · JarvisInterpreter · JarvisIntegrations · JarvisIPC · jarvisctl
Sources/             the agent, interpreter, integrations and IPC
App/                 the SwiftUI app: composition root, AppModel, views, menu bar, Settings, resources
Tests/               five test bundles
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
* **Repeating reminders** support daily, weekly, monthly and yearly intervals through EventKit, with a first due date. Sections and subtasks are not exposed by the public API and return an explicit limitation before any creation.
* **Music** plays from your library only (the catalogue search needs MusicKit and a developer token); albums and artists
  play through a *Jarvis Queue* playlist.
* **Notes** with attachments or passwords are never edited (new notes work normally).
* The app is not notarized (no Developer ID certificate was available); signing is with your Apple Development identity.

See [docs/TESTING.md](docs/TESTING.md) for the honest list of what has and has not been verified on a real machine.
