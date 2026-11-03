import XCTest
import MorrowCore
@testable import MorrowApp

final class ResponderTests: XCTestCase {
    @MainActor func testSkippedMailCanBeExplicitlyRetriedAfterDisablingHeaderAuthentication() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let model = responderFixtureModel(root); model.isDemo = true
        var account = MailAccount(); account.id = "demo"; account.email = "owner@example.com"; account.isDemo = true
        model.accounts = [account]; try await model.store.save(account, kind: "account", id: account.id)
        var rule = MailResponder(); rule.title = "Source matching"; rule.accountID = account.id; rule.sender = "team@example.com"; rule.response = "收到。"; rule.useAI = false; rule.enabled = true
        rule.requireAuthentication = true; rule.trustedAuthService = "mx.google.com"
        try await model.saveResponder(rule)
        var incoming = MailMessage(accountID: account.id, from: .init(email: "team@example.com"), subject: "Test", text: "Source")
        incoming.messageID = "<simple-source@example.com>"; incoming.raw = responderSourceRaw(incoming)
        try await model.store.upsert(incoming); await model.reload(); await model.runResponders()
        let skipped = try XCTUnwrap(model.responderReceipts.first); XCTAssertEqual(skipped.state, "skipped")
        rule = try XCTUnwrap(model.responders.first); rule.requireAuthentication = false; try await model.saveResponder(rule)
        await model.runResponders(); XCTAssertEqual(model.responderReceipts.first?.state, "skipped")
        await model.runResponders(retryReceiptID: skipped.id)
        XCTAssertEqual(model.responderReceipts.first?.state, "simulated", model.responderReceipts.first?.detail ?? "")
        XCTAssertEqual(model.responderReceipts.first?.attempts, 2)
    }
    @MainActor func testNewMailAutomaticallyRespondsOnceAndDoesNotReplyToAutomaticMailOrCopies() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
        let model = responderFixtureModel(root); model.isDemo = true
        var account = MailAccount(); account.id = "demo"; account.email = "you@example.com"; account.isDemo = true; model.accounts = [account]
        try await model.store.save(account, kind: "account", id: account.id)
        var rule = MailResponder(); rule.title = "收到评审材料"; rule.sender = "team@example.com"; rule.subjectContains = "评审"; rule.response = "已收到{{subject}}。"; rule.delivery = "send"; rule.enabled = true
        rule.accountID = "demo"; rule.requireAuthentication = false; rule.useAI = false
        try await model.saveResponder(rule)
        var incoming = MailMessage(accountID:"demo",from:.init(email:"team@example.com"),subject:"评审材料",text:"请核对"); incoming.messageID = "<one@example.com>"
        incoming.raw = responderSourceRaw(incoming)
        try await model.store.upsert(incoming); await model.reload(); await model.runResponders()
        XCTAssertEqual(model.responderReceipts.count,1); XCTAssertEqual(model.responderReceipts.first?.state,"simulated", model.responderReceipts.first?.detail ?? "")
        XCTAssertEqual(model.mails.filter { $0.folder == "Sent" }.count,1)
        var copy = incoming; copy.id = "archive-copy"; copy.folder = "Archive"; try await model.store.upsert(copy); await model.reload(); await model.runResponders()
        XCTAssertEqual(model.responderReceipts.count,1)
        var automatic = incoming; automatic.id = "auto"; automatic.messageID = "<auto@example.com>"; automatic.raw = Data("Auto-Submitted: auto-replied\r\n\r\nHello".utf8)
        try await model.store.upsert(automatic); await model.reload(); await model.runResponders()
        XCTAssertEqual(model.responderReceipts.last?.state,"skipped"); XCTAssertEqual(model.mails.filter { $0.folder == "Sent" }.count,1)
        let sent = try XCTUnwrap(model.mails.first { $0.folder == "Sent" }); let raw = try await model.store.rawData(sent)
        XCTAssertTrue(String(decoding:raw,as:UTF8.self).contains("Auto-Submitted: auto-replied"))
        let runID = try XCTUnwrap(model.responderReceipts.first?.runID)
        let run = try XCTUnwrap(model.agentRuns.first(where: { $0.id == runID }))
        XCTAssertEqual(run.phase, .completed)
        XCTAssertTrue(run.steps.contains(where: { $0.tool == "verifying" }))
        XCTAssertTrue(run.steps.contains(where: { $0.title.contains("第2轮") }))
    }
    @MainActor func testOpenUIResponderActionValidatesScopedFieldsAndDoesNotRunDuringRenderOrTwice() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
        let model = AppModel(root:root,notifications:ResponderTestNotifications()); model.settings.enabled = false
        var account = MailAccount(); account.id = "demo"; account.email = "you@example.com"; account.isDemo = true; model.accounts = [account]
        let source = "root = Form(\"responder\", [Button(\"保存并启用响应器\", @SaveResponder())])"
        let page = OpenUIInteraction(source:source); await model.saveOpenUIInteraction(page)
        _ = try OpenUILang.parse(source).root(); XCTAssertTrue(model.responders.isEmpty)
        var event = OpenUIActionEvent(type:"SaveResponder",formName:"responder",formState:["other":["sender":.init(value:.string("wrong@example.com"))],"responder":["title":.init(value:.string("项目回复")),"sender":.init(value:.string("team@example.com")),"subject":.init(value:.string("评审")),"response":.init(value:.string("收到，谢谢。")),"delivery":.init(value:.string("send"))]])
        event.formState?["responder"]?["accountID"] = .init(value: .string("demo"))
        event.formState?["responder"]?["authentication"] = .init(value: .string("address"))
        try await model.handleOpenUIAction(event,interactionID:page.id,buttonLabel:"保存并启用响应器")
        XCTAssertEqual(model.responders.count,1); XCTAssertEqual(model.responders.first?.sender,"team@example.com"); XCTAssertNotNil(model.openUIInteractions.first?.completedAt)
        do { try await model.handleOpenUIAction(event,interactionID:page.id,buttonLabel:"保存并启用响应器"); XCTFail("Repeated event must not create another rule") } catch {}
        XCTAssertEqual(model.responders.count,1)
    }
    @MainActor func testResponderSettingsPauseLinkedWorkAndBlockNewMailUntilResumed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = responderFixtureModel(root); model.isDemo = true
        var account = MailAccount(); account.id = "demo"; account.email = "you@example.com"; account.isDemo = true
        model.accounts = [account]
        try await model.store.save(account, kind: "account", id: account.id)
        var rule = MailResponder(); rule.title = "项目材料"; rule.sender = "team@example.com"; rule.subjectContains = "评审"; rule.response = "收到，谢谢。"; rule.delivery = "send"; rule.enabled = true
        rule.accountID = "demo"; rule.requireAuthentication = false; rule.useAI = false
        try await model.saveResponder(rule)
        var run = AgentRun(title: "接住项目材料", instruction: "收到材料后回复", phase: .monitoring, isDemo: true)
        run.responderID = rule.id; await model.saveRun(run)
        await model.setResponderEnabled(try XCTUnwrap(model.responders.first), false)
        XCTAssertEqual(model.agentRuns.first(where: { $0.id == run.id })?.phase, .paused)
        let storedPaused = try await model.store.object(AgentRun.self, kind: "agent-run", id: run.id)
        XCTAssertEqual(storedPaused?.phase, .paused)
        var incoming = MailMessage(accountID: "demo", from: .init(email: "team@example.com"), subject: "评审材料", text: "请核对")
        incoming.messageID = "<paused@example.com>"
        incoming.raw = responderSourceRaw(incoming)
        try await model.store.upsert(incoming); await model.reload(); await model.runResponders()
        XCTAssertTrue(model.responderReceipts.isEmpty)
        XCTAssertFalse(model.mails.contains(where: { $0.folder == "Sent" }))
        await model.setResponderEnabled(try XCTUnwrap(model.responders.first), true)
        XCTAssertEqual(model.agentRuns.first(where: { $0.id == run.id })?.phase, .monitoring)
        await model.runResponders()
        XCTAssertEqual(model.responderReceipts.count, 1)
        XCTAssertEqual(model.responderReceipts.first?.state, "simulated", model.responderReceipts.first?.detail ?? "")
        XCTAssertEqual(model.agentRuns.first(where: { $0.id == run.id })?.phase, .monitoring)
    }
    func testReplyToChangesNeverWidenAutomaticRecipientScope() {
        var rule = MailResponder(); rule.enabled = true; rule.delivery = "send"; rule.subjectContains = "评审"
        rule.accountID = "demo"; rule.sender = "team@example.com"; rule.requireAuthentication = false
        var mail = MailMessage(accountID:"demo",from:.init(email:"team@example.com"),subject:"评审",text:""); mail.messageID = "<source@example.com>"
        mail.uid = 1; mail.uidValidity = 7
        var draft = ComposeDraft(); draft.to = "other@example.com"; draft.accountID = "demo"; draft.inReplyTo = mail.messageID
        XCTAssertFalse(ResponderPolicy.canSend(draft,rule:rule,mail:mail)); draft.to = "team@example.com"; XCTAssertTrue(ResponderPolicy.canSend(draft,rule:rule,mail:mail))
    }
}
@MainActor private final class ResponderTestNotifications: MailNotificationManaging {
    func removePending(_ ids:[String]) {}
    func requestAuthorization() async throws -> Bool { false }
    func add(id:String,title:String,body:String,at date:Date?) async throws {}
}

