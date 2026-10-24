import JarvisCore
import JarvisInterpreter
import XCTest

@testable import JarvisIntegrations

/// The contract between the command interpreter and the integrations: every call the parser can emit must be
/// accepted by the real tool schemas, and the catalogue of tools must be complete and consistent.
final class ToolContractTests: XCTestCase {
    private let registry = ToolRegistry(integrations: IntegrationCatalog.makeDefault())

    func testEveryBuiltInToolIsRegisteredExactlyOnce() {
        let registered = registry.descriptors.map(\.name)
        XCTAssertEqual(Set(registered), Set(IntegrationCatalog.builtInToolNames))
        XCTAssertEqual(registered.count, Set(registered).count)
    }

    func testToolNamesAreNamespacedByTheirIntegration() {
        for descriptor in registry.descriptors {
            let namespace = descriptor.name.namespace
            let expected = descriptor.integration.rawValue
            let aliases: [String: String] = ["alarms": "clock", "timers": "clock"]
            XCTAssertEqual(aliases[namespace] ?? namespace, expected, "\(descriptor.name)")
        }
    }

    func testEveryDescriptorIsWellFormed() {
        for descriptor in registry.descriptors {
            XCTAssertFalse(descriptor.summary.isEmpty, "\(descriptor.name)")
            let names = descriptor.parameters.map(\.name)
            XCTAssertEqual(names.count, Set(names).count, "\(descriptor.name) has duplicate parameters")
            for constraint in descriptor.constraints {
                for name in constraint.parameterNames {
                    XCTAssertTrue(
                        names.contains(name), "\(descriptor.name): constraint mentions unknown parameter \(name)")
                }
            }
            for parameter in descriptor.parameters {
                XCTAssertFalse(parameter.summary.isEmpty, "\(descriptor.name).\(parameter.name)")
                if let fallback = parameter.defaultValue {
                    // Defaults must themselves be valid.
                    var probe: JSONObject = [:]
                    for required in descriptor.parameters where required.required {
                        probe[required.name] = Self.sample(for: required)
                    }
                    for constraint in descriptor.constraints {
                        switch constraint {
                        case .atLeastOne(let names), .exactlyOne(let names):
                            if !names.contains(where: { probe[$0] != nil || $0 == parameter.name }),
                                let first = names.first, let spec = descriptor.parameter(named: first)
                            {
                                probe[first] = Self.sample(for: spec)
                            }
                        case .atMostOne: break
                        }
                    }
                    probe[parameter.name] = fallback
                    XCTAssertNoThrow(
                        try registry.validate(ToolCall(tool: descriptor.name, arguments: probe)),
                        "\(descriptor.name).\(parameter.name) default")
                }
            }
        }
    }

    func testDestructiveToolsAreTheOnesThatDelete() {
        let destructive = Set(registry.descriptors.filter { $0.safety == .destructive }.map(\.name))
        XCTAssertEqual(
            destructive,
            [
                .remindersDelete, .notesDelete, .calendarDeleteEvent, .alarmsDelete, "reminders.delete_list",
                "files.trash", "reminders.batch_delete",
            ])
        for descriptor in registry.descriptors where descriptor.safety == .readOnly {
            XCTAssertFalse(
                descriptor.deduplicate, "\(descriptor.name): read-only tools must never be suppressed as duplicates")
        }
    }

    func testCreationToolsAreProtectedAgainstDuplicates() {
        let protected = Set(registry.descriptors.filter(\.deduplicate).map(\.name))
        XCTAssertTrue(
            protected.isSuperset(of: [
                .remindersCreate, .notesCreate, .notesAppend, .calendarCreateEvent, .alarmsCreate, .timersCreate,
            ]))
        XCTAssertFalse(protected.contains(.musicNext), "'next' twice must skip two songs")
        XCTAssertFalse(protected.contains(.musicSetVolume))
    }

    func testEveryExampleInEveryDescriptorValidates() throws {
        for descriptor in registry.descriptors {
            for example in descriptor.examples {
                XCTAssertNoThrow(
                    try registry.validate(ToolCall(tool: descriptor.name, arguments: example.arguments)),
                    "\(descriptor.name): \(example.phrase)")
            }
        }
    }

