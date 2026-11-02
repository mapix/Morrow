import XCTest
@testable import MorrowCore

final class DraftDeliveryMutationTests: XCTestCase {
    private func store() throws -> MailStore { try MailStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("morrow-draft-mutation-" + UUID().uuidString)) }
    func testLateEditorCannotOverwriteClaimedDeliveryOrArtifact() async throws {
        let store = try store(); var draft = ComposeDraft(); draft.body = "Reviewed body"
        let artifact = AgentArtifact(runID: "run", title: "Reply", kind: .draft, content: draft.body, linkedDraftID: draft.id)
        try await store.commitWorkingDraft(draft, artifact: artifact)
        try await store.queueReviewedDraft(draft)
        let claimed = try await store.claimDraft(draft.id); XCTAssertEqual(claimed?.state, "sending")
        var stale = draft; stale.body = "Stale editor text"
        var staleArtifact = artifact; staleArtifact.content = stale.body
        do { try await store.commitWorkingDraft(stale, artifact: staleArtifact); XCTFail("A claimed delivery must not be editable") } catch {}
        do { try await store.queueReviewedDraft(stale); XCTFail("A claimed delivery must not be queued twice") } catch {}
        do { _ = try await store.cancelQueuedDraft(draft.id); XCTFail("A claimed delivery must not be canceled as queued") } catch {}
        do { try await store.discardEditableDraft(draft.id); XCTFail("A claimed delivery must not be discarded") } catch {}
        let saved = try await store.object(ComposeDraft.self, kind: "draft", id: draft.id)
        let output = try await store.object(AgentArtifact.self, kind: "agent-artifact", id: artifact.id)
        XCTAssertEqual(saved?.state, "sending"); XCTAssertEqual(saved?.body, "Reviewed body")
        XCTAssertEqual(output?.content, "Reviewed body")
    }
    func testQueuedDraftCanBeCanceledBeforeClaimAndEdited() async throws {
        let store = try store(); var draft = ComposeDraft(); draft.body = "Initial"
        try await store.commitWorkingDraft(draft, artifact: nil)
        try await store.queueReviewedDraft(draft, now: Date().addingTimeInterval(60))
        var restored = try await store.cancelQueuedDraft(draft.id)
        let claimed = try await store.claimDraft(draft.id); XCTAssertNil(claimed)
        restored.body = "Updated after cancellation"
        try await store.commitWorkingDraft(restored, artifact: nil)
        let saved = try await store.object(ComposeDraft.self, kind: "draft", id: draft.id)
        XCTAssertEqual(saved?.state, "draft"); XCTAssertEqual(saved?.body, restored.body)
    }
    func testDeliveryOwnerCommitsSMTPConfirmationWhileEditorRemainsBlocked() async throws {
        let store = try store(); var draft = ComposeDraft(); draft.accountID = "sender"; draft.body = "Reviewed body"
        try await store.commitWorkingDraft(draft, artifact: nil); try await store.queueReviewedDraft(draft)
        let claimed = try await store.claimDraft(draft.id), claim = try XCTUnwrap(claimed)
        var forged = claim; forged.body = "Content must not change during completion"
        let sent = try await store.finishDraftDelivery(forged, outcome: .sent)
        XCTAssertEqual(sent.state, "sent"); XCTAssertEqual(sent.body, draft.body)
        let receipt = try await store.object(DraftDeliveryReceipt.self, kind: "mail-delivery", id: draft.id)
        XCTAssertEqual(receipt?.messageID, "<" + draft.id + "@morrow.local>")
        do { try await store.commitWorkingDraft(draft, artifact: nil); XCTFail("Late editor must remain blocked") } catch {}
        let repeated = try await store.claimDraft(draft.id); XCTAssertNil(repeated)
        do { _ = try await store.finishDraftDelivery(claim, outcome: .uncertain); XCTFail("Confirmed delivery must not be downgraded") } catch {}
    }
    func testSyncedSentCopyRecoversInterruptedDeliveryButImportedCopyDoesNot() async throws {
        let store = try store(); var account = MailAccount(); account.id = "sender"; account.email = "sender@example.invalid"; account.isDemo = false
        var draft = ComposeDraft(); draft.accountID = account.id; draft.to = "target@example.invalid"; draft.subject = "Delivery test"; draft.body = "Synthetic body"
        try await store.commitWorkingDraft(draft, artifact: nil); try await store.queueReviewedDraft(draft)
        _ = try await store.claimDraft(draft.id)
        let folder = MailFolder(accountID: account.id, path: "Sent Items", role: "sent")
        var mail = MIMEParser.parse(try MIMEWriter.encode(draft, account: account), accountID: account.id, folder: folder.path)
        _ = try await store.upsert(mail)
        let imported = try await store.recoverConfirmedDraftDeliveries(accounts: [account], folders: [folder]); XCTAssertTrue(imported.isEmpty)
        mail.uid = 42; mail.uidValidity = 7; _ = try await store.upsert(mail)
        let recovered = try await store.recoverConfirmedDraftDeliveries(accounts: [account], folders: [folder])
        XCTAssertEqual(recovered.first?.state, "sent"); XCTAssertEqual(recovered.first?.id, draft.id)
        let repeatRecovery = try await store.recoverConfirmedDraftDeliveries(accounts: [account], folders: [folder]); XCTAssertTrue(repeatRecovery.isEmpty)
    }
}