@MainActor private func responderFixtureModel(_ root: URL) -> AppModel {
    let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [ResponderAgentFixtureProtocol.self]
    let model = AppModel(root: root, notifications: ResponderTestNotifications(), partner: PartnerEngine(ai: AIEngine(httpConfiguration: configuration)))
    model.settings.provider = "openai"; model.settings.openAIURL = "https://morrow-responder-fixture.invalid/v1"; model.settings.openAIModel = "fixture"
    return model
}
private final class ResponderAgentFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "morrow-responder-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var bytes = request.httpBody ?? Data()
        if bytes.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; bytes.append(contentsOf: buffer.prefix(n)) }
        }
        let payload = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
        let messages = payload?["messages"] as? [[String: Any]] ?? []
        let system = messages.first?["content"] as? String ?? ""; let prompt = messages.last?["content"] as? String ?? ""
        func field(_ start: String, until end: String = "\n") -> String {
            guard let a = prompt.range(of: start) else { return "" }; let tail = prompt[a.upperBound...]
            return String(tail.prefix { !end.contains($0) })
        }
        let content: String
        if system.contains("执行用户已设定的邮件响应器") {
            let id = field("绑定来源ID：")
            let body = field("固定正文（null表示AI起草）：")
            let op: [String: Any] = prompt.contains("触发邮件的附件（") ? ["type": "draft", "messageID": id, "text": body == "null" ? "收到，谢谢。" : body] : ["type": "attachments", "messageID": id]
            content = String(decoding: try! JSONSerialization.data(withJSONObject: ["answer": "已读取并核对来源。", "messageIDs": [id], "operations": [op]]), as: UTF8.self)
        } else if system.contains("核对待发回复") { content = #"{"approved":true,"issues":[]}"# }
        else { content = "已读取触发邮件。" }
        let result = try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: result); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private func responderSourceRaw(_ mail: MailMessage) -> Data { Data("From: \(mail.from.email)\r\nMessage-ID: \(mail.messageID)\r\nSubject: Fixture\r\n\r\nActual source".utf8) }