    /// A broad corpus in both languages, interpreted with a fixed clock, validated against the real schemas.
    func testEveryCallTheInterpreterProducesPassesSchemaValidation() async throws {
        let corpus: [String] = [
            // Apple Music
            "Play Bohemian Rhapsody on Apple Music", "Play my Study playlist", "Pause the music", "resume the music",
            "stop the music", "next song",
            "previous song", "set the volume to 40", "turn it up", "lower the volume by 25", "mute", "what's playing?",
            "list my playlists",
            "play songs by Queen", "play the album Abbey Road by The Beatles", "play Hello by Adele",
            "shuffle my Chill playlist", "do I have Thriller in my library",
            "Pon mi lista de reproducción Estudio", "pausa la música", "siguiente canción", "sube el volumen",
            "¿qué suena?", "reproduce canciones de Shakira",
            // Reminders
            "Add buy milk to my Shopping reminders list", "Remind me tomorrow at 6 PM to submit my assignment",
            "remind me in two hours to stretch",
            "remind me next Monday to pay rent", "Show my pending reminders", "show completed reminders",
            "what reminders do I have tomorrow",
            "mark buy milk as done", "mark buy milk as not done", "delete the reminder call Mom",
            "create a reminders list called Groceries",
            "reschedule the reminder call Mom to tomorrow at 5 pm", "rename the reminder call Mom to call Grandma",
            "show my reminder lists",
            "Recuérdame mañana a las 6 PM entregar mi tarea", "Agrega leche a mi lista de Compras",
            "marca comprar leche como hecho", "elimina el recordatorio llamar a mamá",
            "remind me every Monday to submit the report",
            // Notes
            "Create a note called Project Ideas with the following content: Build a robot",
            "create a note called Budget in the Work folder with the following content: rent",
            "Append this paragraph to my Project Ideas note: more", "add buy eggs to my shopping note",
            "read my Project Ideas note", "search my notes for budget",
            "list my notes", "show my notes folders", "delete my Old Plans note",
            "take a note: pick up the dry cleaning",
            "replace the content of my Shopping note with: milk, eggs",
            "Crea una nota llamada Ideas con el siguiente contenido: pintura", "lee mi nota Ideas",
            "busca en mis notas presupuesto", "elimina la nota Borrador",
            // Calendar
            "What's on my calendar tomorrow?", "Show me my calendar events for next week.",
            "Show everything scheduled this week", "what do I have on Friday",
            "Schedule a meeting with Daniel on Friday at 3 PM for one hour",
            "Create a lecture on Tuesday at 10 AM lasting two hours", "add Mom's birthday to my calendar on June 5",
            "schedule lunch with Ana tomorrow at 1 pm in my Personal calendar", "Move my meeting to 4 PM",
            "Move my Friday meeting to 3 PM",
            "reschedule my dentist appointment to Monday at 10", "rename my meeting with Daniel to Project sync",
            "change the location of my meeting with Daniel to Room 5",
            "cancel my meeting with Daniel on Friday", "am I free Friday at 3 pm", "list my calendars",
            "¿Qué tengo en mi calendario mañana?", "Agenda una reunión con Daniel el viernes a las 3 PM por una hora",
            "Crea una clase el martes a las 10 AM de dos horas",
            "Mueve mi reunión a las 4 PM", "elimina mi reunión del viernes",
            // Clock
            "Set an alarm for 7:30 tomorrow morning", "wake me up at 6",
            "set an alarm called Gym for 6 am every weekday", "show my alarms", "turn off my 7:30 am alarm",
            "delete my 7:30 alarm", "Set a timer for 10 minutes", "start a 20 minute timer called Pasta",
            "cancel the timer", "pon una alarma a las 7:30 de la mañana",
            "pon un temporizador de 5 minutos", "despiértame a las 6:45",
            // Multiple actions
            "Play my Chill playlist and remind me to study at 8 PM",
            "Pon mi lista Chill y recuérdame estudiar a las 8 PM",
            "Pause the music, set a timer for 5 minutes and what's on my calendar tomorrow",
        ]
        var checked = 0
        var london = Calendar(identifier: .gregorian)
        london.timeZone = TimeZone(identifier: "Europe/London")!
        london.firstWeekday = 2
        let now = ISODates.date(from: "2026-10-17T13:08:00+01:00", timeZone: london.timeZone)!
        for text in corpus {
            let language = LanguageDetector.detect(text)
            let request = InterpretationRequest(
                text: text, language: language, now: now, calendar: london, settings: JarvisSettings())
            let result = try await DeterministicInterpreter().interpret(request)
            guard case .plan(let plan) = result else {
                XCTFail("“\(text)” did not produce a plan: \(result)")
                continue
            }
            for call in plan.steps {
                do {
                    _ = try registry.validate(call)
                    checked += 1
                } catch {
                    XCTFail("“\(text)” → \(call.tool) \(call.arguments) failed validation: \(error)")
                }
            }
        }
        XCTAssertGreaterThan(checked, corpus.count)
    }

    private static func sample(for parameter: ToolParameter) -> JSONValue {
        switch parameter.kind {
        case .string: return "sample"
        case .integer(let min, _): return .int(min ?? 1)
        case .number(let min, _): return .double(min ?? 1)
        case .boolean: return true
        case .dateTime: return "2026-10-18T18:00:00+01:00"
        case .date: return "2026-10-18"
        case .dateOrDateTime: return "2026-10-18"
        case .time: return "07:30"
        case .enumeration(let values): return .string(values[0])
        case .stringList: return ["sample"]
        }
    }
}
