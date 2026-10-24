import Contacts
import CryptoKit
import Foundation
import JarvisCore

public enum ContactsAccess: Sendable, Equatable {
    case authorized
    case notDetermined
    case denied
    case restricted
}

struct ContactMatch: Sendable, Hashable {
    var id: String
    var fullName: String
    var emails: [String]
    var phones: [String]
    var organization: String
    var nickname: String = ""
    var givenName: String = ""
    var familyName: String = ""

    var json: JSONValue {
        .object([
            "id": .string(id), "name": .string(fullName), "nickname": .string(nickname),
            "emails": .array(emails.map(JSONValue.string)),
            "phones": .array(phones.map(JSONValue.string)),
            "organization": organization.isEmpty ? .null : .string(organization),
            "given_name": .string(givenName), "family_name": .string(familyName),
        ])
    }
}

protocol ContactsLookup: Sendable {
    func access() async -> ContactsAccess
    func requestAccess() async -> ContactsAccess
    func find(_ query: String, limit: Int) async throws -> [ContactMatch]
    func get(_ id: String) async throws -> ContactMatch
    func save(id: String?, fields: [String: String]) async throws -> ContactMatch
}
extension ContactsLookup {
    func get(_ id: String) async throws -> ContactMatch {
        throw integrationFailure("contact_missing", "Contact unavailable.", "Contacto no disponible.")
    }
    func save(id: String?, fields: [String: String]) async throws -> ContactMatch {
        throw integrationFailure("contact_missing", "Contact unavailable.", "Contacto no disponible.")
    }
}

/// `CNContactStore`-backed lookup. Only names, e-mail addresses, phone numbers and organisation are read.
struct SystemContactsLookup: ContactsLookup {
    func access() async -> ContactsAccess {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        default: return .denied
        }
    }

    func requestAccess() async -> ContactsAccess {
        _ = try? await CNContactStore().requestAccess(for: .contacts)
        return await access()
    }

    private var keys: [CNKeyDescriptor] {
        [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName), CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor, CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactIdentifierKey as CNKeyDescriptor, CNContactNicknameKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor, CNContactFamilyNameKey as CNKeyDescriptor,
        ]
    }
    private func match(_ contact: CNContact) -> ContactMatch {
        ContactMatch(
            id: contact.identifier,
            fullName: CNContactFormatter.string(from: contact, style: .fullName) ?? contact.organizationName,
            emails: contact.emailAddresses.map { String($0.value) },
            phones: contact.phoneNumbers.map { $0.value.stringValue },
            organization: contact.organizationName, nickname: contact.nickname, givenName: contact.givenName,
            familyName: contact.familyName)
    }
    func find(_ query: String, limit: Int) async throws -> [ContactMatch] {
        let request = CNContactFetchRequest(keysToFetch: keys)
        var found: [ContactMatch] = []
        var scanned = 0
        try CNContactStore().enumerateContacts(with: request) { contact, stop in
            scanned += 1
            let value = match(contact)
            if [value.fullName, value.nickname, value.organization].contains(where: {
                TextFolding.fold($0).contains(TextFolding.fold(query))
            }) {
                found.append(value)
            }
            if found.count >= limit || scanned >= 10000 { stop.pointee = true }
        }
        return found
    }
    func get(_ id: String) async throws -> ContactMatch {
        match(try CNContactStore().unifiedContact(withIdentifier: id, keysToFetch: keys))
    }
    func save(id: String?, fields: [String: String]) async throws -> ContactMatch {
        let store = CNContactStore()
        let contact: CNMutableContact
        if let id {
            contact = try store.unifiedContact(withIdentifier: id, keysToFetch: keys).mutableCopy() as! CNMutableContact
        } else {
            contact = CNMutableContact()
        }
        if let v = fields["given_name"] { contact.givenName = v }
        if let v = fields["family_name"] { contact.familyName = v }
        if let v = fields["nickname"] { contact.nickname = v }
        if let v = fields["organization"] { contact.organizationName = v }
        // Add a new address/phone; never erase existing labelled values implicitly.
        if let v = fields["email"],
            !contact.emailAddresses.contains(where: { String($0.value).lowercased() == v.lowercased() })
        {
            contact.emailAddresses.append(CNLabeledValue(label: CNLabelOther, value: v as NSString))
        }
        if let v = fields["phone"], !contact.phoneNumbers.contains(where: { $0.value.stringValue == v }) {
            contact.phoneNumbers.append(CNLabeledValue(label: CNLabelOther, value: CNPhoneNumber(stringValue: v)))
        }
        let request = CNSaveRequest()
        if id == nil { request.add(contact, toContainerWithIdentifier: nil) } else { request.update(contact) }
        try store.execute(request)
        return try await get(contact.identifier)
    }
}

