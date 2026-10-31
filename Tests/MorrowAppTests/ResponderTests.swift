import XCTest
import MorrowCore
@testable import MorrowApp

final class ResponderTests: XCTestCase {
    @MainActor func testNewMailAutomaticallyRespondsOnceAndDoesNotReplyToAutomaticMailOrCopies() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
        let model = AppModel(root:root,notifications:ResponderTestNotifications()); model.isDemo = true
        var account = MailAccount(); account.id = "demo"; account.email = "you@example.com"; account.isDemo = true; model.accounts = [account]
        var rule = MailResponder(); rule.title = "收到评审材料"; rule.sender = "team@example.com"; rule.subjectContains = "评审"; rule.response = "已收到{{subject}}。"; rule.delivery = "send"; rule.enabled = true
        try await model.saveResponder(rule)
        var incoming = MailMessage(accountID:"demo",from:.init(email:"team@example.com"),subject:"评审材料",text:"请核对"); incoming.messageID = "<one@example.com>"
        try await model.store.upsert(incoming); await model.reload(); await model.runResponders()
        XCTAssertEqual(model.responderReceipts.count,1); XCTAssertEqual(model.responderReceipts.first?.state,"simulated")
        XCTAssertEqual(model.mails.filter { $0.folder == "Sent" }.count,1)
        var copy = incoming; copy.id = "archive-copy"; copy.folder = "Archive"; try await model.store.upsert(copy); await model.reload(); await model.runResponders()
        XCTAssertEqual(model.responderReceipts.count,1)
        var automatic = incoming; automatic.id = "auto"; automatic.messageID = "<auto@example.com>"; automatic.raw = Data("Auto-Submitted: auto-replied\r\n\r\nHello".utf8)
        try await model.store.upsert(automatic); await model.reload(); await model.runResponders()
        XCTAssertEqual(model.responderReceipts.last?.state,"skipped"); XCTAssertEqual(model.mails.filter { $0.folder == "Sent" }.count,1)
        let sent = try XCTUnwrap(model.mails.first { $0.folder == "Sent" }); let raw = try await model.store.rawData(sent)
        XCTAssertTrue(String(decoding:raw,as:UTF8.self).contains("Auto-Submitted: auto-replied"))
    }
    @MainActor func testOpenUIResponderActionValidatesScopedFieldsAndDoesNotRunDuringRenderOrTwice() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
        let model = AppModel(root:root,notifications:ResponderTestNotifications()); model.settings.enabled = false
        let source = "root = Form(\"responder\", [Button(\"保存并启用响应器\", @SaveResponder())])"
        let page = OpenUIInteraction(source:source); await model.saveOpenUIInteraction(page)
        _ = try OpenUILang.parse(source).root(); XCTAssertTrue(model.responders.isEmpty)
        let event = OpenUIActionEvent(type:"SaveResponder",formName:"responder",formState:["other":["sender":.init(value:.string("wrong@example.com"))],"responder":["title":.init(value:.string("项目回复")),"sender":.init(value:.string("team@example.com")),"subject":.init(value:.string("评审")),"response":.init(value:.string("收到，谢谢。")),"delivery":.init(value:.string("send"))]])
        try await model.handleOpenUIAction(event,interactionID:page.id,buttonLabel:"保存并启用响应器")
        XCTAssertEqual(model.responders.count,1); XCTAssertEqual(model.responders.first?.sender,"team@example.com"); XCTAssertNotNil(model.openUIInteractions.first?.completedAt)
        do { try await model.handleOpenUIAction(event,interactionID:page.id,buttonLabel:"保存并启用响应器"); XCTFail("Repeated event must not create another rule") } catch {}
        XCTAssertEqual(model.responders.count,1)
    }
    @MainActor func testResponderSettingsPauseLinkedWorkAndBlockNewMailUntilResumed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(root: root, notifications: ResponderTestNotifications()); model.isDemo = true
        var account = MailAccount(); account.id = "demo"; account.email = "you@example.com"; account.isDemo = true
        model.accounts = [account]
        var rule = MailResponder(); rule.title = "项目材料"; rule.sender = "team@example.com"; rule.subjectContains = "评审"; rule.response = "收到，谢谢。"; rule.delivery = "send"; rule.enabled = true
        try await model.saveResponder(rule)
        var run = AgentRun(title: "接住项目材料", instruction: "收到材料后回复", phase: .monitoring, isDemo: true)
        run.responderID = rule.id; await model.saveRun(run)
        await model.setResponderEnabled(try XCTUnwrap(model.responders.first), false)
        XCTAssertEqual(model.agentRuns.first(where: { $0.id == run.id })?.phase, .paused)
        let storedPaused = try await model.store.object(AgentRun.self, kind: "agent-run", id: run.id)
        XCTAssertEqual(storedPaused?.phase, .paused)
        var incoming = MailMessage(accountID: "demo", from: .init(email: "team@example.com"), subject: "评审材料", text: "请核对")
        incoming.messageID = "<paused@example.com>"
        try await model.store.upsert(incoming); await model.reload(); await model.runResponders()
        XCTAssertTrue(model.responderReceipts.isEmpty)
        XCTAssertFalse(model.mails.contains(where: { $0.folder == "Sent" }))
        await model.setResponderEnabled(try XCTUnwrap(model.responders.first), true)
        XCTAssertEqual(model.agentRuns.first(where: { $0.id == run.id })?.phase, .monitoring)
        await model.runResponders()
        XCTAssertEqual(model.responderReceipts.count, 1)
        XCTAssertEqual(model.responderReceipts.first?.state, "simulated")
        XCTAssertEqual(model.agentRuns.first(where: { $0.id == run.id })?.phase, .monitoring)
    }
    func testReplyToChangesNeverWidenAutomaticRecipientScope() {
        var rule = MailResponder(); rule.enabled = true; rule.delivery = "send"; rule.subjectContains = "评审"
        let mail = MailMessage(accountID:"demo",from:.init(email:"team@example.com"),subject:"评审",text:"")
        var draft = ComposeDraft(); draft.to = "other@example.com"
        XCTAssertFalse(ResponderPolicy.canSend(draft,rule:rule,mail:mail)); draft.to = "team@example.com"; XCTAssertTrue(ResponderPolicy.canSend(draft,rule:rule,mail:mail))
    }
}
@MainActor private final class ResponderTestNotifications: MailNotificationManaging {
    func removePending(_ ids:[String]) {}
    func requestAuthorization() async throws -> Bool { false }
    func add(id:String,title:String,body:String,at date:Date?) async throws {}
}
