# What you can say

Jarvis understands **English and Spanish** (and both in one sentence), in the chat window, the menu bar popover,
`jarvisctl` and the socket. This page lists the supported operations with example phrases that the automated contract
test turns into valid tool calls (see [TESTING.md](TESTING.md)); [TOOLS.md](TOOLS.md) is the exact, generated schema of
every operation.

General behaviour:

* **Say it your way.** Case, accents and filler (“please”, “por favor”, “could you…”) do not matter. A trailing period or
  question mark is fine.
* **Several actions in one command** work: *“Play my Chill playlist and remind me to study at 8 PM”*, *“Pon mi lista Chill
  y recuérdame estudiar a las 8 PM”*. Actions in different apps run at the same time; actions in the same app run in order,
  and if one fails the later ones for that app are skipped and reported.
* **Quote text you want kept verbatim**, especially titles and note content: *“Create a note called Project Ideas with the
  following content: …”*. Everything after “with the following content:” is treated as text, never as commands.
* **Dates and times** are understood in both languages: *tomorrow at 6 PM*, *next Monday*, *el viernes a las 3*, *in two
  hours*, *en 20 minutos*, *June 5*, *this weekend*. If a time has no AM/PM (“at 6”), Jarvis picks the most sensible
  reading, **tells you what it assumed** (“No AM/PM given, so I used 6:00 PM”), and you can correct it. “Morning”,
  “afternoon”, “evening” and “night” use the hours you set in Settings ▸ Integrations ▸ *Parts of the day*.
* **It never guesses between several matches.** If “Shopping” exists in two accounts, or “meeting” matches three
  events, Jarvis lists the options; answer with a button, a number (“2”), or a name (“the second one”, “la primera”).
* **Deleting always asks first**, naming exactly what will be deleted. Answer *yes / no*, *sí / no*, *confirm / cancel*, or use
  the buttons.
* **Results are verified.** Jarvis says “Done” only after reading the effect back; otherwise it says what it could not
  confirm.
* **Typing “help” / “ayuda”** shows examples.

## Phrasing tips

* **Put exact titles in quotes** when they contain words that look like commands or dates: *read my note “Plan for Friday”*,
  *cancel my “Dentist” appointment*, *lee mi nota «Ideas»*, *play “Hello” by “Adele”*. Quotes next to a word such as
  *note*, *event* or *cita* are understood as the title; the word itself is not part of it.
* **Several words after “content” belong to the note** only when they follow *“with the following content:”* or are quoted:
  *Create a note called Groceries with the following content: milk, eggs, bread*. Without that marker the words are read
  as part of the title.
* “*… on my calendar … called X*” can mean the event is called X **or** that the calendar is: say *“an event called X on
  my calendar”* (or *“una reunión llamada X”*) to be unambiguous.
