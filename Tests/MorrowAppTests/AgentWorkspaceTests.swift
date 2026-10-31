import XCTest
import MorrowCore
@testable import MorrowApp

final class AgentWorkspaceTests: XCTestCase {
    @MainActor func testMissionOutputAndDecisionPersistAndDemoAdoptionDoesNotUseSMTP() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(root: root, notifications: WorkspaceTestNotifications()); model.settings.enabled = false; model.isDemo = true
        var account = MailAccount(); account.id = "demo"; account.email = "you@example.com"; account.isDemo = true; model.accounts = [account]
        let run = AgentRun(title: "项目跟进", instruction: "备好回复", phase: .working, isDemo: true); await model.saveRun(run)
        await model.addStep(run.id, title: "读取来源", tool: "邮件", detail: "已读取1封", sourceIDs: ["source"])
        var draft = ComposeDraft(); draft.accountID = "demo"; draft.to = "team@example.com"; draft.subject = "回复评审"; draft.body = "收到，我会先确认日程。"; await model.saveDraft(draft)
        await model.completeRunOutput(run.id, draft: draft, text: "", sourceIDs: ["source"])
        let decision = try XCTUnwrap(model.pendingDecisions.first); XCTAssertEqual(model.agentRuns.first?.phase, .waitingUser)
        await model.updateRun(run.id, phase: .working)
        await model.answerDecision(decision, adopt: true)
        XCTAssertEqual(model.agentDecisions.first?.state, "pending"); XCTAssertFalse(model.mails.contains { $0.folder == "Sent" })
        await model.updateRun(run.id, phase: .waitingUser)
        await model.answerDecision(decision, adopt: true)
        XCTAssertEqual(model.agentRuns.first?.phase, .waitingReply); XCTAssertEqual(model.agentDecisions.first?.state, "accepted")
        XCTAssertTrue(model.mails.contains { $0.folder == "Sent" && $0.subject == draft.subject })
        let store = try MailStore(root: root); let artifacts = try await store.load(AgentArtifact.self, kind: "agent-artifact"); let runs = try await store.load(AgentRun.self, kind: "agent-run")
        XCTAssertEqual(artifacts.first?.linkedDraftID, draft.id); XCTAssertEqual(runs.first?.steps.count, 2)
    }
    func testGeneratedBodyRemovesEmailHeaderAndPlaceholder() {
        let result = GeneratedMailBody.normalize("主题：回复评审\n\n收到。\n\n[您的姓名]")
        XCTAssertEqual(result, "收到。")
    }
    @MainActor func testEditedAgreementChangesFutureInstructionAndStartsOnlyAfterAcceptance() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(root: root, notifications: WorkspaceTestNotifications()); model.settings.enabled = false
        var delegation = Delegation(); delegation.active = false; delegation.title = "原目标"; await model.saveDelegation(delegation)
        let run = try XCTUnwrap(model.agentRuns.first)
        let agreement = WorkAgreement(goal: "核对新报价", doneWhen: "取得客户确认", scope: "该客户邮件", boundaries: ["不承诺价格"], steps: ["比较报价", "备好回复"], kind: "watch", match: "报价")
        await model.updateAgreement(agreement, runID: run.id)
        XCTAssertFalse(model.delegations.first?.active ?? true); XCTAssertTrue(model.delegations.first?.instruction.contains("取得客户确认") ?? false); XCTAssertTrue(model.delegations.first?.instruction.contains("不承诺价格") ?? false)
        var decision = AgentDecision(runID: run.id, title: "交给你吗", detail: agreement.doneWhen); decision.kind = "agreement"; decision.delegationID = delegation.id; await model.saveDecision(decision)
        await model.toggleRun(run); XCTAssertFalse(model.delegations.first?.active ?? true)
        await model.answerDecision(decision, adopt: true)
        XCTAssertEqual(model.delegations.first?.active, true); XCTAssertEqual(model.agentDecisions.first?.state, "accepted"); XCTAssertEqual(model.agentRuns.first?.phase, .queued)
    }
    @MainActor func testOngoingReportUpdatesSameDocumentAndEndsOnlyWhenUserClosesWork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(root: root, notifications: WorkspaceTestNotifications()); model.settings.enabled = false
        var delegation = Delegation(); delegation.active = true; delegation.title = "核对合同"; await model.saveDelegation(delegation)
        let run = try XCTUnwrap(model.agentRuns.first)
        await model.completeRunOutput(run.id, draft: nil, text: "验收10天", sourceIDs: ["old", "new"])
        let identity = try XCTUnwrap(model.agentArtifacts.first?.id)
        XCTAssertEqual(model.agentRuns.first?.phase, .monitoring)
        await model.completeRunOutput(run.id, draft: nil, text: "补充改为7天", sourceIDs: ["old", "new", "supplement"])
        XCTAssertEqual(model.agentArtifacts.count, 1); XCTAssertEqual(model.agentArtifacts.first?.id, identity)
        XCTAssertEqual(model.agentArtifacts.first?.revisions?.first?.content, "验收10天")
        XCTAssertEqual(model.agentArtifacts.first?.content, "补充改为7天")
        let store = try MailStore(root: root); let stored = try await store.load(AgentArtifact.self, kind: "agent-artifact")
        XCTAssertEqual(stored.first?.revisions?.count, 1)
        await model.finishWork(run.id)
        XCTAssertEqual(model.agentRuns.first?.phase, .completed); XCTAssertEqual(model.delegations.first?.active, false)
    }
    @MainActor func testEmptyScopeWaitsWithoutInventingACompletedReport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(root: root, notifications: WorkspaceTestNotifications()); model.settings.enabled = true
        var delegation = Delegation(); delegation.active = true; delegation.includeExisting = true; await model.saveDelegation(delegation)
        await model.runDelegations(forceID: delegation.id)
        XCTAssertEqual(model.agentRuns.first?.phase, .monitoring); XCTAssertTrue(model.agentArtifacts.isEmpty)
        XCTAssertTrue(model.agentRuns.first?.summary.contains("没有可读取") ?? false)
    }
}
@MainActor private final class WorkspaceTestNotifications: MailNotificationManaging {
    func removePending(_ ids: [String]) {}
    func requestAuthorization() async throws -> Bool { false }
    func add(id: String, title: String, body: String, at date: Date?) async throws {}
}
