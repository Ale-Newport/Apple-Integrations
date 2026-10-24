# Jarvis assistant upgrade — 24 October 2026

The existing Swift/SwiftUI application, local control channel and working Apple integrations are preserved. This
upgrade adds an iterative model agent and real, independently registered tools. The capability contract is the
registry, generated in [TOOLS.md](TOOLS.md). An unsupported action returns a limitation or setup requirement before
making a substitute change.

## Requirements and implementation

| Prompt area | Implemented behavior |
| --- | --- |
| Natural language and reasoning | Configurable OpenAI-compatible provider; native function calling, JSON adapter for older servers, dynamic discovery of a small relevant tool set, bounded observation/replanning loop. English/Spanish and mixed language, approximate entities, corrections and general conversation use the configured model. Simple local commands retain the deterministic offline fallback. No paid provider is required or enabled automatically. |
| Planning and recovery | Validate arguments locally, execute independent reads or one write, observe actual results, discard speculative dependent arguments and replan. Successful reads can be reused until a write changes state. Confirmation pauses the workflow. New instructions invalidate stale pending scope. Cancellation, timeouts, bounded rounds, duplicate suppression and uncertain-write quarantine preserve partial results. Unknown tools never become shell code. |
| Context and preferences | Bounded session context with actual tool results and stable IDs; reminder follow-ups update the previous object. Context can be disabled/cleared. Optional explicit aliases, default list/calendar/folder and weather location are local editable preferences, not silently learned personal facts. |
| Music | Unicode/token/fuzzy search of real library candidates; songs, albums, artists and playlists; verified playback IDs; playback, relative/absolute volume, shuffle/repeat, queue and current-track controls. Library filters use actual genre/year/duration/track number and local play counts. Create playlists, inspect membership and add verified tracks. Queue construction preserves existing user playlists. |
| Music catalog | Public Apple iTunes Search API for song/album/artist metadata, album track order and bounded artist releases, with actual store URLs. Storefront-specific, cached and rate limited. Catalog IDs are explicitly different from library IDs. Store links do not imply subscription playback. Promotional previews/artwork are not played or cached. |
| Reminders | List create/read/rename/delete, item create/search/read/update/complete/delete/move, notes, priorities, due dates, repeated rules with intervals/weekdays/count/end, verified readback and conservative IDs. List/date/section/parent instructions are separated from titles; quoted dictation is preserved. Multiple shopping items, exact duplicate candidates and confirmed batches for completion/deletion are supported. Changed batch snapshots require another review; failures report completed IDs. |
| Native Clock | Existing public Shortcuts bridge: create/read/enable/disable/delete alarms, start/cancel timers, with setup checks and available readback. Same-time ambiguity is rejected. Unsupported native edits/recurrence/sound/snooze return the actual limitation; approved custom Shortcuts are the extensible alternative. |
| Jarvis time management | Separate persistent notification timers: multiple labels, query, pause/resume/extend/cancel. Persisted stopwatch: start/status/pause/resume/laps/reset. Neither is represented as a native Clock alarm. |
| Notes | Approximate title/content search, read/create/append/update/rename/delete, folder creation/move, selected text replacement and confirmed merging with duplicate paragraph removal. Original HTML snapshots support restore and rollback. Locked notes/attachments and unsafe edits are protected. Summaries, correction and cross-app extraction use actual note reads plus the model. |
| Calendar | Read/search/create/edit/move/delete; recurring event creation; relative alerts, timezone and all-day fields with readback; conflict detection, overlap pairs and working-hour free slots honoring weekend preferences. Study sessions and agenda/Reminders combinations use the agent's verified intermediate results. Recurring changes affect only the selected occurrence; invitations are not sent. |
| Weather | Real Open-Meteo current, hourly and daily forecasts, up to seven days: temperature/feels-like/humidity/rain probability/wind/gusts/UV/sunrise/sunset. Actual country/city disambiguation and stable place IDs, default city, ten-minute bounded cache and one transient read retry. No GPS tracking or invented severe alerts. |
| Future conditions | Optional signed launch agent, private persisted one-shot rain checks, strict/at-least thresholds, actual place/date validation, leases, offline retry and expiry. launchd evaluates due jobs every 15 minutes with the foreground app closed. Notifications use stable IDs and cancellation removes pending delivery. Disabled/revoked permissions prevent notification submission. This is not continuous monitoring or a native Reminders item. |
| Mathematics | Safe local numeric grammar and unit/date conversion; symbolic derivatives, polynomial indefinite integrals, bounded adaptive definite integration, linear/quadratic equations, linear systems, matrix operations, descriptive statistics, normal/binomial probability and fixed-rate loan/savings calculations with explicit assumptions. No generated code/eval. Currency uses dated Frankfurter reference quotes rather than guessed live trading prices. |
| Knowledge and entertainment | Configured model for explanations, summaries, jokes, riddles, trivia, stories and chat games. Local secure randomness for coins/dice/numbers/choices; calculation tools for numeric results. Current claims require actual retrieved sources. |
| macOS | Installed/running application metadata; open/focus/graceful quit; system audio/mute with readback; battery/charging/storage/system information; public-driver brightness when available; display sleep; allowlisted Settings panes; confirmed URLs and clipboard reads, clipboard write/readback; confirmed ScreenCaptureKit screenshots with real TCC authorization. Focus uses an approved Shortcut. |
| Contacts | Public Contacts search by name/nickname, actual details and stable IDs. Confirmed create/update, preserve existing labelled addresses/phones, revalidate changed contacts and compare requested fields after save. Never guess communication addresses. |
| Mail | Public Mail search in inbox/sent/drafts, subject/sender/received/unread/attachment-name filters, actual message reading, real saved drafts/replies/forwards and approved-file attachments. Sending reviews actual sender/To/Cc/Bcc/body and readable attachments; changed bytes require reconfirmation. Acceptance by Mail is explicitly not delivery verification. |
| Messages | Public conversation/participant lookup and stable recipients. Drafts remain in the Jarvis session. Sending requires review of actual account/handle/text; drafts are consumed before an uncertain send to prevent blind repetition. Public APIs do not expose message history or delivery confirmation. |
| Files and Finder | Explicitly approved roots with canonical containment and symlink checks; bounded metadata search/list/read (UTF-8/PDF); create/copy/move/rename/Trash, exact SHA-256 duplicate groups and confirmed organization. No overwrite; large copies/moves require a fresh snapshot review. Safe ZIP validation/extraction, staged ZIP creation, local text/JSON/PDF-text and PNG/JPEG conversion. Open actual documents, folders or VS Code workspaces with installed apps. Executable content requires confirmation. |
| Browsers and research | Safari/Chrome public tab IDs/titles/URLs, fixed DOM text reads pinned to expected URLs, confirmed page opening. Authorized SearXNG JSON searches return actual source links/snippets. Page/email/note content is untrusted data, never authorization. No history-database scraping or arbitrary generated JavaScript. |
| Third-party extensibility | `AppIntegration` adds independent schemas, permissions, status and execution without rewriting the agent. Installed bundle IDs are discovered rather than guessed. Approved Shortcuts provide a reviewed bridge to installed app actions; file opening supports workspaces/vault folders. Dedicated service search/send adapters are not invented for unconfigured Slack/Notion/Spotify/WhatsApp accounts. Existing browser/LLM provider protocols remain extension points for Chrome/Laya. |
| Chat and history | Native chat with cumulative model text when streaming is supported, per-step progress/results, stop, explicit confirmations, follow-up context, searchable command history and optional saved conversation/tool-step reading. Settings expose providers, aliases, approved folders/workflows, permissions, scheduler setup and privacy erasure. |
| Reliability and control | Swift concurrency, serialized integration writes, bounded subprocess/network reads, cancellation, cache/rate limits, structured failures, stable IDs and real readback. Keychain credentials; no telemetry, private Apple databases/frameworks, TCC bypass or arbitrary model-generated shell. |

