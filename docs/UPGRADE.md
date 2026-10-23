# Intelligent assistant upgrade — 23 October 2026

This increment extends the existing native application and its real integrations. It does not recreate the app or
replace Apple data with simulations. The pre-existing local project was first preserved in Git, then the agent,
integrations and interface were upgraded in separate commits.

## Implemented

| Area | Behavior |
| --- | --- |
| Configurable inference | OpenAI-compatible Chat Completions transport, compatible with Ollama `/v1`, llama.cpp and hosted APIs; user supplies endpoint/model. Disabled by default. Remote HTTPS required; HTTP only on loopback. Keychain credentials; ephemeral sessions; redirects refused; cancellation, time and response-size limits. |
| Agent loop | Plan next batch → validate entire batch → permission check → execute → observe → replan. Independent reads can run concurrently; modifying batches contain one call. Eight rounds by default, bounded to 1–16. Unknown tools/arguments are rejected. Errors preserve partial results and stop further effects. |
| Confirmation and recovery | Single-use expiring confirmations pause agent workflows. Confirmation resumes the remaining work; cancellation preserves earlier completed steps. A new instruction invalidates unanswered confirmations and stops further effects from an older agent workflow in that session. Repeated writes are stopped; creation attempts with timeout, cancellation or failed verification are quarantined for ten minutes until explicit retry. |
| Context | Bounded in-memory context scoped to the chat/IPC session, with actual tool results and stable IDs. Offline reminder move/time/complete follow-ups; multiple possible reminders require clarification. Clearing the chat clears its context. No cross-session sharing. |
| Preferences | Optional explicit aliases, existing default lists/calendars/folders, default weather city, context toggle. Aliases can be edited/replaced/deleted in Intelligence settings; they are never silently learned. |
| Music | Unicode/token normalization plus bounded Damerau-Levenshtein matching on actual library candidates. Exact title/artist splits precede broader searches. Verified persistent IDs are used for playback. Album/artist collections are disambiguated. Shuffle/repeat settings are read back. Catalog-wide search, lyric recognition and popularity ranking are not claimed. |
| Reminders | Correct extraction from list-first instructions and section/subtask requests; comma-separated shopping items; quoted dictation kept together. Stable-ID editing, verified notes/priority, daily/weekly/monthly/yearly EventKit recurrence, list rename and confirmed list deletion. A changed reminder set requires fresh deletion confirmation. |
| Calendar | Free-slot search across busy events in selected calendars, local working hours and weekend preference; overlapping event pairs with actual identifiers. Existing create/edit/delete/conflict protections preserved. |
| Weather | Real Open-Meteo current conditions and seven-day daily forecasts. City geocoding, explicit selection for ambiguous cities, configured default city, temperature/feels-like/humidity/wind, rain probability, UV/sunrise/sunset in structured results. Ten-minute bounded cache and one retry for transient read errors. No guessed weather. Visible attribution. |
| Mathematics | Local numeric grammar for arithmetic, percentages, powers, functions, radians, aggregates and scientific notation. Length/mass/time/temperature/volume/speed conversions and calendar-day differences. No eval, shell, JavaScript or arbitrary NSExpression. Invalid/non-finite expressions fail. |
| Jarvis timers | Separate persistent timers backed by macOS notifications: create/list/pause/resume/extend/cancel, multiple labels, stable IDs, private atomic file storage and serialized mutations. Deadlines survive app restarts and macOS delivers scheduled notifications without an in-app polling loop. Clearly distinct from native Clock. |
| Interface | Intelligence settings, model connection test, credential controls, alias management, mode/context indicator, progressive step cards across agent rounds, stop controls and existing searchable history. |

## Configuration and permissions

1. Build and launch the app as described in the main README.
2. For advanced reasoning, open **Settings → Intelligence**, enable the model and set its API base URL and model name.
   Ollama: `http://localhost:11434/v1`; llama.cpp: use the compatible `/v1` endpoint of your server. Local models need
   no paid provider. A remote provider may require an API key, saved through **Save key** in Keychain.
3. **Test connection** sends only a synthetic connection test. Ordinary model requests send the current user message,
   bounded session history and tool result excerpts to the selected endpoint. Do not configure a provider you do not
   intend to share those data with. Model responses are parsed and validated locally.
4. Existing permissions remain: Automation for Music/Notes, full EventKit access for Reminders/Calendar, optional
   Contacts, and configured Shortcuts for native Clock operations. No TCC bypass or private database access is used.
5. Jarvis timers request macOS notification permission when first created. Focus, sleep, and notification settings can
   delay or silence delivery; these timers are not a replacement for guaranteed native Clock wake-up alarms.