/// Optional contact lookup (`contacts.find`). Nothing is read until the user asks for it, and the permission is
/// only requested when this tool is used (or from Settings).
public struct ContactsIntegration: AppIntegration {
    public let id = IntegrationID.contacts
    public let displayName = LocalizedText(en: "Contacts", es: "Contactos")
    public let summary = LocalizedText(
        en: "Find people by name or nickname, read details and safely create or edit contacts.",
        es: "Busca por nombre o apodo, consulta detalles y crea o edita contactos.")
    public let symbolName = "person.crop.circle"

    private let lookup: any ContactsLookup

    public init() { self.lookup = SystemContactsLookup() }
    init(lookup: any ContactsLookup) { self.lookup = lookup }

    public var permissionRequirements: [PermissionRequirement] { [EventKitRequirements.contacts] }

    public var tools: [ToolDescriptor] {
        [
            ToolDescriptor(
                name: .contactsFind, integration: id, title: "Find a contact",
                summary: "Looks up people in Contacts by name.",
                parameters: [
                    .string("query", "Name (or part of it) to look for.", required: true, maxLength: 200),
                    .integer("limit", "Maximum results.", min: 1, max: 20, default: 5),
                ], safety: .readOnly, timeout: 20,
                examples: [ToolExample("Find Daniel in my contacts", arguments: ["query": "Daniel"])]
            ),
            ToolDescriptor(
                name: "contacts.get", integration: id, title: "Read contact details",
                summary: "Reads actual name, nickname, organization, emails and phones by stable Contacts ID.",
                parameters: [.string("id", "Actual Contacts ID.", required: true, maxLength: 500)], safety: .readOnly),
            ToolDescriptor(
                name: "contacts.create", integration: id, title: "Create contact",
                summary: "Creates a contact after explicit review. Reads back saved fields and stable ID.",
                parameters: fields + [.string("revision", "Confirmation revision.", maxLength: 100)],
                constraints: [.atLeastOne(["given_name", "family_name", "organization"])],
                safety: .modifying, deduplicate: true, requiresConfirmation: true),
            ToolDescriptor(
                name: "contacts.update", integration: id, title: "Edit contact",
                summary:
                    "Changes only supplied name/nickname/organization fields. Adds email/phone without erasing existing labels or addresses. Reviews actual existing contact before changing it.",
                parameters: [
                    .string("id", "Actual Contacts ID.", required: true, maxLength: 500),
                    .string("revision", "Confirmation revision.", maxLength: 100),
                ] + fields, constraints: [.atLeastOne(fields.map(\.name))], safety: .modifying,
                requiresConfirmation: true),
        ]
    }
    private var fields: [ToolParameter] {
        [
            .string("given_name", "First name.", maxLength: 200), .string("family_name", "Last name.", maxLength: 200),
            .string("nickname", "Nickname.", maxLength: 200), .string("organization", "Organization.", maxLength: 200),
            .string("email", "Exact email address to add.", maxLength: 254),
            .string("phone", "Exact telephone number to add.", maxLength: 100),
        ]
    }

    private func state(_ access: ContactsAccess) -> AuthorizationState {
        switch access {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined(EventKitRequirements.contacts)
        case .denied: return .denied(EventKitRequirements.contacts)
        case .restricted: return .restricted(EventKitRequirements.contacts)
        }
    }

    public func status() async -> IntegrationStatus {
        let access = await lookup.access()
        let entry = IntegrationStatus.PermissionEntry(requirement: EventKitRequirements.contacts, state: state(access))
        switch access {
        case .authorized: return IntegrationStatus(state: .ready, permissions: [entry])
        case .notDetermined:
            return IntegrationStatus(
                state: .needsPermission, detail: EventKitRequirements.contacts.rationale, permissions: [entry])
        case .restricted:
            return IntegrationStatus(
                state: .restricted, detail: EventKitRequirements.contacts.rationale, permissions: [entry])
        case .denied:
            return IntegrationStatus(
                state: .denied, detail: EventKitRequirements.contacts.rationale, permissions: [entry])
        }
    }