extension ResponderTests {
    @MainActor func testLiveResponderModelUsesSandboxAndRepliesOnlyInIsolatedDemo() async throws {
        guard let name = ProcessInfo.processInfo.environment["MORROW_LIVE_RESPONDER_MODEL"], !name.isEmpty else { throw XCTSkip("Live local responder model not requested") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(root: root, notifications: ResponderTestNotifications()); model.isDemo = true
        model.settings.provider = "ollama"; model.settings.model = name; model.settings.autoAnalyze = false
        var account = MailAccount(); account.id = "demo-live"; account.email = "owner@example.com"; account.isDemo = true; model.accounts = [account]; try await model.store.save(account, kind: "account", id: account.id)
        var rule = MailResponder(); rule.title = "Live sandbox responder"; rule.accountID = account.id; rule.sender = "team@example.com"; rule.requireAuthentication = false; rule.enabled = true; rule.useAI = true
        rule.response = "先使用 sandbox 工具运行 wc -w input/mail.txt，核对实际工具结果后，再用 draft 准备简短中文回复：确认收到，并请求对方补充明确截止时间。不要声称已完成项目或发送邮件。"
        try await model.saveResponder(rule)
        var mail = MailMessage(accountID: account.id, from: .init(email: "team@example.com"), subject: "Project review", text: "Please review the proposal. The exact deadline is not set yet."); mail.messageID = "<live-responder@example.com>"; mail.raw = responderSourceRaw(mail)
        try await model.store.upsert(mail); await model.reload(); await model.runResponders()
        let receipt = try XCTUnwrap(model.responderReceipts.first)
        XCTAssertEqual(receipt.state, "simulated", receipt.detail + "；步骤：" + model.agentRuns.flatMap(\.steps).map(\.title).joined(separator: " / "))
        let draft = try XCTUnwrap(model.drafts.first); XCTAssertEqual(draft.to, "team@example.com"); XCTAssertTrue(draft.cc.isEmpty && draft.bcc.isEmpty)
        let run = try XCTUnwrap(model.agentRuns.first(where: { $0.id == receipt.runID })); XCTAssertEqual(run.phase, .completed)
        XCTAssertTrue(run.steps.contains(where: { $0.tool == "tool" && $0.title == "sandbox" }))
        XCTAssertEqual(receipt.sandboxRuntime, "anthropic-srt/0.0.81"); XCTAssertTrue(receipt.agentVerified == true)
    }
    @MainActor func testRestartTurnsInterruptedPreparationIntoRetryableFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let model = responderFixtureModel(root)
        let mail = MailMessage(accountID: "demo", from: .init(email: "team@example.com"), subject: "Interrupted", text: "Source")
        var receipt = ResponderReceipt(responderID: "rule", mail: mail)
        var run = AgentRun(title: "Interrupted", instruction: "Read", phase: .working, steps: [.init(title: "Read", tool: "read", state: .active)], sourceMailIDs: [mail.id]); run.responderID = "rule"
        receipt.runID = run.id; model.responderReceipts = [receipt]; await model.saveRun(run)
        await model.recoverResponderExecutions()
        XCTAssertEqual(model.responderReceipts.first?.state, "failed"); XCTAssertEqual(model.agentRuns.first?.steps.first?.state, .failed)
        XCTAssertTrue(model.drafts.isEmpty)
    }
}
