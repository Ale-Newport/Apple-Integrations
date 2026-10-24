# Testing

This page separates **three kinds of evidence**, because they are not equally strong:

1. **Automated tests** — fast, repeatable, use *fake* integrations and in-memory backends. They never touch your data.
2. **Real checks on a real Mac** — the app, signed and running, talking to the real Apple apps with real permissions.
   Run by `scripts/live_tests.py` and by hand.
3. **Not verified** — things that need a human or hardware this was not run on. Listed explicitly.

> A mocked test is never counted as a real one. Where something was verified only with a fake, it says so.

## Upgrade verification — 24 October 2026

The current full Xcode result bundle reports **566 tests: 565 passed, 0 failed, 1 skipped**. The skip is the explicitly
opt-in live-model test. The Swift package contains 544 tests (112 core, 169 interpreter, 240 integrations, 23 IPC);
Xcode adds 22 app tests. Results are read from `xcresulttool get test-results summary`: parallel bundle logs can
interleave, so adjacent text counts are not attributed to a bundle. `scripts/build.sh` now reports the result-bundle totals.

Debug and universal Release builds succeed. Deep/strict code-signature verification passes for the app, embedded CLI and condition agent; the app and agent contain both arm64 and x86_64 slices. The launch-agent BundleProgram resolves inside the packaged app, and Debug rendering/self-test hooks are absent from Release. Application-data mutations use fake scripts/in-memory stores. Source
compilation has no diagnostics; Xcode can emit its standard AppIntents metadata-extraction notice. Real child-process,
Unix-socket, temporary-file ZIP/image/text safety and AppleScript compilation tests exercise OS facilities without
changing personal app data. Scripts compile against the installed Music, Notes, Mail, Messages, Safari and Chrome
dictionaries; successful compilation alone is not evidence that a live Apple application performed an action.

A separately enabled live-model test **passed in 8.548 seconds** against the already installed local
`qwen2.5:7b-instruct-q4_K_M` through Ollama. The user request contains no tool names:

> Busca mis recordatorios pendientes para mañana y crea una nota llamada Resumen con todos sus títulos.

The test supplies the full real tool catalog, but permits execution only against two in-memory fixtures. It verifies
that exactly one note is created and contains both actual synthetic reminder titles, then that the workflow completes.
No personal reminders/notes are read or modified, no model is downloaded, and user inference settings are not changed.
Reproduce explicitly with:

```bash
JARVIS_LIVE_MODEL=qwen2.5:7b-instruct-q4_K_M swift test --filter LiveAgentTests
```

New coverage includes native function schemas and real tool-message replay, unknown/truncated model response rejection,
SSE framing/cancellation and safe reply previews, recurrence roundtrips, fresh batch confirmations, contact creation
confirmation/readback and changed-contact review, recipient validation, Mail attachment byte changes, Messages uncertain
send deduplication, approved file scopes and symlinks, changed bulk-copy/organization plans, ZIP roundtrips/traversal,
catalog IDs/order/cache/rate limits, mathematical reference results/non-finite rejection, dated currency validation,
persisted condition restart/retry/expiry/cancellation/strict thresholds and stopwatch persistence.

Live public read checks: Apple's iTunes Search API returned actual Queen / Bohemian Rhapsody IDs and Apple store
links. Frankfurter returned a date later than the command's current day; the currency tool now rejects future/stale
reference dates, and **no current live conversion is claimed** from that response. Earlier actual Open-Meteo and IPC
checks (23 October: calculator 428.75, London seven-day forecast) remain historical evidence, not new live writes.

The updated Debug app launches in an isolated rendering mode: separate settings/history, IPC and global shortcut off,
schema-only fixture integrations that cannot execute real tools. It produced 38 PNGs in light/dark appearance. The
visible Intelligence and Privacy forms were inspected for layout/readability. Offscreen caching does not faithfully
capture native chat/sidebar layers (missing semantic text/material colors), so those images are **not** accepted as
complete chat visual verification. Native full-screen/manual interaction of the new features remains unverified.
The earlier UI automation bridge timed out; it is not counted as a successful check.

