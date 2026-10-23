# Local control channel (IPC)

Other programs on the same Mac — the wider Jarvis assistant, a script, a future voice module — can send commands to the
running **Jarvis Apple Integrations** app and get real, verified results back. Everything goes through the *same* Action
Engine as the chat window, so the same validation, permission checks, confirmations and duplicate protection apply.

* **Transport:** a Unix-domain stream socket at
  `~/Library/Application Support/JarvisAppleIntegrations/jarvis.sock`
  (the file is mode `0600` inside a `0700` folder; the server also checks that the connecting process runs as the same
  user). There is no network port. If your user name is so long that the path would exceed the 104-byte socket limit, the
  socket moves to `/tmp/jarvis-apple-<uid>.sock`.
* **Framing:** newline-delimited JSON — one JSON object per line in each direction, UTF-8, at most 1 MiB per line.
  A connection can carry any number of requests; they are answered in order. Closing the connection cancels the request
  that is running.
* **Switch:** Settings ▸ Advanced ▸ *Local control channel* (on by default). The app must be running.

## Requests

`type` is optional: it is inferred (`tool` when a `tool` is present, `resolve` when a `token` is present, otherwise
`command`).

| `type` | Fields | Purpose |
| --- | --- | --- |
| `command` | `command` (text), `language` (`en`/`es`, optional), `session`, `allow_duplicate` | Interpret and run natural language. |
| `tool` | `tool` (name), `arguments` (object), `language`, `allow_duplicate` | Run one structured tool call without interpretation. |
| `resolve` | `token`, `decision` (`confirm`/`cancel`/`choose`), `index` (0-based, for `choose`) | Answer a pending confirmation or clarification. |
| `tools` | – | The schema of every tool (see [TOOLS.md](TOOLS.md)). |
| `status` | – | Availability and permission state of each integration. |
| `ping` | – | Liveness and protocol version. |

Every request may carry an `id` (any string); it is echoed in the response.

`session` scopes plain-text replies such as “yes”, “cancel” or “2”: by default each connection is its own session, so
`{"command":"yes"}` on the same connection answers the question that connection's previous command raised.

### Example

```json
{"command":"Add buy milk to my Shopping reminders list","language":"en"}
```

## Responses

```json
{
  "success": true,
  "status": "completed",
  "tool": "reminders.create",
  "message": "…human-readable text in the user's language…",
  "data": { "…": "…structured result with real identifiers…" },
  "results": [ { "…one entry per executed step…" } ],
  "language": "en",
  "interpreter": "deterministic",
  "duration_ms": 112,
  "id": "your-id-if-you-sent-one"
}
```

* `success` is `true` only when every step completed (or the command was answered conversationally). It is never `true`
  for something Jarvis could not do.
* `status` is one of `completed`, `partial`, `failed`, `permission_required`, `needs_confirmation`,
  `needs_clarification`, `setup_required`, `unavailable`, `unsupported`, `duplicate`, `cancelled`, `reply`,
  `unrecognized`, or the protocol-level `invalid_request`.
* For a one-step command `tool` and `data` mirror the only result; for several steps they are `null` and `results` holds
  one entry per step. Each result has its own `status`, `message`, `data`, `error_code`, `assumptions`, `warnings` and a
  `verification` object (`{"state":"verified","detail":…}`, `{"state":"unverified","detail":…}` or
  `{"state":"not_applicable"}`).
* `needs_confirmation` / `needs_clarification` results carry a `confirmation` / `clarification` with a single-use
  `token` (valid for 10 minutes) to send back in a `resolve` request.

### Real exchanges

The following were captured from a running build (output shortened):