6. Weather sends the requested city/coordinates to Open-Meteo only when requested. It does not request GPS/location
   permission. Open-Meteo's public endpoint has usage and non-commercial service terms; configure/extend the provider
   appropriately before commercial distribution.

## Verification evidence

`swift test` passes 501 tests; the full Xcode scheme adds 22 app tests (523 total). Debug and Release builds succeed.
The live app answered IPC ping, returned 428.75 for `17.5/100*2450`, returned a seven-day London forecast and exported
55 unique tool schemas. The native UI inspection bridge timed out; visual inspection of the new settings is not claimed.

Current automated runs are documented in [TESTING.md](TESTING.md). All application-data mutation tests use fake
integrations or in-memory EventKit stores. The suite also compiles every bundled Music/Notes AppleScript against the
installed public dictionaries; harmless process/socket tests use real OS facilities.

New tests cover the agent's dependency ordering, invalid/mixed batches, bounded replanning, duplicate writes,
permission failure, interrupted workflows, confirmation/resumption, corrected scopes, uncertain write outcomes,
session isolation/erasure, provider request shape, endpoint security, error propagation, untrusted-data framing,
bounded prompts, bilingual command corpus, reminder metadata, quoted content, real recurrence, list confirmations,
fuzzy music/disambiguation, safe numeric accuracy, weather disambiguation/cache/failure and timer persistence/concurrency.

A live public Open-Meteo query for London returned current conditions and seven forecast days. This verifies the
external API shape and availability separately from mocked weather tests. No personal reminders, notes, calendars,
contacts, playback or alarms were modified during this upgrade's verification. Earlier live Apple integration evidence
is retained and dated explicitly in TESTING.md; it is not evidence of new live write checks.

The model adapter is verified with a scripted transport. A live model requires a configured running local server or
remote account; none is bundled or silently enabled. Accuracy of advanced natural-language planning depends on that
model. Prompt framing, allowlisted tools and local validation reduce injection exposure; they cannot guarantee that
an arbitrary model will interpret every hostile document correctly. Destructive operations still require confirmation.

## Explicit limits

- **Reminders sections/subtasks/reordering:** EventKit does not expose a supported writing API. These requests are
  extracted correctly and rejected before creating flat substitutes. There is no Accessibility adapter or private
  framework/database workaround. Reminder recurrence supports simple daily/weekly/monthly/yearly intervals, not
  arbitrary calendar rules or holiday exceptions.
- **Native Clock:** remains the public Shortcuts bridge. Repeating alarms, arbitrary alarm edits, sounds and snooze
  cannot be claimed through the existing contract. Jarvis notification timers are explicitly separate.
- **Music:** plays the user's library. It cannot silently invent catalog matches, latest albums, lyrics, similarity,
  genre/decade or most-popular rankings when the required metadata/capability is absent. No MusicKit entitlement is
  configured. Fuzzy matching changes music selection only; destructive reminder/event resolution stays conservative.
- **WeatherKit:** investigated first. Apple's service requires Developer Program configuration and attribution; this
  repository has no WeatherKit service entitlement configured. The working alternative is Open-Meteo. No severe alert
  feed or hourly forecast is exposed by the current tool.
- **Scheduled weather conditions:** not implemented. The agent is explicitly instructed not to claim background
  monitoring. It can perform a one-time forecast check; Jarvis timers schedule notifications, not condition evaluation.
- **Mathematics:** numeric calculations and dimensional conversions only; no symbolic algebra, matrices, calculus
  engine or live currency rates. A model explanation is not evidence of a verified numerical computation.
- **Notes:** existing safe read/create/append/replace/search/delete behavior retained, with attachment/locked-note
  safeguards and rollback verification. Summaries and cross-app extraction require the configured model and actual
  note reads. No new folder-moving or lossless arbitrary rich-text editor is claimed.
- **Calendar:** free slots are based on observed busy calendar data, not inferred personal availability. Invitations,
  attendee writes and arbitrary recurring-series changes remain outside the supported API contract.
- No generic shell execution, Mail/message sending, Finder write adapter, browser automation, third-party app adapters,
  system Focus/brightness automation, streaming response UI, voice front-end or persistent workflow scheduler was added.
  The registry exposes what actually works; unsupported work is not reported as completed.

## Provider references

- [OpenAI Chat Completions API](https://developers.openai.com/api/reference/resources/chat): request/response compatibility.
- [Ollama OpenAI compatibility](https://docs.ollama.com/openai): local compatible endpoint.
- [Apple WeatherKit](https://developer.apple.com/weatherkit/): requirements, service configuration and attribution.
- [Open-Meteo Forecast API](https://open-meteo.com/en/docs) and [Geocoding API](https://open-meteo.com/en/docs/geocoding-api): requested variables and location resolution.
- [Open-Meteo terms](https://open-meteo.com/en/terms): attribution and service usage conditions.
