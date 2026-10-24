# Clock shortcuts: one-time setup

The Clock app has **no AppleScript dictionary and no public framework**, so no app can create an alarm or a timer
directly. What macOS does expose are the Clock app's own *App Intents* (Add Alarm, Find Alarms, Toggle Alarm, Delete
Alarms, Start Timer, Cancel Timer, Get Current Timer…), which the **Shortcuts** app offers as actions.

Jarvis therefore runs small shortcuts that you build once and passes them a piece of JSON as input
(`shortcuts run "NAME" --input-path …`). Nothing is ever pretended: if a shortcut is missing, Jarvis says so and shows
these steps; it never creates a Reminder in place of an alarm.

You can see the same steps, in your language and with a ✓ next to each shortcut that already exists, in the app:
**sidebar ▸ Clock** (or **Settings ▸ Integrations ▸ Clock**). That screen is the canonical, always-current version.

> **Please read:** the steps below were written against the Clock actions available in the macOS 27 Shortcuts app.
> Apple sometimes renames actions or parameters between releases. The *contract* is what matters: a shortcut with the
> exact name, accepting the JSON input shown and doing the described Clock action, works regardless of how you build it.
> These shortcuts could not be created or run automatically while developing Jarvis, so this part is **unverified until
> you have built them** (see [TESTING.md](TESTING.md)).

## Which shortcuts do I need?

| Shortcut name | Needed for | Required? |
| --- | --- | --- |
| `Jarvis Create Alarm` | “Set an alarm for 7:30 tomorrow” | **yes** |
| `Jarvis Start Timer` | “Set a timer for 10 minutes” | **yes** |
| `Jarvis List Alarms` | listing alarms; **verifying** that an alarm now exists; finding an alarm to switch off/delete | recommended |
| `Jarvis Set Alarm Enabled` | “Turn off my 7:30 alarm” | optional |
| `Jarvis Delete Alarm` | “Delete my 7:30 alarm” (always confirmed first) | optional |
| `Jarvis Cancel Timer` | “Cancel the timer” | optional |
| `Jarvis Get Timer` | verifying that a timer is running | optional |

Without `Jarvis List Alarms` / `Jarvis Get Timer`, alarms and timers are still created, but Jarvis reports them as
**not verified** because it cannot read the result back. Names can be changed in **Settings ▸ Integrations ▸ Clock ▸
Shortcut names** if you prefer your own.

## How input reaches a shortcut

Jarvis writes the input as a small JSON file and runs `shortcuts run "NAME" --input-path FILE --output-path FILE`.
In the Shortcuts app that arrives as **Shortcut Input**. Start each shortcut that has input with
**Get Dictionary from Input**, then read keys with **Get Dictionary Value**.

## 1 · `Jarvis Create Alarm`

*Input:* `{"hour":7,"minute":30,"time":"07:30","iso":"2026-10-18T07:30:00","label":"Gym"}`
(`label` may be missing or empty.)

1. Open **Shortcuts** → **File ▸ New Shortcut**. Name it exactly `Jarvis Create Alarm`.
2. Add **Get Dictionary from Input** (Input: *Shortcut Input*).
3. Add **Get Dictionary Value** → *Get Value for* `iso` *in* Dictionary.
4. Add **Get Dates from Input** and give it the value from the previous step.
5. Add **Get Dictionary Value** → *Get Value for* `label` *in* Dictionary.
6. Add **Add Alarm** (the *Clock* action). Set **Time** to the date from step 4 and **Name** to the label value from step 5.
   Leave **Repeats** empty.
7. Add **Stop and Output** with the text `OK`.

Clock alarms ring at the *next* occurrence of a time of day. Jarvis therefore only sends an alarm whose date is that next
occurrence and refuses (explaining why) when you ask for one on a later day, rather than creating a misleading alarm.

## 2 · `Jarvis List Alarms`

*Input:* none.

1. New shortcut named exactly `Jarvis List Alarms`.
2. Add **Find Alarms** (Clock) with no filters.
3. Add **Repeat with Each** over the found alarms.
4. Inside it add a **Text** action containing: *Repeat Item ▸ Hours* `|` *Repeat Item ▸ Minutes* `|` *Repeat Item ▸ Enabled* `|`
   *Repeat Item ▸ Label* (tap each variable and pick the property; keep the `|` characters).
5. After **End Repeat** add **Combine Text** on the *Repeat Results* with separator **New Lines**.
6. Add **Stop and Output** with the combined text.

*Output:* one line per alarm — `hours|minutes|enabled|label`, for example `7|30|Yes|Gym`. Jarvis reads this to list your
alarms, to find the one you mean, and to verify that a new alarm really exists.

## 3 · `Jarvis Set Alarm Enabled`

*Input:* `{"hour":7,"minute":30,"state":"off"}` (`state` is `on` or `off`).

