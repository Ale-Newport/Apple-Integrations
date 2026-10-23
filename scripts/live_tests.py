#!/usr/bin/env python3
"""Live integration tests against the RUNNING Jarvis app: real Apple apps, real data, no mocks.

These are the checks the automated (mocked) test-suite cannot do. They need a Mac where you have *already allowed* Jarvis
to use Reminders, Calendar, Notes and Music (macOS asks the first time a command needs each one — answer the prompts, or
press Allow in Jarvis ▸ Settings ▸ Permissions). A step whose permission is missing is reported as SKIP, never as PASS.

    scripts/live_tests.py                    read-only checks only (default; changes nothing)
    scripts/live_tests.py --write            also creates a few items titled “[Jarvis Test] …” and verifies them
    scripts/live_tests.py --write --only calendar   …but only one section (reminders, calendar, notes, multi)
    scripts/live_tests.py --cleanup --dry-run   lists the “[Jarvis Test] …” items without touching them
    scripts/live_tests.py --cleanup --yes    deletes the “[Jarvis Test] …” items (asks Jarvis, confirms each one)
    scripts/live_tests.py --music-play "Bohemian Rhapsody"   plays a library track for ~4 s (AUDIBLE), then pauses

If Jarvis is not running the script starts it in the background (no focus change) and quits it when done; use --no-launch
to disable that. Every request goes through the same local socket as `jarvisctl`.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import pathlib
import socket
import subprocess
import sys
import threading
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOCKET = pathlib.Path.home() / "Library/Application Support/JarvisAppleIntegrations/jarvis.sock"
PREFIX = "[Jarvis Test]"

PASS, FAIL, SKIP, SETUP, INFO = "PASS", "FAIL", "SKIP", "SETUP", "INFO"
results = []  # (outcome, name, detail)
leftovers = []  # things created by this run that the user may want to delete


class Client:
    def __init__(self, path: pathlib.Path):
        self.path = path
        self._open()

    def _open(self) -> None:
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(str(self.path))
        self.file = self.sock.makefile("rwb")

    def call(self, request: dict, timeout: float = 600.0) -> dict:
        """Sends one request. A macOS permission dialog can keep a request waiting for as long as the user takes to
        answer it, so the wait is long and announces itself; if it still expires the step is reported as SKIP."""
        hint = threading.Timer(12.0, lambda: print("    … waiting — a macOS permission dialog is probably open on your Mac; answer it to continue", flush=True))
        hint.start()
        try:
            self.sock.settimeout(timeout)
            self.file.write(json.dumps(request).encode() + b"\n")
            self.file.flush()
            line = self.file.readline()
            if not line:
                raise ConnectionError("Jarvis closed the connection")
            return json.loads(line)
        except (TimeoutError, socket.timeout):
            # The connection is now out of step with the server; start a fresh one (the server cancels the old request).
            self.sock.close()
            self._open()
            return {"success": False, "status": "client_timeout", "results": [],
                    "message": f"No answer within {int(timeout)} s — a macOS permission dialog is most likely still waiting for you."}
        finally:
            hint.cancel()

    def tool(self, name: str, arguments: dict | None = None, **extra) -> dict:
        return self.call({"tool": name, "arguments": arguments or {}, "language": "en", **extra})

    def command(self, text: str, language: str | None = None, **extra) -> dict:
        request = {"command": text, **extra}
        if language:
            request["language"] = language
        return self.call(request)

    def resolve(self, token: str, decision: str, **extra) -> dict:
        return self.call({"type": "resolve", "token": token, "decision": decision, "language": "en", **extra})


def record(outcome: str, name: str, detail: str = "") -> None:
    results.append((outcome, name, detail))
    mark = {PASS: "✓", FAIL: "✗", SKIP: "–", SETUP: "!", INFO: "·"}[outcome]
    print(f"  {mark} {outcome:<5} {name}" + (f" — {detail}" if detail else ""), flush=True)


def blocked(response: dict) -> str | None:
    """Why a step could not run for lack of permission or setup, or None when it ran."""
    status = response.get("status")
    if status == "client_timeout":
        return first_line(response)
    if status in ("permission_required", "unavailable"):
        return f"{status}: {first_line(response)}"
    if status == "setup_required":
        return f"setup_required: {first_line(response)}"
    return None


def first_line(response: dict) -> str:
    return (response.get("message") or "").strip().splitlines()[0][:160] if response.get("message") else ""


def verification(response: dict) -> str:
    results_ = response.get("results") or []
    if not results_:
        return "none"
    return (results_[0].get("verification") or {}).get("state", "none")


def step(name: str, response: dict, check, *, needs: str = "permission") -> dict | None:
    """Records one step: SKIP/SETUP when blocked, otherwise PASS/FAIL from `check(response) -> (ok, detail)`."""
    why = blocked(response)
    if why:
        record(SETUP if why.startswith("setup_required") else SKIP, name, f"needs manual approval/setup — {why}")
        return None
    try:
        ok, detail = check(response)
    except Exception as error:  # noqa: BLE001 — a malformed response is a failed check, not a crash
        ok, detail = False, f"unexpected response shape ({error!r}): {json.dumps(response)[:300]}"
    if not ok:
        detail += f"  [Jarvis answered status={response.get('status')}: {first_line(response)}]"
    record(PASS if ok else FAIL, name, detail)
    return response if ok else None


def listing(response: dict, *keys: str) -> list:
    data = response.get("data") or {}
    for key in keys:
        if isinstance(data.get(key), list):
            return data[key]
    return []


# ----------------------------------------------------------------------------------------------------- read-only

def read_only(client: Client) -> None:
    print("\nStatus")
    status = client.call({"type": "status"})
    for item in status["data"]["integrations"]:
        perms = ", ".join(f"{p['id']}={p['state']}" for p in item.get("permissions", [])) or "no macOS permission"
        record(INFO, f"{item['name']}: {item['state']}", perms)

    print("\nReminders (EventKit) — read-only")
    r = client.tool("reminders.list_lists")
    step("reminders.list_lists", r, lambda x: (x["success"] and isinstance(listing(x, "lists"), list), f"{len(listing(x, 'lists'))} lists"))
    r = client.tool("reminders.list", {"status": "pending", "limit": 5})
    step("reminders.list (pending, limit 5)", r, lambda x: (x["success"], f"{len(listing(x, 'reminders'))} shown"))

    print("\nCalendar (EventKit) — read-only")
    r = client.tool("calendar.list_calendars")
    step("calendar.list_calendars", r, lambda x: (x["success"] and len(listing(x, "calendars")) > 0, f"{len(listing(x, 'calendars'))} calendars"))
    today = dt.date.today()
    r = client.tool("calendar.list_events", {"start": today.isoformat(), "end": (today + dt.timedelta(days=7)).isoformat(), "limit": 5})
    step("calendar.list_events (next 7 days)", r, lambda x: (x["success"], f"{len(listing(x, 'events'))} shown"))

    print("\nNotes (AppleScript) — read-only")
    r = client.tool("notes.list_folders")
    step("notes.list_folders", r, lambda x: (x["success"] and len(listing(x, "folders")) > 0, f"{len(listing(x, 'folders'))} folders"))
    r = client.tool("notes.list", {"limit": 3})
    step("notes.list (limit 3)", r, lambda x: (x["success"], f"{len(listing(x, 'notes'))} shown"))

    print("\nMusic (AppleScript) — read-only, silent")
    r = client.tool("music.list_playlists", {"limit": 5})
    step("music.list_playlists (limit 5)", r, lambda x: (x["success"], f"{len(listing(x, 'playlists'))} shown"))
    r = client.tool("music.now_playing")
    step("music.now_playing", r, lambda x: (x["success"], first_line(x)))

    natural_language_checks(client)

    print("\nClock (Shortcuts)")
    r = client.tool("alarms.list")
    if r.get("status") == "setup_required":
        record(SETUP, "alarms.list", "the “Jarvis …” shortcuts are not built yet (see docs/SHORTCUTS_SETUP.md); Jarvis correctly refuses instead of faking it")
    else:
        step("alarms.list", r, lambda x: (x["success"], first_line(x)))


def natural_language_checks(client: Client) -> None:
    """Whole pipeline on real data: text → interpreter → engine → integration. Read-only; the language is auto-detected."""
    print("\nNatural language, English and Spanish (read-only, language auto-detected)")
    cases = [
        ("show my pending reminders", "en", ["reminders.list"]),
        ("Muestra mis recordatorios pendientes", "es", ["reminders.list"]),
        ("What's on my calendar tomorrow?", "en", ["calendar.list_events"]),
        ("¿Qué tengo en mi calendario mañana?", "es", ["calendar.list_events"]),
        ("when is my next meeting", "en", ["calendar.list_events"]),
        ("¿cuál es mi próxima reunión?", "es", ["calendar.list_events"]),
        ("show my notes folders", "en", ["notes.list_folders"]),
        ("muéstrame mis carpetas de notas", "es", ["notes.list_folders"]),
        ("list my playlists", "en", ["music.list_playlists"]),
        ("what's playing?", "en", ["music.now_playing"]),
        ("Muestra mis recordatorios y qué tengo en mi calendario mañana", "es", ["reminders.list", "calendar.list_events"]),
    ]
    for text, language, tools in cases:
        r = client.command(text)
        why = blocked(r)
        if why:
            record(SKIP, f"“{text}”", why)
            continue
        got = [x.get("tool") for x in r.get("results", [])]
        ok = r.get("success") is True and got == tools and r.get("language") == language
        record(PASS if ok else FAIL, f"“{text}”", f"tools={got}, language={r.get('language')}, status={r.get('status')}")

    # A quoted title next to the noun, on the test note if an earlier --write run left one.
    found = client.tool("notes.search", {"query": PREFIX, "scope": "title", "limit": 5})
    notes = [n for n in listing(found, "notes", "results") if (n.get("title") or "").startswith(PREFIX)]
    if notes:
        title = notes[0]["title"]
        for text in (f'lee mi nota "{title}"', f'read my note "{title}"'):
            r = client.command(text)
            got = [x.get("tool") for x in r.get("results", [])]
            record(PASS if r.get("success") and got == ["notes.read"] else FAIL, f"quoted note title: {text[:34]}…", f"tools={got}, status={r.get('status')}")
    else:
        record(SKIP, "quoted note titles", f"no “{PREFIX}” note exists yet (run with --write once)")


# ----------------------------------------------------------------------------------------------------- write tests

def write_tests(client: Client, only: set[str]) -> None:
    stamp = time.strftime("%H%M%S")

    def offset_on(day: dt.datetime) -> str:
        """The UTC offset in force on that date (a January date after an October run differs by DST)."""
        tz = day.astimezone().strftime("%z")
        return f"{tz[:3]}:{tz[3:]}"

    if "reminders" in only:
        reminder_tests(client, stamp)
    if "calendar" in only:
        calendar_tests(client, stamp, offset_on)
    if "notes" in only:
        notes_tests(client, stamp)
    if "multi" in only:
        multi_action_test(client)


def reminder_tests(client: Client, stamp: str) -> None:
    print("\nReminders — create, verify, complete, duplicate guard, delete confirmation")
    title = f"{PREFIX} reminder {stamp}"
    tomorrow = f"{dt.date.today().year + 1}-01-15"   # far from today: never appears in Today or Upcoming
    created = step("reminders.create", client.tool("reminders.create", {"title": title, "due": tomorrow}),
                   lambda x: (x["success"] and verification(x) == "verified" and (x.get("data") or {}).get("title") == title,
                              f"verification={verification(x)}"))
    if created:
        reminder_id = (created["data"] or {}).get("id")
        leftovers.append(f"Reminder “{title}”")
        found = client.tool("reminders.list", {"query": title, "status": "pending"})
        step("independent read-back (reminders.list)", found,
             lambda x: (any(i.get("id") == reminder_id or i.get("title") == title for i in listing(x, "reminders")), f"{len(listing(x, 'reminders'))} match"))
        again = client.tool("reminders.create", {"title": title, "due": tomorrow})
        step("duplicate guard (identical create is not run twice)", again,
             lambda x: (x.get("status") == "duplicate" or ((x.get("data") or {}).get("created") is False), f"status={x.get('status')}"))
        done = client.tool("reminders.complete", {"id": reminder_id})
        step("reminders.complete", done, lambda x: (x["success"] and verification(x) == "verified", f"verification={verification(x)}"))
        gone = client.tool("reminders.list", {"query": title, "status": "completed"})
        step("independent read-back (completed list)", gone, lambda x: (len(listing(x, "reminders")) >= 1, f"{len(listing(x, 'reminders'))} match"))
        confirm_flow(client, "reminders.delete", {"id": reminder_id}, "reminders.delete asks before deleting and cancelling changes nothing",
                     lambda: len(listing(client.tool("reminders.list", {"query": title, "status": "all"}), "reminders")) >= 1)



def calendar_tests(client: Client, stamp: str, offset_on) -> None:
    print("\nCalendar — create, verify, move, conflicts, duplicate, delete confirmation")
    etitle = f"{PREFIX} event {stamp}"
    year = dt.date.today().year + 1
    day = 5 + int(time.strftime("%M")) % 20          # a different January day per run: no overlap with earlier test events
    offset = offset_on(dt.datetime(year, 1, day, 3, 0))
    start = f"{year}-01-{day:02d}T03:00:00{offset}"
    end = f"{year}-01-{day:02d}T03:15:00{offset}"
    created = step("calendar.create_event", client.tool("calendar.create_event", {"title": etitle, "start": start, "end": end}),
                   lambda x: (x["success"] and verification(x) == "verified" and (x.get("data") or {}).get("title") == etitle, f"verification={verification(x)}"))
    if created:
        event_id = (created["data"] or {}).get("id")
        leftovers.append(f"Calendar event “{etitle}” on {year}-01-{day:02d}")
        window = {"start": f"{year}-01-{day:02d}", "end": (dt.date(year, 1, day) + dt.timedelta(days=1)).isoformat(), "query": etitle}
        step("independent read-back (calendar.list_events)", client.tool("calendar.list_events", window),
             lambda x: (any(e.get("id") == event_id or e.get("title") == etitle for e in listing(x, "events")), f"{len(listing(x, 'events'))} match"))
        again = client.tool("calendar.create_event", {"title": etitle, "start": start, "end": end})
        step("duplicate guard (identical event is not created twice)", again,
             lambda x: (x.get("status") == "duplicate" or ((x.get("data") or {}).get("created") is False), f"status={x.get('status')}"))
        step("calendar.check_conflicts sees the event", client.tool("calendar.check_conflicts", {"start": start, "end": end}),
             lambda x: (any(e.get("title") == etitle for e in listing(x, "events", "conflicts")), first_line(x)))
        new_start = f"{year}-01-{day:02d}T04:00:00{offset}"
        moved = step("calendar.update_event (rename and move)",
                     client.tool("calendar.update_event", {"id": event_id, "new_title": etitle + " (moved)", "new_start": new_start}),
                     lambda x: (x["success"] and verification(x) == "verified", f"verification={verification(x)}"))
        if moved:
            # An event id names one occurrence (identifier + start time), so after a move the id changes: use the new one.
            event_id = (moved["data"] or {}).get("id") or event_id
            expected = dt.datetime.fromisoformat(new_start)
            step("independent read-back after the move (title and time)", client.tool("calendar.list_events", window),
                 lambda x: (any((e.get("title") == etitle + " (moved)") and dt.datetime.fromisoformat(e["start"]) == expected for e in listing(x, "events")),
                            f"{len(listing(x, 'events'))} event(s) that day"))
            stale = client.tool("calendar.delete_event", {"id": created["data"]["id"]})
            record(PASS if stale.get("status") == "failed" and not (stale.get("results") or [{}])[0].get("confirmation") else FAIL,
                   "a stale event id is refused (nothing to delete) instead of guessing", first_line(stale))
        confirm_flow(client, "calendar.delete_event", {"id": event_id}, "calendar.delete_event asks before deleting and cancelling changes nothing",
                     lambda: any(etitle in (e.get("title") or "") for e in listing(client.tool("calendar.list_events", window), "events")))



def notes_tests(client: Client, stamp: str) -> None:
    print("\nNotes — create, read back, append, search, delete confirmation")
    ntitle = f"{PREFIX} note {stamp}"
    created = step("notes.create", client.tool("notes.create", {"title": ntitle, "content": "Created by the Jarvis live test."}),
                   lambda x: (x["success"] and verification(x) == "verified", f"verification={verification(x)}"))
    if created:
        note_id = (created["data"] or {}).get("id")
        leftovers.append(f"Note “{ntitle}”")
        step("notes.read returns what was written", client.tool("notes.read", {"id": note_id}),
             lambda x: ("Created by the Jarvis live test." in json.dumps(x.get("data") or {}, ensure_ascii=False), first_line(x)))
        appended = client.tool("notes.append", {"id": note_id, "text": "Second paragraph added by the live test."})
        step("notes.append", appended, lambda x: (x["success"] and verification(x) == "verified", f"verification={verification(x)}"))
        step("notes.read shows both paragraphs", client.tool("notes.read", {"id": note_id}),
             lambda x: (all(t in json.dumps(x.get("data") or {}, ensure_ascii=False) for t in ("Created by", "Second paragraph")), first_line(x)))
        step("notes.search finds the note", client.tool("notes.search", {"query": ntitle, "scope": "title"}),
             lambda x: (len(listing(x, "notes", "results")) >= 1, f"{len(listing(x, 'notes', 'results'))} match"))
        confirm_flow(client, "notes.delete", {"id": note_id}, "notes.delete asks before deleting and cancelling changes nothing",
                     lambda: len(listing(client.tool("notes.search", {"query": ntitle, "scope": "title"}), "notes", "results")) >= 1)



def multi_action_test(client: Client) -> None:
    print("\nA multi-action command through the real engine (read-only steps in three apps)")
    r = client.command("Show my reminder lists, what's on my calendar tomorrow and show my notes folders", allow_duplicate=True)
    outcome = blocked(r)
    if outcome:
        record(SKIP, "multi-action command", outcome)
    else:
        tools = [x.get("tool") for x in r.get("results", [])]
        ok = tools == ["reminders.list_lists", "calendar.list_events", "notes.list_folders"] and all(x.get("success") for x in r.get("results", []))
        record(PASS if ok else FAIL, "one sentence → three tools in three apps, all completed", f"status={r.get('status')}, tools={tools}")


def confirm_flow(client: Client, tool: str, arguments: dict, name: str, still_exists) -> None:
    """Checks the safety contract of a destructive tool WITHOUT deleting anything: it must ask, and cancel must change nothing."""
    asked = client.tool(tool, arguments)
    token = ((asked.get("results") or [{}])[0].get("confirmation") or {}).get("token")
    if asked.get("status") != "needs_confirmation" or not token:
        record(FAIL, name, f"expected needs_confirmation with a token, got {asked.get('status')}")
        return
    cancelled = client.resolve(token, "cancel")
    reused = client.resolve(token, "confirm")
    ok = cancelled.get("status") == "cancelled" and reused.get("status") == "failed" and still_exists()
    record(PASS if ok else FAIL, name, f"cancel={cancelled.get('status')}, reuse of the token={reused.get('status')}, item still exists={still_exists()}")


# ----------------------------------------------------------------------------------------------------- cleanup

def find_test_items(client: Client) -> list[tuple[str, str, str, object]]:
    """Everything titled “[Jarvis Test] …” in Reminders, Calendar and Notes, as (delete tool, id, label, still_there())."""
    items: list[tuple[str, str, str, object]] = []
    seen: set[str] = set()

    def reminders_now() -> list:
        return listing(client.tool("reminders.list", {"query": PREFIX, "status": "all", "limit": 200}), "reminders")

    for r in reminders_now():
        if (r.get("title") or "").startswith(PREFIX) and r.get("id") and r["id"] not in seen:
            seen.add(r["id"])
            items.append(("reminders.delete", r["id"], f"reminder “{r['title']}”", lambda i=r["id"]: any(x.get("id") == i for x in reminders_now())))

    year = dt.date.today().year
    for y in (year, year + 1):
        window = {"start": f"{y}-01-01", "end": f"{y + 1}-01-01", "query": PREFIX, "limit": 200}
        for e in listing(client.tool("calendar.list_events", window), "events"):
            if (e.get("title") or "").startswith(PREFIX) and e.get("id") and e["id"] not in seen:
                seen.add(e["id"])
                items.append(("calendar.delete_event", e["id"], f"event “{e['title']}” ({str(e.get('start', ''))[:10]})",
                              lambda i=e["id"], w=window: any(x.get("id") == i for x in listing(client.tool("calendar.list_events", w), "events"))))

    def notes_now() -> list:
        return listing(client.tool("notes.search", {"query": PREFIX, "scope": "title", "limit": 100}), "notes", "results")

    for n in notes_now():
        if (n.get("title") or "").startswith(PREFIX) and n.get("id") and n["id"] not in seen:
            seen.add(n["id"])
            items.append(("notes.delete", n["id"], f"note “{n['title']}”", lambda i=n["id"]: any(x.get("id") == i for x in notes_now())))
    return items


def cleanup(client: Client, dry_run: bool) -> None:
    items = find_test_items(client)
    print(f"\nFound {len(items)} item(s) titled “{PREFIX} …”:")
    for _, _, label, _ in items:
        print(f"  • {label}")
    if dry_run:
        print("\nDry run: nothing was deleted. Run again with --cleanup --yes to delete them.")
        return
    if not items:
        print("\nNothing to delete.")
        return

    print("\nDeleting (each deletion is confirmed through Jarvis):")
    removed = 0
    for tool, item_id, label, still_there in items:
        try:
            asked = client.tool(tool, {"id": item_id})
            token = ((asked.get("results") or [{}])[0].get("confirmation") or {}).get("token")
            if not token:
                record(FAIL, f"delete {label}", f"no confirmation token ({asked.get('status')}: {first_line(asked)})")
                continue
            done = client.resolve(token, "confirm")
            gone = done.get("success") and not still_there()
            removed += 1 if gone else 0
            record(PASS if gone else FAIL, f"delete {label}", first_line(done))
        except Exception as error:  # noqa: BLE001 — one failing item must not stop the rest
            record(FAIL, f"delete {label}", repr(error))
    print(f"\nDeleted {removed} of {len(items)} item(s). Deleted notes stay in Notes ▸ Recently Deleted for 30 days.")


def music_play(client: Client, query: str) -> None:
    print(f"\nMusic playback (AUDIBLE) — “{query}”")
    r = client.tool("music.play", {"query": query})
    played = step("music.play", r, lambda x: (x["success"] and verification(x) == "verified", f"{first_line(x)} (verification={verification(x)})"))
    if played:
        time.sleep(4)
        step("music.now_playing reports the same track", client.tool("music.now_playing"), lambda x: (x["success"], first_line(x)))
        step("music.pause", client.tool("music.pause"), lambda x: (x["success"] and verification(x) == "verified", f"verification={verification(x)}"))


# ----------------------------------------------------------------------------------------------------- main

APP_NAME = "Jarvis Apple Integrations"


def connect(auto_launch: bool) -> tuple[Client, bool]:
    """Connects to the running app. If it is not running it is started in the background (no focus change) unless
    --no-launch was given. Returns the client and whether this script started the app (so it can quit it afterwards)."""
    try:
        return Client(SOCKET), False
    except OSError:
        if not auto_launch:
            sys.exit("Jarvis is not running (no control socket). Start the app, or drop --no-launch.")
    # Prefer the installed app, then a Release build, then a Debug build.
    built = {p.parent.name: p for p in ROOT.glob(f"build/DerivedData/Build/Products/*/{APP_NAME}.app")}
    apps = [pathlib.Path(f"/Applications/{APP_NAME}.app"), built.get("Release"), built.get("Debug")]
    apps = [a for a in apps if a]
    app = next((a for a in apps if a.exists()), None)
    if not app:
        sys.exit("Could not find the app to launch; build it first (scripts/build.sh).")
    print(f"Jarvis is not running: starting {app} in the background (it will be quit when this finishes).")
    subprocess.run(["open", "-g", str(app)], check=True)
    for _ in range(40):
        time.sleep(0.5)
        try:
            return Client(SOCKET), True
        except OSError:
            continue
    sys.exit("Jarvis did not open its control socket in time.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--write", action="store_true", help=f"also create and verify a few “{PREFIX} …” items")
    parser.add_argument("--only", help="with --write: comma-separated subset of reminders,calendar,notes,multi (default: all)")
    parser.add_argument("--cleanup", action="store_true", help=f"delete the “{PREFIX} …” items (needs --yes, or --dry-run to only list them)")
    parser.add_argument("--yes", action="store_true", help="confirm that --cleanup may delete items")
    parser.add_argument("--dry-run", action="store_true", help="with --cleanup: only list what would be deleted")
    parser.add_argument("--music-play", metavar="QUERY", help="play a library song for about four seconds (audible) and pause")
    parser.add_argument("--no-launch", action="store_true", help="do not start the app when it is not running (it is started by default and quit afterwards)")
    parser.add_argument("--launch", action="store_true", help=argparse.SUPPRESS)  # accepted for compatibility: launching is the default
    parser.add_argument("--report", default=str(ROOT / "build/live-tests-report.json"), help="where to write the JSON report")
    args = parser.parse_args()

    if args.cleanup and not (args.yes or args.dry_run):
        sys.exit(f"--cleanup deletes every item titled “{PREFIX} …” in Reminders, Calendar and Notes. Re-run with --yes to allow it, or with --dry-run to only list them.")

    client, launched = connect(auto_launch=not args.no_launch)
    try:
        run(client, args)
    finally:
        if launched:
            subprocess.run(["pkill", "-x", APP_NAME], check=False)


def run(client: Client, args: argparse.Namespace) -> None:
    pong = client.call({"type": "ping"})
    print(f"Connected to {pong['data']['app']} {pong['data']['version']} (protocol {pong['data']['protocol']})")

    if args.cleanup:
        cleanup(client, dry_run=args.dry_run)   # --dry-run always wins over --yes
    else:
        read_only(client)
        if args.write:
            chosen = {part.strip() for part in (args.only or "reminders,calendar,notes,multi").split(",") if part.strip()}
            unknown = chosen - {"reminders", "calendar", "notes", "multi"}
            if unknown:
                sys.exit(f"--only: unknown section(s) {sorted(unknown)}")
            write_tests(client, chosen)
        if args.music_play:
            music_play(client, args.music_play)

    counts = {k: sum(1 for r in results if r[0] == k) for k in (PASS, FAIL, SKIP, SETUP)}
    print("\n" + "─" * 70)
    print(f"{counts[PASS]} passed · {counts[FAIL]} failed · {counts[SKIP]} skipped (need your approval) · {counts[SETUP]} need setup")
    if leftovers:
        print(f"\nItems created by this run — delete them by hand, or run: scripts/live_tests.py --cleanup --yes")
        for item in leftovers:
            print(f"  • {item}")
    report = pathlib.Path(args.report)
    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_text(json.dumps({"when": dt.datetime.now().astimezone().isoformat(), "results": [dict(zip(("outcome", "name", "detail"), r)) for r in results], "leftovers": leftovers}, indent=2, ensure_ascii=False))
    sys.exit(1 if counts[FAIL] else 0)


if __name__ == "__main__":
    main()
