import JarvisCore
import JarvisIntegrations
import SwiftUI

/// Static, hand-written help for each integration: what to say and what the limits are.
struct IntegrationGuide {
    let examples: [(en: String, es: String)]
    let limitations: [(en: String, es: String)]

    static func guide(for id: IntegrationID) -> IntegrationGuide {
        switch id {
        case .music:
            return IntegrationGuide(
                examples: [
                    ("Play Bohemian Rhapsody on Apple Music", "Pon Bohemian Rhapsody en Apple Music"),
                    ("Play my Study playlist", "Pon mi lista de reproducción Study"),
                    ("Pause the music · Next song · Previous song", "Pausa la música · Siguiente canción · Canción anterior"),
                    ("Set the volume to 40 · Turn it up", "Pon el volumen al 40 · Sube el volumen"),
                    ("What's playing?", "¿Qué suena?"),
                    ("List my playlists · Search my music for Radiohead", "Muestra mis listas · Busca Radiohead en mi música"),
                ],
                limitations: [
                    ("Only music that is in your library can be played. Jarvis never claims playback it could not confirm.", "Solo se puede reproducir música que esté en tu biblioteca. Jarvis nunca afirma una reproducción que no pudo confirmar."),
                    ("Albums and artists play through a playlist called “Jarvis Queue” (change or disable it in Settings); nothing else in your library is modified.", "Los álbumes y artistas se reproducen mediante una lista llamada «Jarvis Queue» (cámbiala o desactívala en Ajustes); no se modifica nada más de tu biblioteca."),
                    ("The catalogue-wide Apple Music search needs MusicKit and a developer account, so it is not used.", "La búsqueda en todo el catálogo de Apple Music requiere MusicKit y una cuenta de desarrollador, por eso no se usa."),
                ]
            )
        case .reminders:
            return IntegrationGuide(
                examples: [
                    ("Add milk to my Shopping reminders list", "Agrega leche a mi lista de recordatorios Compras"),
                    ("Remind me tomorrow at 6 PM to submit my assignment", "Recuérdame mañana a las 6 PM entregar mi tarea"),
                    ("Show my pending reminders", "Muestra mis recordatorios pendientes"),
                    ("Mark buy milk as done", "Marca comprar leche como hecho"),
                    ("Delete the reminder call Mom", "Elimina el recordatorio llamar a mamá"),
                    ("Create a reminders list called Groceries", "Crea una lista de recordatorios llamada Viajes"),
                ],
                limitations: [
                    ("Daily, weekly, monthly and yearly reminder recurrence is supported. Sections and subtasks require the Reminders app.", "Se admiten recordatorios diarios, semanales, mensuales y anuales. Las secciones y subtareas requieren la app Recordatorios."),
                    ("Deleting always asks first. Duplicate list names in different accounts are never guessed.", "Eliminar siempre pregunta antes. Los nombres de lista duplicados en distintas cuentas nunca se adivinan."),
                ]
            )
        case .notes:
            return IntegrationGuide(
                examples: [
                    ("Create a note called Project Ideas with the following content: …", "Crea una nota llamada Ideas con el siguiente contenido: …"),
                    ("Append this paragraph to my Project Ideas note: …", "Añade este párrafo a mi nota Ideas: …"),
                    ("Search my notes for budget", "Busca en mis notas presupuesto"),
                    ("Read my Project Ideas note", "Lee mi nota Ideas"),
                    ("Delete my Old Plans note", "Elimina mi nota Borrador"),
                ],
                limitations: [
                    ("Password-protected notes cannot be read or changed. Notes with attachments are never rewritten (Notes' scripting interface would risk losing them).", "Las notas con contraseña no se pueden leer ni modificar. Las notas con adjuntos nunca se reescriben (la interfaz de scripts de Notas podría perderlos)."),
                    ("Deleted notes go to Recently Deleted. If a folder name exists in several accounts, Jarvis asks which one.", "Las notas eliminadas van a Eliminadas recientemente. Si una carpeta existe en varias cuentas, Jarvis pregunta cuál."),
                ]
            )
        case .calendar:
            return IntegrationGuide(
                examples: [
                    ("What's on my calendar tomorrow?", "¿Qué tengo en mi calendario mañana?"),
                    ("Schedule a meeting with Daniel on Friday at 3 PM for one hour", "Agenda una reunión con Daniel el viernes a las 3 PM por una hora"),
                    ("Create a lecture on Tuesday at 10 AM lasting two hours", "Crea una clase el martes a las 10 AM de dos horas"),
                    ("Move my Friday meeting to 3 PM", "Mueve mi reunión del viernes a las 3 PM"),
                    ("Am I free Friday at 3 PM?", "¿Estoy libre el viernes a las 3 PM?"),
                    ("Cancel my meeting with Daniel on Friday", "Cancela mi reunión con Daniel el viernes"),
                ],
                limitations: [
                    ("Invitations cannot be sent or attendees added: Calendar's public API does not allow it. People you mention are noted in the event.", "No se pueden enviar invitaciones ni añadir asistentes: la API pública de Calendario no lo permite. Las personas que menciones se anotan en el evento."),
                    ("If a request matches several events, nothing is changed until you choose. Changing a repeating event affects only that occurrence.", "Si una petición coincide con varios eventos, no se cambia nada hasta que elijas. Cambiar un evento repetitivo solo afecta a esa ocurrencia."),
                ]
            )
        case .clock:
            return IntegrationGuide(
                examples: [
                    ("Set an alarm for 7:30 tomorrow morning", "Pon una alarma a las 7:30 de la mañana"),
                    ("Show my alarms · Turn off my 7:30 alarm", "Muestra mis alarmas · Desactiva la alarma de las 7:30"),
                    ("Delete my 7:30 alarm", "Elimina mi alarma de las 7:30"),
                    ("Set a timer for 10 minutes · Cancel the timer", "Pon un temporizador de 10 minutos · Cancela el temporizador"),
                ],
                limitations: [
                    ("Clock has no scripting interface. Jarvis uses Shortcuts actions from the Clock app, so you create a few small “Jarvis …” shortcuts once (see below).", "Reloj no tiene interfaz de scripts. Jarvis usa acciones de Atajos de la app Reloj, así que creas unos pocos atajos «Jarvis …» una sola vez (ver abajo)."),
                    ("Alarms ring at the next occurrence of the time (they cannot be pinned to a later date); repeating alarms and timer labels are not supported.", "Las alarmas suenan en la próxima vez que llegue esa hora (no se pueden fijar a una fecha posterior); no se admiten alarmas repetitivas ni etiquetas de temporizador."),
                    ("Without the optional “Jarvis List Alarms” and “Jarvis Get Timer” shortcuts, actions run but are reported as not verified.", "Sin los atajos opcionales «Jarvis List Alarms» y «Jarvis Get Timer», las acciones se ejecutan pero se informan como no verificadas."),
                ]
            )
        case "weather":
            return IntegrationGuide(examples: [("Weather in London tomorrow", "¿Va a llover mañana en Londres?")], limitations: [
                ("Data by Open-Meteo (CC BY 4.0), geocoding by GeoNames. The city is sent to Open-Meteo when requested. No background monitoring or severe alerts.", "Datos de Open-Meteo (CC BY 4.0), geocodificación de GeoNames. La ciudad se envía a Open-Meteo al consultarla. Sin seguimiento en segundo plano ni alertas graves."),
                ("Seven-day forecast; configure a default location in Intelligence settings.", "Previsión de siete días; configura una ubicación predeterminada en los ajustes de Inteligencia.")])
        case "utilities":
            return IntegrationGuide(examples: [("Calculate (2+3)^4", "Calcula el 17,5% de 2.450"), ("Convert 10 km to mi", "Convierte 10 km a mi")], limitations: [("Numeric calculations only; no symbolic algebra or live currency rates. Trigonometric angles are radians.", "Cálculos numéricos; sin álgebra simbólica ni tipos de cambio en directo. Los ángulos trigonométricos se expresan en radianes.")])
        case "jarvis_timers":
            return IntegrationGuide(examples: [("Start a Jarvis timer for 25 minutes", "Pon un temporizador de Jarvis de 25 minutos")], limitations: [("Uses macOS notifications, separate from Clock. Notification permission is required. Focus, sleep and system notification settings affect delivery.", "Usa notificaciones de macOS, separadas de Reloj. Requiere permiso de notificaciones. El modo de concentración, el reposo y los ajustes del sistema afectan al aviso.")])
        case .contacts:
            return IntegrationGuide(
                examples: [("Find Daniel in my contacts", "Busca a Daniel en mis contactos")],
                limitations: [
                    ("Optional. Contacts are only read when you ask, or when “Look up people in Contacts” is enabled for events.", "Opcional. Los contactos solo se leen cuando lo pides o cuando «Buscar personas en Contactos» está activado para eventos."),
                ]
            )
        default:
            return IntegrationGuide(examples: [], limitations: [])
        }
    }
}

