import Contacts
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

    var json: JSONValue {
        .object([
            "id": .string(id), "name": .string(fullName), "emails": .array(emails.map(JSONValue.string)),
            "phones": .array(phones.map(JSONValue.string)), "organization": organization.isEmpty ? .null : .string(organization),
        ])
    }
}

protocol ContactsLookup: Sendable {
    func access() async -> ContactsAccess
    func requestAccess() async -> ContactsAccess
    func find(_ query: String, limit: Int) async throws -> [ContactMatch]
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

    func find(_ query: String, limit: Int) async throws -> [ContactMatch] {
        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName), CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor, CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactIdentifierKey as CNKeyDescriptor,
        ]
        let predicate = CNContact.predicateForContacts(matchingName: query)
        let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keys)
        return contacts.prefix(limit).map { contact in
            ContactMatch(
                id: contact.identifier,
                fullName: CNContactFormatter.string(from: contact, style: .fullName) ?? contact.organizationName,
                emails: contact.emailAddresses.map { String($0.value) },
                phones: contact.phoneNumbers.map { $0.value.stringValue },
                organization: contact.organizationName
            )
        }
    }
}

/// Optional contact lookup (`contacts.find`). Nothing is read until the user asks for it, and the permission is
/// only requested when this tool is used (or from Settings).
public struct ContactsIntegration: AppIntegration {
    public let id = IntegrationID.contacts
    public let displayName = LocalizedText(en: "Contacts", es: "Contactos")
    public let summary = LocalizedText(en: "Optional: look up people by name.", es: "Opcional: busca personas por nombre.")
    public let symbolName = "person.crop.circle"

    private let lookup: any ContactsLookup

    public init() { self.lookup = SystemContactsLookup() }
    init(lookup: any ContactsLookup) { self.lookup = lookup }

    public var permissionRequirements: [PermissionRequirement] { [EventKitRequirements.contacts] }

    public var tools: [ToolDescriptor] {
        [ToolDescriptor(
            name: .contactsFind, integration: id, title: "Find a contact", summary: "Looks up people in Contacts by name.",
            parameters: [
                .string("query", "Name (or part of it) to look for.", required: true, maxLength: 200),
                .integer("limit", "Maximum results.", min: 1, max: 20, default: 5),
            ], safety: .readOnly, timeout: 20,
            examples: [ToolExample("Find Daniel in my contacts", arguments: ["query": "Daniel"])]
        )]
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
        case .notDetermined: return IntegrationStatus(state: .needsPermission, detail: EventKitRequirements.contacts.rationale, permissions: [entry])
        case .restricted: return IntegrationStatus(state: .restricted, detail: EventKitRequirements.contacts.rationale, permissions: [entry])
        case .denied: return IntegrationStatus(state: .denied, detail: EventKitRequirements.contacts.rationale, permissions: [entry])
        }
    }

    public func authorization(for tool: ToolDescriptor) async -> AuthorizationState { state(await lookup.access()) }
    public func requestAuthorization(for tool: ToolDescriptor) async -> AuthorizationState { state(await lookup.requestAccess()) }

    public func execute(_ call: ValidatedToolCall, context: ExecutionContext) async throws -> ToolOutcome {
        let query = call.string("query") ?? ""
        let limit = call.int("limit") ?? 5
        let matches: [ContactMatch]
        do {
            matches = try await lookup.find(query, limit: limit)
        } catch {
            throw JarvisError.failed("contacts_error", en: "Contacts could not be searched: \(error.localizedDescription)", es: "No se pudo buscar en Contactos: \(error.localizedDescription)")
        }
        let language = context.language
        guard !matches.isEmpty else {
            return .done(ToolOutput(message: language.pick("No contacts match “\(query)”.", "Ningún contacto coincide con «\(query)»."), data: ["contacts": [], "count": 0], verification: .notApplicable))
        }
        let lines = matches.map { match -> String in
            let detail = ([match.organization] + match.emails.prefix(1)).filter { !$0.isEmpty }.joined(separator: " · ")
            return detail.isEmpty ? match.fullName : "\(match.fullName) — \(detail)"
        }
        return .done(ToolOutput(
            message: language.pick("Found \(matches.count) contact\(matches.count == 1 ? "" : "s"):\n", "Encontré \(matches.count) contacto\(matches.count == 1 ? "" : "s"):\n") + Formatting.bullets(lines),
            data: ["contacts": .array(matches.map(\.json)), "count": .int(matches.count)], verification: .notApplicable
        ))
    }
}
