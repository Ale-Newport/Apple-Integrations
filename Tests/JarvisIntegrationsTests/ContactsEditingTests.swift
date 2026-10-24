import JarvisCore
import XCTest

@testable import JarvisIntegrations

private actor EditableContacts: ContactsLookup {
    var value = ContactMatch(
        id: "person-1", fullName: "Pablo Ruiz", emails: ["old@example.com"], phones: [], organization: "",
        givenName: "Pablo", familyName: "Ruiz")
    var saves = 0
    let retainChanges: Bool
    init(retainChanges: Bool = true) { self.retainChanges = retainChanges }
    func access() async -> ContactsAccess { .authorized }
    func requestAccess() async -> ContactsAccess { .authorized }
    func find(_ query: String, limit: Int) async throws -> [ContactMatch] { [value] }
    func get(_ id: String) async throws -> ContactMatch { value }
    func externalChange() { value.nickname = "Externally changed" }
    func save(id: String?, fields: [String: String]) async throws -> ContactMatch {
        saves += 1
        if retainChanges {
            if let name = fields["given_name"] {
                value.givenName = name
                value.fullName = name + " " + value.familyName
            }
            if let email = fields["email"] { value.emails.append(email) }
        }
        return value
    }
}
final class ContactsEditingTests: XCTestCase {
    func testCreateConfirmationIsValidAndReadbackMatchesRequestedFields() async throws {
        let store = EditableContacts()
        let registry = ToolRegistry(integrations: [ContactsIntegration(lookup: store)])
        let proposal = try await registry.run("contacts.create", ["given_name": "Daniel", "email": "new@example.com"])
        let review = try XCTUnwrap(proposal.confirmation)
        XCTAssertNoThrow(try registry.validate(review.call))
        let saved = try await registry.run(
            "contacts.create", review.call.arguments, context: executionContext(confirmed: true))
        XCTAssertEqual(saved.output?.data?["given_name"], "Daniel")
        XCTAssertEqual(saved.output?.data?["emails"]?.arrayValue?.count, 2)
        XCTAssertTrue(saved.output?.verification.isVerified == true)
    }
    func testChangedContactRequiresNewReviewBeforeWriting() async throws {
        let store = EditableContacts()
        let registry = ToolRegistry(integrations: [ContactsIntegration(lookup: store)])
        let proposal = try await registry.run("contacts.update", ["id": "person-1", "given_name": "Daniel"])
        let review = try XCTUnwrap(proposal.confirmation)
        await store.externalChange()
        let current = try await registry.run(
            "contacts.update", review.call.arguments, context: executionContext(confirmed: true))
        XCTAssertNotNil(current.confirmation)
        let count = await store.saves
        XCTAssertEqual(count, 0)
    }
    func testUnretainedFieldsCannotBeReportedAsVerified() async throws {
        let registry = ToolRegistry(integrations: [ContactsIntegration(lookup: EditableContacts(retainChanges: false))])
        let proposal = try await registry.run("contacts.update", ["id": "person-1", "given_name": "Daniel"])
        let review = try XCTUnwrap(proposal.confirmation)
        do {
            _ = try await registry.run(
                "contacts.update", review.call.arguments, context: executionContext(confirmed: true))
            XCTFail()
        } catch let error as JarvisError { XCTAssertEqual(error.code, "verification_failed") }
    }
}
