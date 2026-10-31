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
}
