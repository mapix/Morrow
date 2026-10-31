import XCTest
import MorrowCore
@testable import MorrowApp

final class WorkContextTests: XCTestCase {
    @MainActor private func makeModel() -> AppModel {
        let model = AppModel(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), notifications: WorkContextNotifications())
        model.settings.enabled = false; model.workspacePreferences.memoryEnabled = false
        var a = MailAccount(); a.id = "a"; a.email = "a@example.com"; var b = a; b.id = "b"; b.email = "b@example.com"; model.accounts = [a, b]
        return model
    }
    @MainActor func testCapturedContactAndEmptyMailboxKeepAccountCeiling() throws {
        let model = makeModel(); defer { try? FileManager.default.removeItem(at: model.store.root) }
        let original = MailMessage(accountID: "a", from: .init(email: "lin@example.com"), subject: "项目", text: "资料")
        model.mails = [original]
        let context = WorkspaceContext(page: "people", label: "林舟的全部往来", mailIDs: [original.id], contactEmail: "lin@example.com")
        let contact = try XCTUnwrap(model.workContextLimit(context, instruction: "持续整理这个人的待回复事项"))
        XCTAssertEqual(contact.accountIDs, ["a", "b"]); XCTAssertTrue(contact.allowsFuture)
        XCTAssertFalse(try XCTUnwrap(model.workContextLimit(context, instruction: "整理当前资料")).allowsFuture)
        XCTAssertFalse(try XCTUnwrap(model.workContextLimit(context, instruction: "整理过去的跟进记录")).allowsFuture)
        XCTAssertFalse(try XCTUnwrap(model.workContextLimit(context, instruction: "只处理已收到邮件，不关注新邮件")).allowsFuture)
        var inbox = original; inbox.messageID = "<same-mail>"; inbox.folder = "INBOX"
        var copy = inbox; copy.id = UUID().uuidString; copy.folder = "Archive"; model.mails = [copy, inbox]
        let selectedCopy = WorkspaceContext(page: "mail", label: "原邮件副本", mailIDs: [copy.id])
        XCTAssertTrue(try XCTUnwrap(model.workContextLimit(selectedCopy, instruction: "核对这封邮件")).containsExisting(inbox))
        var empty = WorkspaceContext(page: "mail-list", label: "邮箱A收件箱"); empty.accountID = "a"
        let mailbox = try XCTUnwrap(model.workContextLimit(empty, instruction: "持续关注项目新来信"))
        XCTAssertEqual(mailbox.accountIDs, ["a"]); XCTAssertTrue(mailbox.existingMailIDs.isEmpty)
        let futureA = MailMessage(accountID: "a", from: .init(email: "lin@example.com"), subject: "项目", text: "")
        var futureB = futureA; futureB.accountID = "b"
        XCTAssertTrue(mailbox.contains(futureA)); XCTAssertFalse(mailbox.contains(futureB))
    }
    @MainActor func testEditedAgreementCannotReplaceHostCeilingAndPersistsIt() async throws {
        let model = makeModel(); defer { try? FileManager.default.removeItem(at: model.store.root) }
        let selected = MailMessage(accountID: "a", from: .init(email: "lin@example.com"), subject: "项目", text: "")
        let other = MailMessage(accountID: "b", from: .init(email: "other@example.com"), subject: "项目", text: "")
        model.mails = [selected, other]
        var delegation = Delegation(); delegation.active = false; await model.saveDelegation(delegation)
        var run = try XCTUnwrap(model.agentRuns.first)
        var old = WorkAgreement(goal: "核对", doneWhen: "完成", scope: "指定邮件", boundaries: [], steps: [])
        old.hostScope = WorkContextLimit(kind: .selection, label: "指定邮件", existingMailIDs: [selected.id], accountIDs: ["a"])
        old.resolvedScope = WorkScope(sourceMailIDs: [selected.id]).validated(against: [selected, other]); run.agreement = old; await model.saveRun(run)
        var edited = old; edited.scope = "所有邮箱项目邮件"; edited.boundaries = []
        edited.hostScope = WorkContextLimit(kind: .mailbox, label: "全部", existingMailIDs: [selected.id, other.id], accountIDs: ["a", "b"], allowsFuture: true)
        edited.resolvedScope = WorkScope(sourceMailIDs: [selected.id, other.id], subjectTerms: ["项目"])
        await model.updateAgreement(edited, runID: run.id)
        let actual = try XCTUnwrap(model.agentRuns.first?.agreement)
        XCTAssertEqual(actual.hostScope, old.hostScope); XCTAssertTrue(actual.contains(selected)); XCTAssertFalse(actual.contains(other)); XCTAssertTrue(actual.boundaries.contains(old.hostScope!.boundary))
        XCTAssertTrue(model.workMatches(selected, delegation: delegation)); XCTAssertFalse(model.workMatches(other, delegation: delegation))
        let stored = try await model.store.object(AgentRun.self, kind: "agent-run", id: run.id)
        XCTAssertEqual(stored?.agreement?.hostScope, old.hostScope); XCTAssertFalse(stored?.agreement?.contains(other) ?? true)
    }
    @MainActor func testUnsupportedMaterialsAndAttachmentsSaveSubmittedConversationWithoutWork() async throws {
        let model = makeModel(); defer { try? FileManager.default.removeItem(at: model.store.root) }
        await model.restoreChatSessions(); let a = model.activeSessionID
        try await model.addChatData(Data("合同期限7天".utf8), name: "条款.txt", mime: "text/plain")
        let materials = model.chatMaterials
        let b = await model.createChatSession(title: "B"); model.chatInput = "B的未发送内容"
        let snapshot = ChatSubmission(sessionID: a, instruction: "持续核对这些资料", materials: materials, context: .init(page: "materials", label: "仅带入资料"), newWork: true)
        await ChatTaskContext.$sessionID.withValue(a) { await model.submitSidebarChat(snapshot) }
        XCTAssertTrue(model.agentRuns.isEmpty); XCTAssertTrue(model.delegations.isEmpty); XCTAssertEqual(model.activeSessionID, b); XCTAssertEqual(model.chatInput, "B的未发送内容")
        let submitted = model.chat.filter { $0.sessionID == a }; XCTAssertEqual(submitted.count, 2); XCTAssertEqual(submitted.first?.materials?.map(\.id), materials.map(\.id)); XCTAssertTrue(submitted.last?.text.contains("切回普通对话") ?? false)
        let attachmentContext = WorkspaceContext(page: "attachments", label: "所选附件", attachmentIDs: ["mail:attachment"])
        await model.submitSidebarChat(ChatSubmission(sessionID: b, instruction: "持续核对附件", materials: [], context: attachmentContext, newWork: true))
        XCTAssertTrue(model.visibleChat.last?.text.contains("不能只关注附件") ?? false); XCTAssertTrue(model.agentRuns.isEmpty)
    }
    @MainActor func testScopedResponderRequestCannotBypassSubmittedLimit() async throws {
        let model = makeModel(); defer { try? FileManager.default.removeItem(at: model.store.root) }
        await model.restoreChatSessions()
        let snapshot = ChatSubmission(sessionID: model.activeSessionID, instruction: "设置收到项目邮件自动回复", materials: [], context: .init(page: "people", label: "林舟", contactEmail: "lin@example.com"), newWork: true)
        await model.submitSidebarChat(snapshot)
        XCTAssertTrue(model.responders.isEmpty); XCTAssertTrue(model.openUIInteractions.isEmpty); XCTAssertTrue(model.agentRuns.isEmpty)
        XCTAssertEqual(model.visibleChat.count, 2); XCTAssertTrue(model.visibleChat.last?.text.contains("独立设置") ?? false)
    }
    @MainActor func testExplicitSessionMemoryOverridesCurrentContact() async throws {
        let model = makeModel(); defer { try? FileManager.default.removeItem(at: model.store.root) }
        await model.restoreChatSessions(); let a = model.activeSessionID
        let context = WorkspaceContext(page: "people", label: "林舟", contactEmail: "lin@example.com")
        await model.rememberFromChat("本会话用英文交流", context: context, user: "记住：本会话用英文交流")
        let saved = try XCTUnwrap(model.memories.first); XCTAssertEqual(saved.scope, .session); XCTAssertEqual(saved.scopeID, a)
        let b = await model.createChatSession(title: "B")
        XCTAssertTrue(MemoryRanking.search(model.memories, query: "英文", sessionID: b, contactEmail: "lin@example.com").isEmpty)
    }
}
@MainActor private final class WorkContextNotifications: MailNotificationManaging {
    func removePending(_ ids: [String]) {}; func requestAuthorization() async throws -> Bool { false }; func add(id: String, title: String, body: String, at date: Date?) async throws {}
}