## Setup

1. Build/install the app using the main [README](../README.md). Keep the signed app at a stable location before enabling
   its optional agent. Developer signing preserves permission identity across builds; notarization is not configured.
2. In **Settings → Intelligence**, enable a model and enter its exact name and API base URL. For an installed Ollama
   model use `http://localhost:11434/v1`; compatible llama.cpp/MLX servers can use their own `/v1` endpoint. Remote URLs
   require HTTPS. Native function calling is recommended for capable models; JSON compatibility remains selectable.
   API keys go in Keychain. The connection test sends only synthetic text.
3. Model-enabled requests send your message, bounded recent context and tool-result excerpts to that endpoint. Context,
   aliases, command history and full conversation saving are independently controlled. There is no automatic model download.
4. Grant Automation separately for requested Apple apps and full EventKit access for Reminders/Calendar. Contacts and
   screen capture request their own macOS permissions when used. See [PERMISSIONS.md](PERMISSIONS.md).
5. **Settings → Integrations → Files**: choose only approved roots. A file outside them is inaccessible to file tools.
   **Workflows**: load installed Shortcuts, then explicitly approve trusted names. Every execution reviews its input.
   Native Clock setup is in [SHORTCUTS_SETUP.md](SHORTCUTS_SETUP.md).
6. For Focus, create/approve the configured **Jarvis Set Focus** Shortcut. It receives `enabled`, `mode`, `until` and
   must implement the requested mode/end time. Completion is an unverified Shortcut submission, not a private Focus query.
7. For current web research, configure a trusted SearXNG `/search` URL with JSON enabled on that server. No search
   server is silently selected. Safari/Chrome page reading separately requires the browser's **Allow JavaScript from
   Apple Events** setting; Jarvis does not enable it for you.
