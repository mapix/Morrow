import XCTest
import MorrowCore
@testable import MorrowApp

final class LiveScopedWorkTests: XCTestCase {
    @MainActor func testLocalModelProposesWorkOnlyForCapturedContact() async throws {
        guard ProcessInfo.processInfo.environment["MORROW_LIVE_CONTEXT"] == "1" else { throw XCTSkip("Set MORROW_LIVE_CONTEXT for actual local model agreement") }
        let model = AppModel(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), notifications: ScopedWorkNotifications())
        defer { try? FileManager.default.removeItem(at: model.store.root) }
        model.workspacePreferences.memoryEnabled = false; model.settings.autoAnalyze = false
        model.settings.provider = "ollama"; model.settings.model = "qwen3.8:27b-mlx"
        var account = MailAccount(); account.id = "demo"; account.email = "me@example.com"; account.isDemo = true; model.accounts = [account]
        let selected = MailMessage(accountID: account.id, from: .init(name: "林舟", email: "lin@example.com"), subject: "合同材料待确认", text: "请核对合同附件清单，周一前告知缺失项。")
        let unrelated = MailMessage(accountID: account.id, from: .init(name: "其他客户", email: "other@example.com"), subject: "无关报价", text: "请核对其他项目报价。")
        model.mails = [selected, unrelated]
        let context = WorkspaceContext(page: "people", label: "林舟的全部往来", mailIDs: [selected.id], contactEmail: "lin@example.com")
        await model.proposeWork("持续整理这个人的待回复事项，只生成待办简报，不发送邮件。", context: context)
        XCTAssertNil(model.error, model.error ?? "")
        let run = try XCTUnwrap(model.agentRuns.first)
        let agreement = try XCTUnwrap(run.agreement)
        XCTAssertEqual(run.phase, .waitingUser)
        XCTAssertTrue(agreement.contains(selected)); XCTAssertFalse(agreement.contains(unrelated))
        XCTAssertEqual(agreement.hostScope?.contactEmail, "lin@example.com")
        XCTAssertTrue(agreement.hostScope?.allowsFuture ?? false)
        XCTAssertTrue(model.drafts.isEmpty)
        let stored = try await model.store.object(AgentRun.self, kind: "agent-run", id: run.id)
        XCTAssertEqual(stored?.agreement?.hostScope, agreement.hostScope)
        print("LOCAL_SCOPED_AGREEMENT: selected=1 unrelated=0 phase=waitingUser; actual model output and persisted host ceiling verified")
    }
}
@MainActor private final class ScopedWorkNotifications: MailNotificationManaging {
    func removePending(_ ids: [String]) {}
    func requestAuthorization() async throws -> Bool { false }
    func add(id: String, title: String, body: String, at date: Date?) async throws {}
}