* A generic noun with a date (“my Friday meeting”, “cancel tomorrow's meeting”) selects by the **date**: with one event
  that day Jarvis asks you to confirm that one; with several it lists them.
* Playing your **whole library** at once (“shuffle my library”) is not available; name a song, album, artist or playlist.

## Apple Music

Plays from **your library** (songs, albums, artists, playlists) and controls playback. Needs Automation permission for
Music.

| English | Español |
| --- | --- |
| Play Bohemian Rhapsody on Apple Music | Pon Bohemian Rhapsody en Apple Music |
| Play my Study playlist · shuffle my Chill playlist | Pon mi lista de reproducción Estudio |
| Play songs by Queen · play the album Abbey Road by The Beatles | Reproduce canciones de Shakira |
| Play Hello by Adele | |
| Pause the music · resume the music · stop the music | Pausa la música |
| Next song · previous song | Siguiente canción |
| Set the volume to 40 · turn it up · lower the volume by 25 · mute | Sube el volumen |
| What's playing? | ¿Qué suena? |
| List my playlists · do I have Thriller in my library | |

Notes: playback is reported as started only when the Music app confirms the player state. Albums and artists are played
through a playlist named *Jarvis Queue* (configurable; never touches your other playlists). The catalogue-wide Apple Music
search needs MusicKit and a developer token, so only your library is searched. Controls such as *pause* never launch
Music if it is not running.

## Reminders

Uses EventKit. Needs Reminders (full access).

| English | Español |
| --- | --- |
| Add buy milk to my Shopping reminders list | Agrega leche a mi lista de Compras |
| Remind me tomorrow at 6 PM to submit my assignment | Recuérdame mañana a las 6 PM entregar mi tarea |
| Remind me in two hours to stretch · remind me next Monday to pay rent | |
| Show my pending reminders · show completed reminders · what reminders do I have tomorrow | |
| Mark buy milk as done · mark buy milk as not done | Marca comprar leche como hecho |
| Reschedule the reminder call Mom to tomorrow at 5 pm · rename the reminder call Mom to call Grandma | |
| Delete the reminder call Mom | Elimina el recordatorio llamar a mamá |
| Create a reminders list called Groceries · show my reminder lists | |

Notes: a reminder with a time gets a real alert at that time; a date alone is an all-day reminder. If the list does not
exist, Jarvis asks (or you can say to create it). **Repeating reminders** (“every Monday…”) are created as a *one-time*
reminder and Jarvis tells you so. Lists with the same name in different accounts are never guessed.

## Notes

Uses Notes' scripting interface. Needs Automation permission for Notes.

| English | Español |
| --- | --- |
| Create a note called Project Ideas with the following content: Build a robot | Crea una nota llamada Ideas con el siguiente contenido: pintura |
| Create a note called Budget in the Work folder with the following content: rent | |
| Append this paragraph to my Project Ideas note: more · add buy eggs to my shopping note | |
| Read my Project Ideas note | Lee mi nota Ideas |
| Search my notes for budget · list my notes · show my notes folders | Busca en mis notas presupuesto |
| Replace the content of my Shopping note with: milk, eggs | |
| Take a note: pick up the dry cleaning | |
| Delete my Old Plans note | Elimina la nota Borrador |

Notes: new notes are written as HTML with a proper title; the note is read back to verify it. **Password-protected notes
cannot be read or changed, and notes that contain attachments are never rewritten** (Notes' scripting interface replaces
the whole body and could lose them); in those cases Jarvis offers to create a new note. Deleted notes go to *Recently
Deleted*. Folders with the same name in several accounts trigger a question.

## Calendar

Uses EventKit. Needs Calendars (full access).

| English | Español |
| --- | --- |
| What's on my calendar tomorrow? · show me my calendar events for next week · what do I have on Friday | ¿Qué tengo en mi calendario mañana? |
| Schedule a meeting with Daniel on Friday at 3 PM for one hour | Agenda una reunión con Daniel el viernes a las 3 PM por una hora |
| Create a lecture on Tuesday at 10 AM lasting two hours | Crea una clase el martes a las 10 AM de dos horas |
| Add Mom's birthday to my calendar on June 5 · schedule lunch with Ana tomorrow at 1 pm in my Personal calendar | |
| Move my meeting to 4 PM · move my Friday meeting to 3 PM · reschedule my dentist appointment to Monday at 10 | Mueve mi reunión a las 4 PM |
| Rename my meeting with Daniel to Project sync · change the location of my meeting with Daniel to Room 5 | |
| Cancel my meeting with Daniel on Friday | Elimina mi reunión del viernes |
| Am I free Friday at 3 pm? · list my calendars | |

Notes: events overlapping an existing one trigger a question (or a warning, or nothing, depending on Settings ▸
Calendar). An identical event that already exists is not created twice. **Recurring events:** a change or deletion affects
only the occurrence you meant. **Attendees:** Calendar's public API cannot send invitations or add attendees; people you
mention are written in the event's notes (and matched against Contacts if you turn that on). A date with no time creates
an all-day event.

## Clock: alarms and timers

Through Shortcuts actions of the Clock app, **after a one-time setup** — see [SHORTCUTS_SETUP.md](SHORTCUTS_SETUP.md).

| English | Español |
| --- | --- |
| Set an alarm for 7:30 tomorrow morning · wake me up at 6 | Pon una alarma a las 7:30 de la mañana · despiértame a las 6:45 |
| Show my alarms | |
| Turn off my 7:30 am alarm | |
| Delete my 7:30 alarm | |
| Set a timer for 10 minutes · start a 20 minute timer called Pasta | Pon un temporizador de 5 minutos |
| Cancel the timer | |

Notes: Jarvis never substitutes a Reminder for an alarm. A Clock alarm rings at the **next** occurrence of its time, so an
alarm for a later day (“at 7 on Friday”, asked on Monday) is refused with an explanation. **Repeating alarms are not
supported** (“every weekday”): Jarvis says so and suggests creating it in the Clock app. Without the optional *List
Alarms* / *Get Timer* shortcuts, alarms and timers are created but reported as **not verified**.

## Contacts (optional)

Off by default. When enabled in Settings ▸ Integrations, people you mention in an event (“meeting with Daniel”) are looked
up in Contacts and their name and email are added to the event notes. Needs the Contacts permission.

## When something goes wrong

| You see | Meaning | What to do |
| --- | --- | --- |
| *Permission needed* | macOS has not allowed it yet, or it was denied | Press **Allow…** / **Open System Settings** (Settings ▸ Permissions) |
| *Setup needed* | The Clock shortcuts are missing | Follow the steps shown (about two minutes, once) |
| *Which one?* | Several matches | Choose one |
| *Please confirm* | A deletion | Confirm or cancel |
| *Not understood* | The rules did not recognise it | Rephrase, or say “help” |
| *Skipped duplicate* | The same creation just ran | Say it again after a few seconds, or use *Run again* in History |
| ✓ **Verified** / ⚠︎ **Not verified** | Whether Jarvis could read the effect back | Not verified means “it ran, but I could not confirm”: check the app |
