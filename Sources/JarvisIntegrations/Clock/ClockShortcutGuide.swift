import Foundation
import JarvisCore

/// The Shortcuts Jarvis needs for the Clock app, and the exact steps to build each one.
///
/// Clock has no AppleScript dictionary and no public framework. What macOS 27 *does* expose are Clock's App Intents
/// (Add Alarm, Find Alarms, Toggle Alarm, Delete Alarms, Start Timer, Cancel Timer, Get Current Timer…), which the
/// Shortcuts app surfaces as actions. Jarvis therefore runs small user-made shortcuts with `shortcuts run` and passes
/// them JSON as input. Building them takes a couple of minutes, once.
public enum ClockShortcut: String, CaseIterable, Sendable, Hashable {
    case createAlarm, listAlarms, setAlarmEnabled, deleteAlarm, startTimer, cancelTimer, getTimer

    public func name(in names: ShortcutNames) -> String {
        switch self {
        case .createAlarm: return names.createAlarm
        case .listAlarms: return names.listAlarms
        case .setAlarmEnabled: return names.setAlarmEnabled
        case .deleteAlarm: return names.deleteAlarm
        case .startTimer: return names.startTimer
        case .cancelTimer: return names.cancelTimer
        case .getTimer: return names.getTimer
        }
    }

    /// Needed to do the basic job at all.
    public var isEssentialForCreating: Bool { self == .createAlarm || self == .startTimer }

    /// Used to verify results and to look alarms up. Without them actions still run, but are reported as unverified.
    public var purpose: LocalizedText {
        switch self {
        case .createAlarm: return LocalizedText(en: "Create alarms", es: "Crear alarmas")
        case .listAlarms: return LocalizedText(en: "List alarms (also lets Jarvis verify alarm changes)", es: "Listar alarmas (también permite verificar cambios en alarmas)")
        case .setAlarmEnabled: return LocalizedText(en: "Turn alarms on or off", es: "Activar o desactivar alarmas")
        case .deleteAlarm: return LocalizedText(en: "Delete alarms", es: "Eliminar alarmas")
        case .startTimer: return LocalizedText(en: "Start timers", es: "Iniciar temporizadores")
        case .cancelTimer: return LocalizedText(en: "Cancel the running timer", es: "Cancelar el temporizador en curso")
        case .getTimer: return LocalizedText(en: "Read the running timer (lets Jarvis verify timers)", es: "Leer el temporizador en curso (permite verificar temporizadores)")
        }
    }

    /// What Jarvis sends as the shortcut's input (a text file containing JSON).
    public var inputExample: String {
        switch self {
        case .createAlarm: return #"{"hour":7,"minute":30,"time":"07:30","iso":"2026-10-18T07:30:00","label":"Gym"}"#
        case .listAlarms: return "(no input)"
        case .setAlarmEnabled: return #"{"hour":7,"minute":30,"state":"off"}"#
        case .deleteAlarm: return #"{"hour":7,"minute":30}"#
        case .startTimer: return #"{"seconds":600,"label":"Pasta"}"#
        case .cancelTimer, .getTimer: return "(no input)"
        }
    }

    /// What the shortcut must output.
    public var outputDescription: LocalizedText {
        switch self {
        case .listAlarms:
            return LocalizedText(
                en: "Text, one line per alarm: hours|minutes|enabled|label  (for example 7|30|Yes|Gym).",
                es: "Texto, una línea por alarma: horas|minutos|activada|etiqueta  (por ejemplo 7|30|Sí|Gym)."
            )
        case .getTimer:
            return LocalizedText(
                en: "The remaining time as text (for example “9.5 min”). The shortcut may fail or output nothing when no timer is running.",
                es: "El tiempo restante como texto (por ejemplo «9,5 min»). El atajo puede fallar o no devolver nada si no hay temporizador."
            )
        default:
            return LocalizedText(en: "Any text, for example “OK”.", es: "Cualquier texto, por ejemplo «OK».")
        }
    }

