import XCTest
import MorrowCore
@testable import MorrowApp

final class PerformanceIntegrationTests: XCTestCase {
    @MainActor func testMetadataReloadPreservesFullProfileAndReplyEvidence() async throws {
        let model = fixture(); defer { model.contactRefreshTask?.cancel(); try? FileManager.default.removeItem(at: model.store.root) }
        let body = String(repeating: "ordinary line\n", count: 100) + "FULL_TAIL_EVIDENCE_SENTINEL"
        var message = MailMessage(accountID: "demo", from: .init(name: "Client", email: "client@example.invalid"), subject: "Evidence", text: body)
        message.id = "fixture"; message.messageID = "<fixture@example.invalid>"; message.html = "<p>FULL_HTML_SENTINEL</p>"
        let full = try await model.store.upsert(message)
        await model.reload(); await model.refreshContactProfiles()
        let displayed = try XCTUnwrap(model.mailByID(full.id))
        XCTAssertEqual(displayed.contentAvailability, .preview); XCTAssertTrue(displayed.html.isEmpty); XCTAssertLessThanOrEqual(displayed.text.count, 300)
        let profile = try XCTUnwrap(model.contactProfiles.first)
        XCTAssertEqual(profile.fingerprint, ContactProfileBuilder.build(mails: [full], accounts: model.accounts, manual: []).first?.fingerprint)
        let before = try await model.store.profileInventoryFingerprint()
        await model.markRead(displayed, true)
        let after = try await model.store.profileInventoryFingerprint(); XCTAssertEqual(before, after)
        await model.compose(replyTo: displayed)
        XCTAssertTrue(model.composer?.body.contains("FULL_TAIL_EVIDENCE_SENTINEL") == true)
        let stored = try await model.store.message(full.id); XCTAssertEqual(stored?.html, full.html); XCTAssertEqual(stored?.text, body)
    }
    @MainActor func testBatchStarsAndLabelsUseMetadataAndUndoPreservesOtherState() async throws {
        let model = fixture(); defer { model.contactRefreshTask?.cancel(); try? FileManager.default.removeItem(at: model.store.root) }
        var messages: [MailMessage] = []
        for i in 0..<110 {
            var mail = MailMessage(accountID: "demo", from: .init(email: "client@example.invalid"), subject: "Fixture \(i)", text: "Original body \(i)")
            mail.id = "message-\(i)"; mail.messageID = "<message-\(i)@example.invalid>"; mail.labels = ["before"]; mail.isStarred = i == 0
            messages.append(try await model.store.upsert(mail))
        }
        await model.reload(); let ids = Set(messages.map(\.id))
        await model.batch(ids, action: .star(true)); XCTAssertTrue(model.mails.allSatisfy(\.isStarred))
        await model.undo(); XCTAssertEqual(model.mails.filter(\.isStarred).map(\.id), ["message-0"])
        await model.batch(ids, action: .label("new-label")); XCTAssertTrue(model.mails.allSatisfy { $0.labels == ["before", "new-label"] })
        await model.undo(); XCTAssertTrue(model.mails.allSatisfy { $0.labels == ["before"] })
        let stored = try await model.store.message("message-5"); XCTAssertEqual(stored?.text, "Original body 5")
    }
    @MainActor private func fixture() -> AppModel {
        let model = AppModel(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        model.settings.enabled = false; model.workspacePreferences.memoryEnabled = false
        var account = MailAccount(); account.id = "demo"; account.email = "owner@example.invalid"; account.isDemo = true
        model.accounts = [account]; model.folders = [.init(accountID: account.id, path: "INBOX", role: "inbox")]
        return model
    }
}
