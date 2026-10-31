import XCTest
import MorrowCore
@testable import MorrowApp

final class WorkingDraftTests: XCTestCase {
    @MainActor private func fixture() async throws -> (AppModel, AgentRun, AgentArtifact, ComposeDraft) {
        let model = AppModel(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), notifications: WorkingDraftNotifications())
        model.settings.enabled = false; model.workspacePreferences.memoryEnabled = false
        let run = AgentRun(title: "项目回复", instruction: "准备回复", phase: .waitingUser)
        await model.saveRun(run); model.selectedRunID = run.id; model.workspacePage = .desk
        var draft = ComposeDraft(); draft.accountID = "work"; draft.to = "lin@example.com"; draft.subject = "项目核对"; draft.body = "原始正文"
        await model.saveDraft(draft)
        let artifact = AgentArtifact(runID: run.id, title: draft.subject, kind: .draft, content: draft.body, linkedDraftID: draft.id)
        await model.saveArtifact(artifact); model.activateWorkingDraft(draft, artifactID: artifact.id)
        return (model, run, artifact, draft)
    }
    @MainActor func testInlineContextCapturesUnsavedInputAndDraftArtifactIdentity() async throws {
        let (model, run, artifact, draft) = try await fixture(); defer { try? FileManager.default.removeItem(at: model.store.root) }
        var unsaved = draft; unsaved.body = "用户尚未保存的正文"; unsaved.to = "new@example.com"
        model.activateWorkingDraft(unsaved, artifactID: artifact.id)
        let context = model.currentContext
        XCTAssertEqual(context.page, "desk"); XCTAssertEqual(context.runID, run.id); XCTAssertEqual(context.draftID, draft.id); XCTAssertEqual(context.artifactID, artifact.id); XCTAssertEqual(context.accountID, "work")
        XCTAssertTrue(model.isDraftEdit("把这份草稿改成更简短的回复", context: context))
        let snapshot = try await model.sidebarDraft(id: context.draftID)
        XCTAssertEqual(snapshot.body, unsaved.body); XCTAssertEqual(snapshot.to, unsaved.to)
        XCTAssertEqual(model.drafts.first?.body, "原始正文")
    }
    @MainActor func testAIEditCommitsDraftArtifactAndWorkingBufferAndOldViewCannotOverwrite() async throws {
        let (model, _, artifact, draft) = try await fixture(); defer { try? FileManager.default.removeItem(at: model.store.root) }
        var unsaved = draft; unsaved.body = "用户当前正文"; model.activateWorkingDraft(unsaved, artifactID: artifact.id)
        let snapshot = try await model.sidebarDraft(id: draft.id)
        let receipt = try await model.applySidebarDraftEdit(.init(type: "updateDraft", text: "实际AI修改", kind: draft.id), snapshot: snapshot)
        XCTAssertTrue(receipt.contains("已更新")); XCTAssertEqual(model.workingDraft?.body, "实际AI修改"); XCTAssertEqual(model.drafts.count, 1)
        XCTAssertEqual(model.agentArtifacts.first?.content, "实际AI修改")
        await model.finishWorkingDraft(unsaved, baseline: draft, artifactID: artifact.id)
        XCTAssertNil(model.workingDraft)
        XCTAssertEqual(model.drafts.first?.body, "实际AI修改"); XCTAssertEqual(model.agentArtifacts.first?.content, "实际AI修改")
        let storedDraft = try await model.store.object(ComposeDraft.self, kind: "draft", id: draft.id)
        let storedArtifact = try await model.store.object(AgentArtifact.self, kind: "agent-artifact", id: artifact.id)
        XCTAssertEqual(storedDraft?.body, "实际AI修改"); XCTAssertEqual(storedArtifact?.content, "实际AI修改"); XCTAssertEqual(storedArtifact?.linkedDraftID, draft.id)
        // Repeated disappearance from an old view still cannot put its local copy back.
        await model.finishWorkingDraft(unsaved, baseline: draft, artifactID: artifact.id)
        XCTAssertEqual(model.drafts.first?.body, "实际AI修改")
    }
    @MainActor func testConcurrentUnsavedUserEditKeepsOriginalAndArtifactAndSavesAISuggestion() async throws {
        let (model, _, artifact, draft) = try await fixture(); defer { try? FileManager.default.removeItem(at: model.store.root) }
        let snapshot = try await model.sidebarDraft(id: draft.id)
        var user = draft; user.body = "等待时用户继续编辑"; user.to = "changed@example.com"; model.activateWorkingDraft(user, artifactID: artifact.id)
        let receipt = try await model.applySidebarDraftEdit(.init(type: "updateDraft", text: "AI建议", kind: draft.id), snapshot: snapshot)
        XCTAssertTrue(receipt.contains("另")); XCTAssertEqual(model.drafts.count, 2)
        XCTAssertEqual(model.workingDraft?.body, user.body); XCTAssertEqual(model.drafts.first(where: { $0.id == draft.id })?.to, user.to)
        XCTAssertEqual(model.agentArtifacts.first?.content, user.body); XCTAssertEqual(model.agentArtifacts.first?.linkedDraftID, draft.id)
        XCTAssertEqual(model.drafts.first(where: { $0.id != draft.id })?.body, "AI建议")
        let original = try await model.store.object(ComposeDraft.self, kind: "draft", id: draft.id); XCTAssertEqual(original?.body, user.body)
    }
    @MainActor func testPinnedWorkDraftCanBeUpdatedAfterLeavingPrimaryView() async throws {
        let (model, _, artifact, draft) = try await fixture(); defer { try? FileManager.default.removeItem(at: model.store.root) }
        let pinned = model.currentContext
        var unsaved = draft; unsaved.body = "离开前未保存的内容"; model.activateWorkingDraft(unsaved, artifactID: artifact.id)
        await model.finishWorkingDraft(unsaved, baseline: draft, artifactID: artifact.id)
        model.workspacePage = .people
        let snapshot = try await model.sidebarDraft(id: pinned.draftID)
        _ = try await model.applySidebarDraftEdit(.init(type: "updateDraft", text: "固定原稿的新内容", kind: draft.id), snapshot: snapshot)
        XCTAssertEqual(model.drafts.first?.body, "固定原稿的新内容"); XCTAssertEqual(model.agentArtifacts.first?.content, "固定原稿的新内容"); XCTAssertNil(model.composer)
    }
    @MainActor func testDeliveryStatesNeverBecomeEditableWorkingOriginals() async throws {
        let (model, _, artifact, draft) = try await fixture(); defer { try? FileManager.default.removeItem(at: model.store.root) }
        for state in ["sent", "queued", "sending", "uncertain"] {
            var immutable = draft; immutable.state = state; immutable.scheduledAt = Date().addingTimeInterval(60)
            // Terminal states are receipts from transport, not editable Save Draft input.
            try await model.store.save(immutable, kind: "draft", id: immutable.id)
            if let i = model.drafts.firstIndex(where: { $0.id == immutable.id }) { model.drafts[i] = immutable }
            await model.saveDraft(draft)
            XCTAssertNotNil(model.error); model.error = nil
            model.workingDraft = nil; model.workingArtifactID = nil
            model.activateWorkingDraft(immutable, artifactID: artifact.id)
            XCTAssertNil(model.currentContext.draftID)
            let count = model.drafts.count
            _ = try await model.applySidebarDraftEdit(.init(type: "updateDraft", text: "另存建议", kind: draft.id), snapshot: immutable)
            XCTAssertEqual(model.drafts.first(where: { $0.id == draft.id })?.state, state); XCTAssertEqual(model.drafts.count, count + 1)
            let suggestion = try XCTUnwrap(model.drafts.last); XCTAssertEqual(suggestion.state, "draft"); XCTAssertNil(suggestion.scheduledAt)
        }
    }
}
@MainActor private final class WorkingDraftNotifications: MailNotificationManaging {
    func removePending(_ ids: [String]) {}; func requestAuthorization() async throws -> Bool { false }; func add(id: String, title: String, body: String, at date: Date?) async throws {}
}
