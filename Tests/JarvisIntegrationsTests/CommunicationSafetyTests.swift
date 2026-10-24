import JarvisCore
import XCTest

@testable import JarvisIntegrations

final class CommunicationSafetyTests: XCTestCase {
    func testAttachmentBytesChangingRequireReconfirmationEvenWhenNameAndSizeMatch() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("first".utf8).write(to: url)
        let scripts = FakeScripts()
        scripts.on(
            MailScripts.readDraft,
            returns: Rec.fields("17", "Meeting", "Hello", "pablo@example.com", "", "", "me@example.com", url.path))
        scripts.on(MailScripts.send, returns: "accepted")
        let registry = ToolRegistry(integrations: [MailIntegration(scripts: scripts, access: FakeAutomation())])
        let first = try await registry.run("mail.send", ["draft_id": 17])
        let review = try XCTUnwrap(first.confirmation)
        XCTAssertTrue(review.prompt.contains(url.lastPathComponent))
        try Data("other".utf8).write(to: url)
        let changed = try await registry.run(
            "mail.send", review.call.arguments, context: executionContext(confirmed: true))
        XCTAssertNotNil(changed.confirmation)
        XCTAssertNotEqual(review.call.arguments["revision"], changed.confirmation?.call.arguments["revision"])
        XCTAssertTrue(scripts.calls(to: MailScripts.send).isEmpty)
    }
    func testMailSendRequiresActualDraftReviewAndChangedDraftReconfirmation() async throws {
        let scripts = FakeScripts()
        scripts.on(MailScripts.readDraft) { _, index in
            Rec.fields(
                "17", "Meeting", index < 2 ? "Hello\nThursday?" : "Changed body", "pablo@example.com", "",
                "hidden@example.com", "me@example.com")
        }
        scripts.on(MailScripts.send, returns: "accepted")
        let registry = ToolRegistry(integrations: [MailIntegration(scripts: scripts, access: FakeAutomation())])
        let review = try await registry.run("mail.send", ["draft_id": 17])
        let confirmation = try XCTUnwrap(review.confirmation)
        XCTAssertTrue(confirmation.prompt.contains("hidden@example.com"))
        XCTAssertTrue(confirmation.prompt.contains("Hello\nThursday?"))
        XCTAssertTrue(scripts.calls(to: MailScripts.send).isEmpty)
        let sent = try await registry.run(
            "mail.send", confirmation.call.arguments, context: executionContext(confirmed: true))
        XCTAssertFalse(try XCTUnwrap(sent.output).verification.isVerified)
        XCTAssertEqual(scripts.calls(to: MailScripts.send).count, 1)
        let changed = try await registry.run(
            "mail.send", confirmation.call.arguments, context: executionContext(confirmed: true))
        XCTAssertNotNil(changed.confirmation)
        XCTAssertTrue(changed.confirmation?.prompt.contains("Changed body") == true)
        XCTAssertEqual(scripts.calls(to: MailScripts.send).count, 1)
    }
    func testMailDraftRejectsGuessedOrMalformedRecipientsBeforeCreatingAnything() async throws {
        let scripts = FakeScripts()
        let registry = ToolRegistry(integrations: [MailIntegration(scripts: scripts, access: FakeAutomation())])
        do {
            _ = try await registry.run("mail.draft", ["to": ["Pablo"], "subject": "Hi", "body": "Hello"])
            XCTFail()
        } catch {}
        XCTAssertTrue(scripts.calls.isEmpty)
    }
    func testMessagesDraftNeverSendsAndSubmissionIsSingleUse() async throws {
        let scripts = FakeScripts()
        scripts.on(MessagesScripts.recipient, returns: Rec.fields("real-id", "Pablo", "+441234567890", "account-id"))
        scripts.on(MessagesScripts.send, returns: "submitted")
        let registry = ToolRegistry(integrations: [MessagesIntegration(scripts: scripts, access: FakeAutomation())])
        let draft = try await registry.run(
            "messages.draft", ["recipient_id": "real-id", "body": "Ten minutes late\nSee you soon"])
        let id = try XCTUnwrap(draft.output?.data?["draft_id"]?.stringValue)
        XCTAssertTrue(scripts.calls(to: MessagesScripts.send).isEmpty)
        let review = try await registry.run("messages.send", ["draft_id": .string(id)])
        let confirmation = try XCTUnwrap(review.confirmation)
        XCTAssertTrue(confirmation.prompt.contains("+441234567890"))
        let outcome = try await registry.run(
            "messages.send", confirmation.call.arguments, context: executionContext(confirmed: true))
        XCTAssertFalse(try XCTUnwrap(outcome.output).verification.isVerified)
        XCTAssertEqual(
            scripts.calls(to: MessagesScripts.send).first?.arguments,
            ["real-id", "+441234567890", "account-id", "Ten minutes late\nSee you soon"])
        do {
            _ = try await registry.run(
                "messages.send", confirmation.call.arguments, context: executionContext(confirmed: true))
            XCTFail()
        } catch {}
        XCTAssertEqual(scripts.calls(to: MessagesScripts.send).count, 1)
    }
    func testMessagesUncertainSubmissionConsumesDraft() async throws {
        let scripts = FakeScripts()
        scripts.on(MessagesScripts.recipient, returns: Rec.fields("real-id", "Pablo", "+441234567890", "account-id"))
        scripts.on(MessagesScripts.send, failsWith: AppleScriptFailure(kind: .timeout, code: nil, message: "Timeout"))
        let registry = ToolRegistry(integrations: [MessagesIntegration(scripts: scripts, access: FakeAutomation())])
        let draft = try await registry.run("messages.draft", ["recipient_id": "real-id", "body": "Hi"])
        let review = try await registry.run("messages.send", ["draft_id": draft.output!.data!["draft_id"]!])
        let args = review.confirmation!.call.arguments
        for _ in 0..<2 {
            do {
                _ = try await registry.run("messages.send", args, context: executionContext(confirmed: true))
                XCTFail()
            } catch {}
        }
        XCTAssertEqual(scripts.calls(to: MessagesScripts.send).count, 1)
    }
}