```text
>> {"type":"ping"}
<< {"data":{"app":"Jarvis Apple Integrations","protocol":1,"version":"1.0.0"},"message":"pong","results":[],"status":"ok","success":true,"tool":null}

>> {"command":"pausa la música","language":"es","id":"req-7"}
<< {"data":{"player_state":"not_running"},"id":"req-7","language":"es","message":"Música no está abierta, así que no hay nada sonando.",
    "results":[{"status":"completed","tool":"music.pause","verification":{"detail":"Música no está abierta.","state":"verified"},…}],
    "status":"completed","success":true,"tool":"music.pause"}

>> {"command":"pon una alarma a las 7:30","language":"es"}        # the Clock shortcuts are not built yet
<< {"success":false,"status":"setup_required","message":"Todavía no puedo crear alarmas. Esto necesita el Atajo “Jarvis Create Alarm”, …",
    "results":[{"error_code":"setup_required","assumptions":["No indicaste AM/PM, así que usé las 7:30 AM"],…}],…}

>> this is not json
<< {"success":false,"status":"invalid_request","message":"The request is not a valid Jarvis request: send one JSON object per line, …",…}

>> {"type":"resolve","token":"nope","decision":"confirm"}
<< {"success":false,"status":"failed","message":"Esa solicitud expiró o ya se atendió.",…}
```

## Confirmation flow (deleting something)

The shape of the exchange (illustrative: the wording of the messages varies with the language and the item):

```text
>> {"command":"delete my Old Plans note","language":"en"}
<< {"success":false,"status":"needs_confirmation","message":"Delete the note “Old Plans”? …",
    "results":[{"status":"needs_confirmation","confirmation":{"token":"K7Q2…","destructive":true,"prompt":"…"}}]}

>> {"type":"resolve","token":"K7Q2…","decision":"confirm"}
<< {"success":true,"status":"completed","message":"Deleted the note “Old Plans”.","results":[{…"verification":{"state":"verified",…}}]}
```

A token works once; sending it again, or after it expired, is answered with `failed`.
A `needs_clarification` result lists `options`; answer with `{"type":"resolve","token":"…","decision":"choose","index":1}`.

## From a shell

```bash
SOCK="$HOME/Library/Application Support/JarvisAppleIntegrations/jarvis.sock"

printf '%s\n' '{"command":"What is on my calendar tomorrow?","language":"en"}' | nc -U "$SOCK"
```

## `jarvisctl`

The app bundle contains a small command-line client at
`Jarvis Apple Integrations.app/Contents/Helpers/jarvisctl` (Settings ▸ Advanced shows the exact path and copies an
example):

```bash
CTL="/Applications/Jarvis Apple Integrations.app/Contents/Helpers/jarvisctl"

"$CTL" "Add buy milk to my Shopping reminders list"
"$CTL" --language es "Pon mi lista Study"
"$CTL" --tool reminders.create --args '{"title":"Buy milk","list":"Shopping"}'
"$CTL" --confirm TOKEN        # or --cancel TOKEN, or --choose TOKEN 1
"$CTL" --tools                # every tool schema
"$CTL" --status               # availability and permissions of each integration
"$CTL" --json "…"             # print the raw JSON response
```

Exit codes: `0` the request succeeded · `1` Jarvis answered but the action did not complete (the reason is printed) ·
`2` Jarvis could not be reached (is the app running?).

## Writing a client

* Open the socket, write one line, read one line. Keep the connection open to send several requests.
* Always read `success` and `status`; never assume a created item exists unless `verification.state` is `verified`.
* Handle `needs_confirmation`, `needs_clarification` and `permission_required`: they are normal outcomes, not errors.
* Do not retry a failed *creation* blindly: identical creations within a few seconds are suppressed as duplicates
  (`status: duplicate`) unless you send `"allow_duplicate": true`.
* Python reference client in 10 lines:

```python
import json, os, socket
path = os.path.expanduser("~/Library/Application Support/JarvisAppleIntegrations/jarvis.sock")
with socket.socket(socket.AF_UNIX) as s:
    s.connect(path)
    f = s.makefile("rwb")
    f.write(json.dumps({"command": "Pause the music", "language": "en"}).encode() + b"\n"); f.flush()
    print(json.loads(f.readline()))
```