    public func steps(name: String, language: Language) -> [String] {
        let open = language.pick(
            "Open the Shortcuts app → File ▸ New Shortcut. Name it exactly “\(name)”.",
            "Abre la app Atajos → Archivo ▸ Nuevo atajo. Ponle exactamente el nombre «\(name)»."
        )
        let parse = language.pick(
            "Add “Get Dictionary from Input” (Input: Shortcut Input).",
            "Añade «Obtener diccionario de la entrada» (Entrada: Entrada del atajo)."
        )
        func value(_ key: String) -> String {
            language.pick("Add “Get Dictionary Value” → Get Value for “\(key)” in Dictionary.", "Añade «Obtener valor del diccionario» → Obtener valor de «\(key)» en Diccionario.")
        }
        let output = language.pick("Add “Stop and Output” with the text “OK”.", "Añade «Detener y devolver» con el texto «OK».")

        switch self {
        case .createAlarm:
            return [
                open, parse, value("iso"),
                language.pick("Add “Get Dates from Input” and give it the value from the previous step.", "Añade «Obtener fechas de la entrada» y dale el valor del paso anterior."),
                value("label"),
                language.pick("Add “Add Alarm” (Clock). Set Time to the date from “Get Dates from Input” and Name to the label value. Leave Repeats empty.", "Añade «Añadir alarma» (Reloj). Pon como Hora la fecha de «Obtener fechas de la entrada» y como Nombre el valor de la etiqueta. Deja Repeticiones vacío."),
                output,
            ]
        case .listAlarms:
            return [
                open,
                language.pick("Add “Find Alarms” (Clock) with no filters.", "Añade «Buscar alarmas» (Reloj) sin filtros."),
                language.pick("Add “Repeat with Each” over the found alarms.", "Añade «Repetir con cada» sobre las alarmas encontradas."),
                language.pick("Inside it add a “Text” action containing: Repeat Item ▸ Hours | Repeat Item ▸ Minutes | Repeat Item ▸ Enabled | Repeat Item ▸ Label (tap each variable and pick the property; keep the “|” characters).", "Dentro añade una acción «Texto» con: Elemento ▸ Horas | Elemento ▸ Minutos | Elemento ▸ Activada | Elemento ▸ Etiqueta (toca cada variable y elige la propiedad; conserva los caracteres «|»)."),
                language.pick("After “End Repeat” add “Combine Text” on the Repeat Results, separator “New Lines”.", "Tras «Fin de repetir» añade «Combinar texto» sobre los Resultados de repetir, con separador «Nuevas líneas»."),
                language.pick("Add “Stop and Output” with the combined text.", "Añade «Detener y devolver» con el texto combinado."),
            ]
        case .setAlarmEnabled:
            return [
                open, parse, value("hour"), value("minute"), value("state"),
                language.pick("Add “Find Alarms” with filters Hours is (hour value) and Minutes is (minute value).", "Añade «Buscar alarmas» con los filtros Horas es (valor de hour) y Minutos es (valor de minute)."),
                language.pick("Add an “If”: state value is “on” → “Toggle Alarm” (Operation: Turn, State: On, Alarm: the found alarms). Otherwise → “Toggle Alarm” (Turn, State: Off, same alarms). End If.", "Añade un «Si»: el valor de state es «on» → «Alternar alarma» (Operación: Activar, Estado: Sí, Alarma: las encontradas). Si no → «Alternar alarma» (Activar, Estado: No, mismas alarmas). Fin del si."),
                output,
            ]
        case .deleteAlarm:
            return [
                open, parse, value("hour"), value("minute"),
                language.pick("Add “Find Alarms” with filters Hours is (hour value) and Minutes is (minute value).", "Añade «Buscar alarmas» con los filtros Horas es (valor de hour) y Minutos es (valor de minute)."),
                language.pick("Add “Delete Alarms” on the found alarms.", "Añade «Eliminar alarmas» sobre las alarmas encontradas."),
                output,
            ]
        case .startTimer:
            return [
                open, parse, value("seconds"),
                language.pick("Add “Start Timer” (Clock). Set Duration to the seconds value and change its unit to “sec”.", "Añade «Iniciar temporizador» (Reloj). Pon como Duración el valor de seconds y cambia la unidad a «s»."),
                output,
            ]
        case .cancelTimer:
            return [open, language.pick("Add “Cancel Timer” (Clock).", "Añade «Cancelar temporizador» (Reloj)."), output]
        case .getTimer:
            return [
                open,
                language.pick("Add “Get Current Timer” (Clock) with Mode “Remaining Time”.", "Añade «Obtener temporizador actual» (Reloj) con Modo «Tiempo restante»."),
                language.pick("Add “Stop and Output” with that result.", "Añade «Detener y devolver» con ese resultado."),
            ]
        }
    }

    /// Instructions for a set of missing shortcuts, as shown in errors and Settings.
    public static func instructions(missing: [ClockShortcut], names: ShortcutNames, language: Language) -> SetupInstructions {
        var steps: [String] = []
        for shortcut in missing {
            let name = shortcut.name(in: names)
            steps.append("▸ " + name + " — " + shortcut.purpose.resolved(language))
            for (index, step) in shortcut.steps(name: name, language: language).enumerated() {
                steps.append("   \(index + 1). \(step)")
            }
            steps.append("   " + language.pick("Input Jarvis sends: ", "Entrada que envía Jarvis: ") + shortcut.inputExample)
            steps.append("   " + language.pick("Output: ", "Salida: ") + shortcut.outputDescription.resolved(language))
        }
        steps.append(language.pick(
            "Finally run each shortcut once from the Shortcuts app and choose “Always Allow” if macOS asks for permission.",
            "Por último, ejecuta cada atajo una vez desde la app Atajos y elige «Permitir siempre» si macOS pide permiso."
        ))
        return SetupInstructions(
            title: language.pick("One-time setup: Clock shortcuts", "Configuración única: atajos del Reloj"),
            steps: steps, documentation: "docs/SHORTCUTS_SETUP.md"
        )
    }
}