    public func authorization(for tool: ToolDescriptor) async -> AuthorizationState { state(await lookup.access()) }
    public func requestAuthorization(for tool: ToolDescriptor) async -> AuthorizationState {
        state(await lookup.requestAccess())
    }

    public func execute(_ call: ValidatedToolCall, context: ExecutionContext) async throws -> ToolOutcome {
        let operation = call.descriptor.name.rawValue
        if operation == "contacts.get" {
            let value = try await lookup.get(call.string("id") ?? "")
            return .done(ToolOutput(message: value.fullName, data: value.json, verification: .notApplicable))
        }
        if operation == "contacts.create" || operation == "contacts.update" {
            let values = fields.reduce(into: [String: String]()) {
                if let value = call.string($1.name) { $0[$1.name] = value }
            }
            if let email = values["email"], !MailIntegration.email(email) {
                throw integrationFailure(
                    "invalid_email", "Enter an exact email address.", "Indica una dirección de correo válida.")
            }
            let existing: ContactMatch?
            if let id = call.string("id") { existing = try await lookup.get(id) } else { existing = nil }
            let snapshot = existing?.json.canonicalString() ?? "new"
            let revision = SHA256.hash(data: Data(snapshot.utf8)).map { String(format: "%02x", $0) }.joined()
            if !context.isConfirmed || (existing != nil && call.string("revision") != revision) {
                let edits = values.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
                return .confirm(
                    ConfirmationRequest(
                        prompt: context.language.pick(
                            "Save these contact changes?", "¿Guardar estos cambios del contacto?") + "\n"
                            + (existing?.fullName ?? "") + "\n" + edits,
                        call: call.call.adding(["revision": .string(revision)]), destructive: false))
            }
            let saved = try await lookup.save(id: call.string("id"), fields: values)
            let scalarFields = [
                "given_name": saved.givenName, "family_name": saved.familyName, "nickname": saved.nickname,
                "organization": saved.organization,
            ]
            for (key, actual) in scalarFields where values[key] != nil {
                guard actual == values[key] else {
                    throw JarvisError.verificationFailed(
                        LocalizedText(
                            en: "Contacts did not retain every requested field. Inspect the contact before retrying.",
                            es:
                                "Contactos no conservó todos los campos solicitados. Revisa el contacto antes de reintentar."
                        ))
                }
            }
            if let email = values["email"],
                !saved.emails.contains(where: { $0.caseInsensitiveCompare(email) == .orderedSame })
            {
                throw CocoaError(.fileWriteUnknown)
            }
            if let phone = values["phone"],
                !saved.phones.contains(where: { $0.filter(\.isNumber) == phone.filter(\.isNumber) })
            {
                throw CocoaError(.fileWriteUnknown)
            }
            return .done(
                ToolOutput(
                    message: context.language.pick("Contact saved and read back.", "Contacto guardado y releído."),
                    data: saved.json, verification: .verified("Read back from CNContactStore after CNSaveRequest.")))
        }
        let query = call.string("query") ?? ""
        let limit = call.int("limit") ?? 5
        let matches: [ContactMatch]
        do {
            matches = try await lookup.find(query, limit: limit)
        } catch {
            throw JarvisError.failed(
                "contacts_error", en: "Contacts could not be searched: \(error.localizedDescription)",
                es: "No se pudo buscar en Contactos: \(error.localizedDescription)")
        }
        let language = context.language
        guard !matches.isEmpty else {
            return .done(
                ToolOutput(
                    message: language.pick("No contacts match “\(query)”.", "Ningún contacto coincide con «\(query)»."),
                    data: ["contacts": [], "count": 0], verification: .notApplicable))
        }
        let lines = matches.map { match -> String in
            let detail = ([match.organization] + match.emails.prefix(1)).filter { !$0.isEmpty }.joined(separator: " · ")
            return detail.isEmpty ? match.fullName : "\(match.fullName) — \(detail)"
        }
        return .done(
            ToolOutput(
                message: language.pick(
                    "Found \(matches.count) contact\(matches.count == 1 ? "" : "s"):\n",
                    "Encontré \(matches.count) contacto\(matches.count == 1 ? "" : "s"):\n")
                    + Formatting.bullets(lines),
                data: ["contacts": .array(matches.map(\.json)), "count": .int(matches.count)],
                verification: .notApplicable
            ))
    }
}