8. For future rain notifications, explicitly enable the signed agent in **Settings → Integrations**, approve any macOS
   Login Items & Extensions request, then press **Allow agent notifications**. Both the service and its notification
   authorization must exist before a condition is saved. The service is not registered during automated tests.

## Persistence and data sources

Private application support files hold capped command history, optional last 100 conversations, timers, stopwatch,
condition jobs and the last 30 original Notes snapshots. Notes snapshots have a 30-day restore window; expired entries
are pruned on access. Privacy settings erase history and Notes snapshots independently. Conversation storage excludes
raw tool payloads, API keys and confirmation tokens; user text and answers can still contain personal content.

Open-Meteo receives requested city/coordinates and supplies attributed actual forecasts. Its public endpoint has usage
and non-commercial service terms; commercial distribution needs an appropriate provider arrangement. WeatherKit was
investigated: this project has no configured WeatherKit entitlement/service account, so Open-Meteo is the working
alternative. No severe alert feed is configured. Apple catalog requests disclose the requested search/store country.
Frankfurter returns dated reference rates, not intraday executable exchange quotes. Research queries go only to the
configured search provider.

## Genuine platform and verification limits

- **Reminders sections, subtasks and manual order:** installed EventKit headers and the public Reminders scripting
  dictionary do not expose these writes. An Accessibility adapter was investigated; this execution environment has no
  AX authorization, so element-level behavior and failure detection cannot be validated reliably. No brittle keystroke
  automation or private storage workaround is shipped. Requests retain section/parent metadata and fail before creating
  flat substitutes. The strongest extensible alternative is an explicitly approved supported Shortcut, or manual Reminders UI.
- **Native Clock:** the current public Shortcut contract cannot reliably read/write all repeat/snooze/sound/edit fields.
  Future-dated one-off alarms beyond the next time-of-day occurrence are refused. Jarvis timers and stopwatch provide
  real separate time management. Custom app-supported Shortcuts can be approved without pretending to support absent actions.
- **Music:** catalog coverage varies by storefront; bounded release results do not prove a globally newest album.
  No MusicKit subscription entitlement/token is configured. There is no lyric index, semantic audio analysis or global
  popularity feed. Local play counts and real genre/year metadata are reported as such. Catalog links do not start playback.
- **Notes:** arbitrary rich text/attachments cannot be losslessly rewritten with the public scripting contract. Unsafe
  edits are refused; original HTML snapshots and verified rollback are available for supported edits. Merging does not
  delete the source notes implicitly.
- **Calendar:** observed free slots are not a guarantee of personal availability. Only the first recurring event is
  checked for conflicts during creation; arbitrary recurring-series edits and attendee invitations are not claimed.
- **Mail/Messages:** live submission and delivery are distinct. Unsupported/unreadable Mail attachments fail safely;
  inspect those drafts in Mail. Messages history is unavailable through its scripting API. Send tests use fakes.
- **System/hardware:** brightness can fail on drivers without the public IOKit parameter. Screen capture still requires
  TCC and macOS 14.4+. Display sleep is supported; native screen locking is not fabricated. Approved app-supported
  Shortcuts are the alternative for actions without an available public control surface.
- **Scheduling:** the agent is implemented, packaged and signed, with injected restart/offline/cancellation tests. Real
  launchd registration and notification delivery require user setup and have not been activated during this upgrade.
  Sleep/offline/Focus may delay or silence delivery; jobs expire instead of producing misleading late alerts.
- **Reasoning:** model quality governs open-ended understanding; no finite corpus proves every sentence. Retrieved-data
  framing, typed tool validation, confirmations and limited execution reduce prompt-injection exposure, not prove immunity.
- **Math:** symbolic derivatives and polynomial antiderivatives are supported, not a general-purpose CAS. Nonlinear or
  higher-degree equation solving and non-polynomial indefinite integrals return a limitation. All financial formulas
  expose fixed-rate assumptions and are computations, not personalized financial advice.

See [TESTING.md](TESTING.md) for exact evidence and the distinction between real OS checks and application-data mocks.

## Public references

- [OpenAI function calling](https://developers.openai.com/api/docs/guides/function-calling),
  [Chat streaming](https://developers.openai.com/api/reference/resources/chat/subresources/completions/streaming-events),
  [Ollama compatibility](https://docs.ollama.com/openai).
- [Apple iTunes Search API](https://performance-partners.apple.com/search-api),
  [WeatherKit](https://developer.apple.com/weatherkit/),
  [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice).
- [Open-Meteo forecast](https://open-meteo.com/en/docs), [geocoding](https://open-meteo.com/en/docs/geocoding-api),
  [terms](https://open-meteo.com/en/terms), [Frankfurter](https://frankfurter.dev/),
  [SearXNG search API](https://docs.searxng.org/dev/search_api.html).
