import XCTest
import MorrowCore
@testable import MorrowApp

final class SessionsMemoryTests: XCTestCase {
    @MainActor func makeModel() -> AppModel { let model = AppModel(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),notifications:SessionNotifications()); model.settings.enabled = false; model.workspacePreferences.memoryEnabled = false; return model }
    @MainActor func testSessionsKeepDraftsMessagesAndBackgroundReceiptsSeparate() async throws {
        let model = makeModel(); defer { try? FileManager.default.removeItem(at:model.store.root) }
        await model.restoreChatSessions(); let first = model.activeSessionID
        model.chatInput = "会话A未发送内容"
        let second = await model.createChatSession(title:"会话B"); model.chatInput = "会话B未发送内容"
        model.switchChatSession(first); XCTAssertEqual(model.chatInput,"会话A未发送内容")
        await ChatTaskContext.$sessionID.withValue(first) {
            try? await model.recordChat(PartnerChat(role:"user",text:"A提交"))
            model.switchChatSession(second)
            try? await model.recordChat(PartnerChat(role:"partner",text:"A的后台回执"))
        }
        XCTAssertTrue(model.visibleChat.isEmpty); XCTAssertEqual(model.chatInput,"会话B未发送内容")
        model.switchChatSession(first); XCTAssertEqual(model.visibleChat.count,2); XCTAssertTrue(model.visibleChat.allSatisfy { $0.sessionID == first })
        let stored = try await model.store.load(PartnerChat.self,kind:"chat"); XCTAssertEqual(stored.last?.sessionID,first)
    }
    @MainActor func testChatContactKnowledgePersistsAsManagedMemoryAndSupersedes() async throws {
        let model = makeModel(); defer { try? FileManager.default.removeItem(at:model.store.root) }
        await model.restoreChatSessions()
        var account = MailAccount(); account.email = "me@example.com"; model.accounts = [account]
        let mail = MailMessage(accountID:account.id,from:.init(name:"林舟",email:"lin@example.com"),subject:"项目",text:"请核对")
        try await model.store.upsert(mail); await model.reload(); model.selectProfile("lin@example.com")
        let context = model.currentContext
        await model.rememberFromChat("林舟是客户负责人",context:context,user:"记住：林舟是客户负责人")
        await model.rememberFromChat("林舟不是客户，是内部项目负责人",context:context,user:"纠正：林舟不是客户，是内部项目负责人")
        XCTAssertEqual(model.memories.filter { $0.status == "active" }.count,1)
        XCTAssertEqual(model.memories.filter { $0.status == "superseded" }.count,1)
        let current = try XCTUnwrap(model.memories.first { $0.status == "active" }); XCTAssertEqual(current.scopeID,"lin@example.com"); XCTAssertNotNil(current.sourceChatID)
        let stored = try await model.store.load(AgentMemory.self,kind:"agent-memory"); XCTAssertEqual(stored.count,2)
        await model.changeMemoryState(current.id,status:"paused")
        XCTAssertTrue(MemoryRanking.search(model.memories,query:"",sessionID:model.activeSessionID,contactEmail:"lin@example.com").isEmpty)
        await model.changeMemoryState(current.id,status:"active")
        XCTAssertEqual(MemoryRanking.search(model.memories,query:"",sessionID:model.activeSessionID,contactEmail:"lin@example.com").count,1)
    }
    @MainActor func testMemoryQuestionNeverWritesAndAccountSelectionScopesInbox() async throws {
        let model = makeModel(); defer { try? FileManager.default.removeItem(at:model.store.root) }
        XCTAssertNil(model.explicitMemoryContent("记住了吗？")); XCTAssertNil(model.explicitMemoryContent("不要纠正这个人")); XCTAssertEqual(model.explicitMemoryContent("补充：负责交付"),"负责交付")
        var a = MailAccount(); a.id = "a"; a.email = "a@example.com"; var b = a; b.id = "b"; b.email = "b@example.com"; model.accounts = [a,b]
        model.folders = [.init(accountID:"a",path:"INBOX",role:"inbox"),.init(accountID:"b",path:"INBOX",role:"inbox")]
        let one = MailMessage(accountID:"a",from:.init(email:"x@example.com"),subject:"A",text:"")
        var two = MailMessage(accountID:"b",from:.init(email:"x@example.com"),subject:"B",text:""); two.isRead = true
        model.mails = [one,two]
        model.chooseMailbox("a"); XCTAssertEqual(model.visibleMails.map(\.subject),["A"]); XCTAssertEqual(model.inboxUnreadCount("a"),1)
        model.chooseMailbox(nil); XCTAssertEqual(model.visibleMails.count,2); XCTAssertEqual(model.inboxUnreadCount(nil),1)
    }
    @MainActor func testCapturedSubmissionSurvivesSessionSwitchAndKeepsNewDraft() async throws {
        let model = makeModel(); defer { try? FileManager.default.removeItem(at:model.store.root) }
        await model.restoreChatSessions(); let a = model.activeSessionID
        let snapshot = ChatSubmission(sessionID:a,instruction:"打开联系人",materials:[],context:.init(page:"global",label:"全邮箱"),newWork:false)
        let b = await model.createChatSession(title:"B"); model.chatInput = "B的未发文字"
        await ChatTaskContext.$sessionID.withValue(a) { await model.submitSidebarChat(snapshot) }
        XCTAssertEqual(model.activeSessionID,b); XCTAssertEqual(model.chatInput,"B的未发文字"); XCTAssertTrue(model.visibleChat.isEmpty)
        XCTAssertEqual(model.chat.filter { $0.sessionID == a }.count,2)
    }
    @MainActor func testDensityAndReplySenderPersistWithMultipleAccounts() async throws {
        let model = makeModel(); defer { try? FileManager.default.removeItem(at:model.store.root) }
        model.workspacePreferences.density = "compact"; await model.savePreferences()
        let preferences = try await model.store.load(WorkspacePreferences.self,kind:"workspace-preferences"); XCTAssertEqual(preferences.first?.density,"compact")
        var account = MailAccount(); account.id = "work"; account.email = "work@example.com"; account.isDemo = true; model.accounts = [account]
        let mail = MailMessage(accountID:"work",from:.init(email:"partner@example.com"),subject:"工作邮件",text:"核对")
        await model.compose(replyTo:mail); XCTAssertEqual(model.composer?.accountID,"work"); XCTAssertEqual(model.composer?.to,"partner@example.com")
    }
    @MainActor func testMigrationKeepsLegacyMessagesExactlyOnce() async throws {
        let model = makeModel(); defer { try? FileManager.default.removeItem(at:model.store.root) }
        let legacy = PartnerChat(role:"user",text:"旧消息"); model.chat = [legacy]
        await model.restoreChatSessions(); await model.restoreChatSessions()
        XCTAssertEqual(model.chatSessions.count,1); XCTAssertEqual(model.visibleChat.count,1); XCTAssertEqual(model.visibleChat[0].text,"旧消息")
    }
}
@MainActor private final class SessionNotifications: MailNotificationManaging {
    func removePending(_ ids:[String]) {}; func requestAuthorization() async throws -> Bool { false }; func add(id:String,title:String,body:String,at date:Date?) async throws {}
}