The optional condition agent is packaged and signed; restart/offline/notification behavior is tested with injected
services. It has **not** been registered with launchd or granted notification consent during this upgrade. Brightness,
screen capture, Contacts writes, Mail/Messages sends, native Clock custom Shortcuts and live reminder section/subtask
Accessibility operations have not been exercised against personal data. The upgrade's supported alternatives and
setup requirements are detailed in [UPGRADE.md](UPGRADE.md).

## 1 · Automated baseline (17 October 2026; 470 tests)

```bash
scripts/test.sh            # swift test + xcodebuild test
scripts/test.sh package    # only the Swift package suites (fastest)
scripts/test.sh xcode      # the full Xcode scheme
```

| Bundle | Tests | What it covers | Backends |
| --- | ---: | --- | --- |
| `JarvisCoreTests` | 100 | Action Engine pipeline, tool validation, permissions, confirmations (single-use, expiring, session-scoped), ambiguity, duplicate guard, concurrency across/within integrations, timeouts and cancellation, language resolution, history, settings, secrets, dates | fake integrations (`MockIntegration`) |
| `JarvisInterpreterTests` | 146 | the English/Spanish parser (every tool, multi-action sentences, hostile input, long input), the natural-date parser (DST, ambiguous hours, ranges, “next/this”), quoted titles, the pluggable AI interpreter and its validation | none (pure text → tool calls) |
| `JarvisIntegrationsTests` | 179 | Music, Notes, Reminders, Calendar, Clock and Contacts logic: verification after every effect, name matching, ambiguity, duplicates, conflicts, recurring events, locked/attachment notes, missing shortcuts; the AppleScript runner; **parser ↔ schema contract** over ~100 EN/ES phrases | fake scripts / in-memory EventKit / fake Shortcuts, **plus the real checks below** |
| `JarvisIPCTests` | 23 | the socket server and client: framing, many requests per connection, concurrent clients, malformed JSON, oversize lines, peer check, cancellation on disconnect, stale-socket handling | **real Unix sockets** in temporary folders |
| `JarvisAppTests` | 22 | `AppModel` (submit, double-Return, stop, confirmations answered once, history recall/reuse/delete, settings clamping, picker choices that never trigger a permission prompt), `AppShell` (Dock/menu-bar invariant, persistence) | stub integrations; compiled without `@main`, so no app launch |

Tests that are **not** mocked even though they run in the automated suite:

* `ScriptCompilationTests` compiles every AppleScript against the *installed* Music and Notes dictionaries (needs those apps installed).
* `AppleScriptRunnerTests` runs real `/usr/bin/osascript` and real child processes with harmless scripts to prove: user values arrive as data (including `"; do shell script "…"` payloads), timeouts kill the process, cancelling a task cancels the child, output is capped.
* IPC tests use real sockets (see above).

Everything is Swift 6 strict-concurrency clean: **no compiler warnings** in Debug or Release.

## 2 · Real checks on a real Mac

Environment: macOS 27.0.1, Xcode 27.1, Apple-silicon Mac, system languages Spanish/English, app signed with an Apple
Development identity (Hardened Runtime, not sandboxed). Verified on 17 October 2026.

### Build and packaging

| Check | Result |
| --- | --- |
| Debug and Release builds with `xcodebuild` | succeed, no warnings |
| Build from a **clean copy** of the sources (no local signing file, no caches) | succeeds (ad-hoc signed) |
| Release binary | universal (arm64 + x86_64), Hardened Runtime flag set, entitlements embedded, `jarvisctl` embedded and signed, debug-only hooks absent |
| Permission grants across builds | the Release build kept the grants given to the Debug build (same signing identity) |

### Running app