1. New shortcut named exactly `Jarvis Set Alarm Enabled`.
2. **Get Dictionary from Input**, then **Get Dictionary Value** for each of `hour`, `minute`, `state`.
3. Add **Find Alarms** with the filters *Hours is* (hour value) and *Minutes is* (minute value).
4. Add an **If**: *state value is* `on` → **Toggle Alarm** (Operation: Turn, State: On, Alarm: the found alarms).
   **Otherwise** → **Toggle Alarm** (Turn, State: Off, same alarms). **End If**.
5. Add **Stop and Output** with the text `OK`.

## 4 · `Jarvis Delete Alarm`

*Input:* `{"hour":7,"minute":30}`.

1. New shortcut named exactly `Jarvis Delete Alarm`.
2. **Get Dictionary from Input**, then **Get Dictionary Value** for `hour` and `minute`.
3. Add **Find Alarms** with the filters *Hours is* (hour value) and *Minutes is* (minute value).
4. Add **Delete Alarms** on the found alarms.
5. Add **Stop and Output** with the text `OK`.

Jarvis always asks for confirmation (showing which alarm) before it runs this shortcut.

## 5 · `Jarvis Start Timer`

*Input:* `{"seconds":600,"label":"Pasta"}`.

1. New shortcut named exactly `Jarvis Start Timer`.
2. **Get Dictionary from Input**, then **Get Dictionary Value** for `seconds`.
3. Add **Start Timer** (Clock). Set **Duration** to the seconds value and change its unit to **sec**.
4. Add **Stop and Output** with the text `OK`.

Timer labels are accepted but the Clock action cannot store them, so Jarvis only echoes the label back.

## 6 · `Jarvis Cancel Timer`

*Input:* none.

1. New shortcut named exactly `Jarvis Cancel Timer`.
2. Add **Cancel Timer** (Clock).
3. Add **Stop and Output** with the text `OK`.

## 7 · `Jarvis Get Timer`

*Input:* none.

1. New shortcut named exactly `Jarvis Get Timer`.
2. Add **Get Current Timer** (Clock) with *Mode* **Remaining Time**.
3. Add **Stop and Output** with that result.

*Output:* the remaining time as text. The shortcut may fail or output nothing when no timer is running; Jarvis treats that
as “no timer”.

## Finally

Run each shortcut once from the Shortcuts app and choose **Always Allow** if macOS asks for permission, so later runs
are silent. Then check **Settings ▸ Integrations ▸ Clock** (or the **Clock** page in the sidebar): every shortcut you
built shows a ✓ and the status dot turns green.

## Testing it

```bash
# Through Jarvis (the app must be running):
"/Applications/Jarvis Apple Integrations.app/Contents/Helpers/jarvisctl" "Set a timer for 1 minute"
"/Applications/Jarvis Apple Integrations.app/Contents/Helpers/jarvisctl" "Show my alarms"

# Or directly, to test a shortcut on its own:
echo '{"seconds":60,"label":"test"}' > /tmp/timer.json
shortcuts run "Jarvis Start Timer" --input-path /tmp/timer.json
```

## Limitations

* **Repeating alarms** are not supported. Jarvis creates one-time alarms only and says so (suggesting you create the
  repeating alarm in the Clock app) instead of silently creating a one-off alarm.
* **Alarms on a later day** are refused with an explanation, because a Clock alarm always rings at the *next*
  occurrence of its time (ask again closer to the day, or use a reminder if you only need a notification).
* **Timer labels** are accepted but cannot be stored by the Clock action; **changing** an existing alarm's time is not
  offered (delete it and create a new one).
* Shortcuts run in the background, so a macOS prompt (“Always Allow”) can appear the first time each one runs.

## Approved workflows and Focus

Settings → Integrations can load installed Shortcuts and explicitly approve individual names. This separate allowlist
is the extension surface for supported third-party actions and native Clock actions outside the built-in contract.
Jarvis never adds to this list from model output. Each `workflows.run` execution reviews the complete data input and
reports successful process exit as unverified external effects.

For Focus, create **Jarvis Set Focus** (or change the configured name), approve it, and use the public **Set Focus**
action available in your Shortcuts installation. Input is JSON:

```json
{"enabled":true,"mode":"Do Not Disturb","until":"2026-10-24T18:00:00+01:00"}
```

The Shortcut must select the requested Focus, honor `enabled`, and apply the supplied end date instead of leaving it
on indefinitely. Action names and selectable Focus parameters vary by macOS release; inspect them in Shortcuts.
Jarvis validates approval/installation, displays the input for confirmation and submits it; it cannot independently
query private Focus state. No Focus Shortcut was installed or executed during automated testing.

Persistent rain evaluation uses the separate signed condition agent documented in [UPGRADE.md](UPGRADE.md), rather
than a timer that pretends to evaluate a future condition. Jarvis stopwatch and notification timers also remain
separate from native Clock alarms.