struct IntegrationDetailView: View {
    @Environment(AppModel.self) private var model
    let integrationID: IntegrationID

    var body: some View {
        if let integration = model.integration(integrationID) {
            let status = model.statuses[integrationID]
            let guide = IntegrationGuide.guide(for: integrationID)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header(integration, status)
                    permissions(integration, status)
                    if integrationID == .clock { ClockSetupView() }
                    if !guide.examples.isEmpty {
                        section(model.t("What you can say", "Qué puedes decir")) {
                            ForEach(Array(guide.examples.enumerated()), id: \.offset) { _, example in
                                Button {
                                    model.input = model.t(example.en, example.es)
                                    model.selection = .chat
                                    model.requestFocus()
                                } label: {
                                    Label(model.t(example.en, example.es), systemImage: "text.bubble")
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                                .padding(.vertical, 2)
                            }
                        }
                    }
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(integration.tools, id: \.name) { tool in
                                HStack(alignment: .top) {
                                    Image(systemName: safetySymbol(tool.safety)).foregroundStyle(safetyColor(tool.safety)).frame(width: 18)
                                    VStack(alignment: .leading) {
                                        Text(tool.name.rawValue).font(.system(.callout, design: .monospaced))
                                        Text(tool.summary).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .padding(.top, 6)
                    } label: {
                        Text(model.t("Operations (technical)", "Operaciones (técnico)")).font(.headline)
                    }
                    if !guide.limitations.isEmpty {
                        section(model.t("Good to know", "Conviene saber")) {
                            ForEach(Array(guide.limitations.enumerated()), id: \.offset) { _, item in
                                Label(model.t(item.en, item.es), systemImage: "info.circle").foregroundStyle(.secondary).font(.callout)
                            }
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 720, alignment: .leading)
            }
            .navigationTitle(integration.displayName.resolved(model.language))
            .onAppear { model.refreshStatuses() }
        } else {
            ContentUnavailableView("Unknown integration", systemImage: "questionmark")
        }
    }

    private func header(_ integration: any AppIntegration, _ status: IntegrationStatus?) -> some View {
        HStack(spacing: 14) {
            Image(systemName: integration.symbolName)
                .font(.system(size: 30))
                .frame(width: 56, height: 56)
                .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 3) {
                Text(integration.displayName.resolved(model.language)).font(.title2.weight(.semibold))
                Text(integration.summary.resolved(model.language)).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    StatusDot(state: status?.state)
                    Text(statusText(status)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func statusText(_ status: IntegrationStatus?) -> String {
        guard let status else { return model.t("Checking…", "Comprobando…") }
        switch status.state {
        case .ready: return model.t("Ready", "Listo")
        case .needsPermission: return model.t("Needs your permission", "Necesita tu permiso")
        case .needsSetup: return model.t("Needs one-time setup", "Necesita configuración única")
        case .denied: return model.t("Access denied in System Settings", "Acceso denegado en Ajustes del Sistema")
        case .restricted: return model.t("Restricted by a profile or parental controls", "Restringido por un perfil o controles parentales")
        case .unavailable: return model.t("Not available on this Mac", "No disponible en este Mac")
        }
    }

    @ViewBuilder
    private func permissions(_ integration: any AppIntegration, _ status: IntegrationStatus?) -> some View {
        if let status, !status.permissions.isEmpty {
            section(model.t("Permissions", "Permisos")) {
                ForEach(status.permissions) { entry in
                    PermissionRow(integration: integration, entry: entry)
                }
            }
        } else if integration.permissionRequirements.isEmpty {
            section(model.t("Permissions", "Permisos")) {
                Label(model.t("No macOS privacy permission is needed.", "No se necesita ningún permiso de privacidad de macOS."), systemImage: "checkmark.shield").foregroundStyle(.secondary)
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }

    private func safetySymbol(_ safety: ToolSafety) -> String {
        switch safety {
        case .readOnly: return "eye"
        case .modifying: return "pencil"
        case .destructive: return "trash"
        }
    }

    private func safetyColor(_ safety: ToolSafety) -> Color {
        switch safety {
        case .readOnly: return .secondary
        case .modifying: return .blue
        case .destructive: return .red
        }
    }
}

struct PermissionRow: View {
    @Environment(AppModel.self) private var model
    let integration: any AppIntegration
    let entry: IntegrationStatus.PermissionEntry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(color).frame(width: 22).font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.requirement.title.resolved(model.language)).font(.callout.weight(.medium))
                Text(entry.requirement.rationale.resolved(model.language)).font(.caption).foregroundStyle(.secondary)
                Text(stateText).font(.caption).foregroundStyle(color)
            }
            Spacer()
            actions
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var actions: some View {
        switch entry.state {
        case .notDetermined:
            Button(model.t("Allow…", "Permitir…")) { model.requestPermission(for: integration) }
        case .denied, .restricted:
            Button(model.t("Open System Settings", "Abrir Ajustes del Sistema")) { model.openSystemSettings(entry.requirement.settingsURL) }
        case .authorized, .unavailable:
            EmptyView()
        }
    }

    private var symbol: String {
        switch entry.state {
        case .authorized: return "checkmark.circle.fill"
        case .notDetermined: return "questionmark.circle.fill"
        case .denied, .restricted: return "xmark.circle.fill"
        case .unavailable: return "minus.circle.fill"
        }
    }

    private var color: Color {
        switch entry.state {
        case .authorized: return .green
        case .notDetermined: return .orange
        case .denied, .restricted: return .red
        case .unavailable: return .secondary
        }
    }

    private var stateText: String {
        switch entry.state {
        case .authorized: return model.t("Allowed", "Permitido")
        case .notDetermined: return model.t("Not asked yet", "Aún no se ha pedido")
        case .denied: return model.t("Denied — change it in System Settings", "Denegado: cámbialo en Ajustes del Sistema")
        case .restricted: return model.t("Restricted by your organisation or parental controls", "Restringido por tu organización o controles parentales")
        case .unavailable(let reason): return reason.resolved(model.language)
        }
    }
}