| Check | Result |
| --- | --- |
| App launches; window, Dock icon and ✦ menu-bar icon present | verified in a screenshot |
| Every screen — chat, history, six integration pages, five Settings tabs, the menu-bar popover — in **dark and light** | all 26 renders produced by an offscreen renderer; a representative set was reviewed by eye (the menu-bar popover render lacks the system's popover background, so it is not a faithful picture of it), plus real screenshots of the running main window |
| Idle resource use | 0 % CPU; no network sockets at all (only the Unix socket); `0700` folder, `0600` socket and history file |
| Local control channel | ping, status, tools, commands, tool calls, confirmations, malformed requests and an unknown token all answered correctly through the real socket and `jarvisctl` |
| The input field, with **real key events** delivered to the real SwiftUI text field (invisible window, no Accessibility needed) | typing, **Return runs**, empty Return does nothing, **Shift+Return** and **Option+Return** add a line without running, multi-line text runs as one command, **↑** recalls the last command (found and fixed: Shift+Return used to run the command) |

### macOS permissions (real prompts, answered by the user)

| Permission | Result |
| --- | --- |
| Reminders (EventKit) | the system prompt appeared and was granted. It appeared under the Hardened Runtime with only `com.apple.security.personal-information.calendars`, which confirms that entitlement is sufficient for Reminders. |
| Calendars (EventKit) | prompt shown and granted |
| Automation → Notes, Automation → Music | prompts shown and granted; the AppleScript child process (`osascript`) is attributed to the app and runs under that consent |
| Contacts, Clock (Shortcuts) | **not exercised** (see section 3) |

### Live integration checks (`scripts/live_tests.py`)

Read-only checks (default; change nothing) — **all pass**: reminder lists and pending reminders; calendars and the next
7 days of events; Notes folders and notes; Music playlists and *now playing* (silent); Clock correctly reports
`setup_required` instead of faking an alarm.

Natural language, **English and Spanish**, through the whole pipeline on real data (text → interpreter → engine → real
app → verified result), **language auto-detected** — all pass: pending reminders, tomorrow's calendar, “when is my next
meeting”, Notes folders, playlists, now playing, a two-app Spanish sentence (“Muestra mis recordatorios y qué tengo en mi
calendario mañana”), and reading a note whose title is in quotes (`lee mi nota "…"`, `read my note "…"`).

Write checks (`--write`; create only items titled “[Jarvis Test] …”) — **all pass**, each result verified by an
*independent read-back*, not by trusting the creating call:

| App | Verified for real |
| --- | --- |
| Reminders | create (verified) · found again by `reminders.list` · identical create is **suppressed as a duplicate** · complete (verified) · found in the completed list · mark done / not done by natural language (verified) · `reminders.delete` **asks first**, cancelling deletes nothing, the token cannot be reused |
| Calendar | create (verified) · found by `calendar.list_events` · identical create suppressed · `calendar.check_conflicts` sees it · rename + move (verified, and read back with the new title and time) · a **stale event id is refused**, not guessed · `calendar.delete_event` asks first, cancelling deletes nothing · creating an **overlapping** event asks (“would overlap with … Create it anyway?”) and, when cancelled, creates nothing |
| Notes | create (verified) · `notes.read` returns the text · `notes.append` (verified) · both paragraphs read back · search finds it · `notes.delete` asks first, cancelling deletes nothing |
| Engine | one sentence → three tools in three apps, all completed |

**Confirmed deletion — verified for real** (`--cleanup --yes`, run by the user, not by the author of the code): one reminder,
two calendar events and one note were each deleted through Jarvis's confirmation flow, and every one was **re-read afterwards
and found gone**. The note was moved to *Recently Deleted* (Notes' own safety net); reminders and events are removed for
good. Deleting a *recurring* event (only the chosen occurrence is removed) was not exercised on real data.

The live runs create a few “[Jarvis Test] …” items in the real apps. They are never deleted automatically:

```bash
scripts/live_tests.py --cleanup --dry-run   # only lists them
scripts/live_tests.py --cleanup --yes       # deletes them, confirming each one through Jarvis (starts the app if needed)
```

### Bugs this real-world testing found (and that are now fixed and covered by tests)

* Quoted titles next to a noun were not understood (`lee mi nota "Ideas"`, `cancel my "Dentist" appointment`),
  `append "…" to my note "Ideas"` produced a note called “my”, and `play "Hello" by "Adele"` left stray quote characters
  on both names.
* Everyday phrasings: `mark call mom done`, `marca como completado …`, `alarm at 7 tomorrow`, `an alarm for 7`,
  `apaga la alarma de las 7`, `cancel tomorrow's meeting`, `when is my next meeting`, `what's pending`, `find my note
  about …`, `new note: …`, `turn it down a bit`, `pon mi lista de ejercicio`, `gracias, ahora pon música`.
* “Not understood” replies came back in English on a Spanish Mac (the engine now falls back to the host's language when
  the text gives no hint).
* The local-channel error for malformed JSON embedded a locale-dependent system message.

## 3 · Not verified — needs a human or other hardware

| Not verified | Why | How to check |
| --- | --- | --- |
| **Music playback** (a track actually plays, then pauses) | it is audible; not run while the user was working | `scripts/live_tests.py --music-play "Song title"` |
| **Clock alarms and timers** | the shortcuts must be built by you in the Shortcuts app; they cannot be created or run programmatically. The steps in `SHORTCUTS_SETUP.md` were written from the Clock actions available on macOS 27 and are **unverified until built** | follow [SHORTCUTS_SETUP.md](SHORTCUTS_SETUP.md), then `jarvisctl "Set a timer for 1 minute"` |
| Deleting one occurrence of a **recurring** event | needs a recurring event in your calendar; non-recurring deletion is verified live (section 2) | try it on a recurring event you do not mind losing |
| **Contacts lookup** (optional feature) | needs the Contacts permission, which was not requested | enable it in Settings ▸ Integrations, then “Schedule a meeting with <contact> …” |
| **Global shortcut by physical key press** (⌃⌥Space), **menu-bar popover** interaction, **Launch at login**, clicking through Settings | need real input events / system login-items; registration itself reported no error, and the popover and Settings views were rendered and reviewed | press ⌃⌥Space; click the ✦ icon; toggle “Open at login” |
| Notes with **attachments** or **passwords**, **recurring** calendar events, reminders in **read-only** lists, accounts with the same list name | require specific data in your accounts | covered with fakes; try on your own data if you have such items |
| Intel Macs, older macOS (14–26), VoiceOver audit | the Release binary is universal and targets macOS 14, but it was run only on one Apple-silicon Mac with macOS 27 | — |
| Notarization / Gatekeeper on another Mac | no Developer ID certificate was available; the app is signed with a development identity | notarize with your Developer ID before distributing |
| A live configured model (local or remote) | the compatible transport and planning behavior are tested with scripted responses; no live model was configured during this run | configure Settings ▸ Intelligence and use Test connection |

## Developer-only helpers (Debug builds only)

Launch arguments to inspect screens and states without clicking (they are compiled out of Release builds):

```bash
APP="build/DerivedData/Build/Products/Debug/Jarvis Apple Integrations.app"
open -n "$APP" --args -JarvisScreen history                    # or: chat, music, reminders, notes, calendar, clock, contacts
open -n "$APP" --args -JarvisSubmit "help||pon una alarma a las 7:30"
open -n "$APP" --args -JarvisOpenSettings YES -pref.settingsTab permissions
open -g -n "$APP" --args -JarvisSnapshotDir /tmp/jarvis-ui     # renders every screen, dark and light, to PNG files offscreen
open -g -n "$APP" --args -JarvisSelfTestOutput /tmp/selftest.txt   # drives the input field with real key events
```
