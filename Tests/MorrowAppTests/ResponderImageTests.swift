import XCTest
import MorrowCore
@testable import MorrowApp

@MainActor final class ResponderImageTests: XCTestCase {
    private func fixture() async throws -> AppModel {
        ImageResponderHTTP.reset()
        let network = URLSessionConfiguration.ephemeral; network.protocolClasses = [ImageResponderHTTP.self]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = AppModel(root: root, notifications: ImageResponderNotifications(), partner: PartnerEngine(ai: AIEngine(httpConfiguration: network)))
        app.settings.provider = "openai"; app.settings.openAIURL = "https://responder-image-tests.invalid/v1"; app.settings.openAIModel = "fixture"
        app.settings.autoAnalyze = false; app.workspacePreferences.memoryEnabled = false; app.isDemo = true
        app.gatewayMediaClientOverride = GatewayMediaClient(configuration: try GatewayMediaConfiguration.load(), apiKey: "fixture", network: network)
        var account = MailAccount(); account.id = "demo-image"; account.email = "owner@example.com"; account.isDemo = true
        app.accounts = [account]; try await app.store.save(account, kind: "account", id: account.id)
        await app.restoreChatSessions()
        return app
    }
    private func rule(_ app: AppModel, dailyLimit: Int = 20) async throws -> MailResponder {
        var rule = MailResponder(); rule.title = "Image reply"; rule.accountID = "demo-image"; rule.sender = "source@example.com"
        rule.bodyContains = "生成图片"; rule.response = "根据来信描述生成一张图片并附到回复。"; rule.requireAuthentication = false; rule.enabled = true
        rule.imageReply = .init(); var policy = rule.policy; policy.allowedTools.append("generateImage"); policy.maximumSeconds = 360; rule.executionPolicy = policy
        rule.dailyLimit = dailyLimit
        try await app.saveResponder(rule)
        return try XCTUnwrap(app.responders.first)
    }
    private func incoming(_ app: AppModel, body: String = "生成图片：白底蓝色圆形") async throws -> MailMessage {
        var mail = MailMessage(accountID: "demo-image", from: .init(email: "source@example.com"), subject: "Image request", text: body)
        mail.id = "image-source"; mail.messageID = "<image-request@example.com>"
        mail.raw = Data("From: source@example.com\r\nMessage-ID: <image-request@example.com>\r\nSubject: Image request\r\n\r\n\(body)".utf8)
        try await app.store.upsert(mail); await app.reload()
        return mail
    }
    func testNewMatchingMailProducesOneRealImageAttachmentAndOnlyOneReply() async throws {
        let app = try await fixture(); defer { try? FileManager.default.removeItem(at: app.store.root) }
        _ = try await rule(app); _ = try await incoming(app)
        await app.runResponders(); await app.runResponders()
        let receipt = try XCTUnwrap(app.responderReceipts.first)
        XCTAssertEqual(receipt.state, "simulated", receipt.detail)
        XCTAssertEqual(app.responderReceipts.count, 1); XCTAssertEqual(ImageResponderHTTP.imageCalls, 1)
        let draft = try XCTUnwrap(app.drafts.first)
        XCTAssertEqual(draft.to, "source@example.com"); XCTAssertTrue(draft.cc.isEmpty && draft.bcc.isEmpty)
        XCTAssertEqual(draft.attachments.count, 1); XCTAssertEqual(draft.attachments.first?.data, ImageResponderHTTP.png)
        let sent = try XCTUnwrap(app.mails.first { $0.folder == "Sent" })
        let parsed = MIMEParser.parse(try await app.store.rawData(sent), accountID: "demo-image", folder: "Sent")
        XCTAssertEqual(parsed.attachments.first?.data, ImageResponderHTTP.png)
        let images = try await app.store.load(ResponderImageReceipt.self, kind: "responder-image")
        XCTAssertEqual(images.first?.state, "complete"); XCTAssertEqual(images.first?.id, ImageResponderHTTP.idempotencyKey)
    }
    func testRetryAfterFailedVerificationReusesGeneratedImage() async throws {
        let app = try await fixture(); defer { try? FileManager.default.removeItem(at: app.store.root) }
        _ = try await rule(app); _ = try await incoming(app)
        ImageResponderHTTP.approve = false
        await app.runResponders()
        let first = try XCTUnwrap(app.responderReceipts.first)
        XCTAssertEqual(first.state, "failed"); XCTAssertTrue(app.drafts.isEmpty)
        XCTAssertEqual(ImageResponderHTTP.imageCalls, 1)
        ImageResponderHTTP.approve = true
        await app.runResponders(retryReceiptID: first.id)
        XCTAssertEqual(app.responderReceipts.first?.state, "simulated", app.responderReceipts.first?.detail ?? "")
        XCTAssertEqual(ImageResponderHTTP.imageCalls, 1)
        XCTAssertEqual(app.drafts.first?.attachments.count, 1)
    }
    func testUncertainGenerationCannotChargeAgainOrSendOnRetry() async throws {
        let app = try await fixture(); defer { try? FileManager.default.removeItem(at: app.store.root) }
        _ = try await rule(app); _ = try await incoming(app)
        ImageResponderHTTP.failImage = true
        await app.runResponders()
        let first = try XCTUnwrap(app.responderReceipts.first)
        ImageResponderHTTP.failImage = false
        await app.runResponders(retryReceiptID: first.id)
        XCTAssertEqual(ImageResponderHTTP.imageCalls, 1); XCTAssertTrue(app.drafts.isEmpty)
        XCTAssertEqual(app.responderReceipts.first?.state, "failed")
        XCTAssertTrue(app.responderReceipts.first?.detail.contains("结果待确认") == true)
    }
    func testBodyConditionBlocksGenerationAndMissingImageBlocksDelivery() async throws {
        let app = try await fixture(); defer { try? FileManager.default.removeItem(at: app.store.root) }
        _ = try await rule(app); _ = try await incoming(app, body: "普通文字邮件，没有触发词")
        await app.runResponders(); XCTAssertEqual(ImageResponderHTTP.imageCalls, 0); XCTAssertTrue(app.responderReceipts.isEmpty)
        _ = try await incoming(app)
        ImageResponderHTTP.skipImage = true
        await app.runResponders()
        XCTAssertEqual(ImageResponderHTTP.imageCalls, 0); XCTAssertTrue(app.drafts.isEmpty)
        XCTAssertEqual(app.responderReceipts.first?.state, "failed")
    }
    func testChatReviewSavesExactConditionsAndPreventsDuplicateSave() async throws {
        let app = try await fixture(); defer { try? FileManager.default.removeItem(at: app.store.root) }
        let context = SDKChatContext(sessionID: app.activeSessionID, instruction: "来源 source@example.com，生成图片后回复", ui: nil, runID: nil, allowedIDs: nil, agreement: nil)
        let output = try await app.performSDKTool(.object(["name": .string("setup_responder"), "callId": .string("prepare"), "args": .object([
            "instruction": .string("生成图片并回复"), "title": .string("Image reply"), "accountID": .string("demo-image"), "bodyContains": .string("生成图片"),
            "senderAllowlist": .array([.string("source@example.com")]), "imageReply": .bool(true), "dailyLimit": .number(2)])]), context: context)
        XCTAssertEqual(output.object["saved"], .bool(false)); XCTAssertTrue(app.responders.isEmpty)
        var page = try XCTUnwrap(context.presentation); _ = try OpenUILang.parse(page.source).root()
        XCTAssertEqual(page.responderDraft?.bodyContains, "生成图片"); XCTAssertNotNil(page.responderDraft?.imageReply)
        var message = PartnerChat(role: "partner", text: "Review"); message.sessionID = app.activeSessionID; message.openUIID = page.id; page.chatID = message.id
        try await app.recordChat(message, presentation: page)
        let values: [String: String] = ["title": "Image reply", "accountID": "demo-image", "sender": "source@example.com", "body": "生成图片", "response": "根据来信生成图片并回复", "delivery": "send", "contentMode": "ai", "authentication": "address", "imageReply": "image", "imageSize": "1024x1024", "imageQuality": "auto", "dailyLimit": "2"]
        let event = OpenUIActionEvent(type: "SaveResponder", formName: "responder", formState: ["responder": values.mapValues { .init(value: .string($0)) }])
        try await app.handleOpenUIAction(event, interactionID: page.id, buttonLabel: "保存并启用响应器")
        XCTAssertEqual(app.responders.count, 1); XCTAssertEqual(app.responders.first?.id, output.object["responderID"]?.text)
        XCTAssertEqual(app.responders.first?.bodyContains, "生成图片"); XCTAssertEqual(app.responders.first?.dailyLimit, 2)
        XCTAssertEqual(app.responders.first?.imageReply?.model, app.gatewayMediaClientOverride?.configuration.defaultImageModel)
        do { try await app.handleOpenUIAction(event, interactionID: page.id, buttonLabel: "保存并启用响应器"); XCTFail("Duplicate save accepted") } catch {}
        XCTAssertEqual(app.responders.count, 1)
    }
    func testReadStatusAndTrialReportActualEvidenceWithoutSending() async throws {
        let app = try await fixture(); defer { try? FileManager.default.removeItem(at: app.store.root) }
        let saved = try await rule(app); let mail = try await incoming(app)
        let context = SDKChatContext(sessionID: app.activeSessionID, instruction: "测试这个响应器", ui: nil, runID: nil, allowedIDs: nil, agreement: nil)
        context.workspaceLease = try await app.sessionWorkspaces.open(app.activeSessionID)
        func call(_ name: String) async throws -> OpenUIJSON {
            try await app.performSDKTool(.object(["name": .string(name), "callId": .string(name), "args": .object(["responderID": .string(saved.id), "messageID": .string(mail.id)])]), context: context)
        }
        let read = try await call("read_responder"); XCTAssertEqual(read.object["bodyContains"], .string("生成图片"))
        let trial = try await call("test_responder"); XCTAssertEqual(trial.object["sent"], .bool(false)); XCTAssertEqual(trial.object["attachmentCount"], .number(1))
        XCTAssertTrue(app.drafts.isEmpty); XCTAssertFalse(app.mails.contains { $0.folder == "Sent" }); XCTAssertEqual(context.generatedMedia.count, 1)
        let status = try await call("responder_status"); XCTAssertEqual(status.object["receipts"], .array([]))
    }
    func testAttachmentVerificationIncludesItsActualBytes() {
        var draft = ComposeDraft(); var image = MailAttachment(name: "image.png", mimeType: "image/png", data: ImageResponderHTTP.png); image.id = "same-id"; draft.attachments = [image]
        let before = ResponderPolicy.draftFingerprint(draft); draft.attachments[0].data = Data("changed".utf8)
        XCTAssertNotEqual(before, ResponderPolicy.draftFingerprint(draft))
        XCTAssertFalse(ReplySuggestionPolicy.containsUnverifiedConfirmation("图片已附上。", hasVerifiedAttachments: true))
        XCTAssertTrue(ReplySuggestionPolicy.containsUnverifiedConfirmation("已付款，图片已附上。", hasVerifiedAttachments: true))
    }
    func testFailedVerificationStillConsumesDailyImageAllowance() async throws {
        let app = try await fixture(); defer { try? FileManager.default.removeItem(at: app.store.root) }
        let saved = try await rule(app, dailyLimit: 1); var mail = try await incoming(app)
        ImageResponderHTTP.approve = false
        await app.runResponders(); XCTAssertEqual(app.responderReceipts.first?.state, "failed")
        mail.messageID = "<second-image@example.com>"; mail.id = "second-image"
        do { _ = try await app.responderImage(saved, mail: mail, prompt: "Another blue circle"); XCTFail("Daily media budget bypassed after failed verification") }
        catch { XCTAssertTrue(error.localizedDescription.contains("当天的图片生成次数上限"), error.localizedDescription) }
        XCTAssertEqual(ImageResponderHTTP.imageCalls, 1)
    }
}

@MainActor private final class ImageResponderNotifications: MailNotificationManaging {
    func removePending(_ ids: [String]) {}
    func requestAuthorization() async throws -> Bool { false }
    func add(id: String, title: String, body: String, at date: Date?) async throws {}
}
private final class ImageResponderHTTP: URLProtocol, @unchecked Sendable {
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aXioAAAAASUVORK5CYII=")!
    static var imageCalls = 0, approve = true, failImage = false, skipImage = false
    static var idempotencyKey: String?
    static func reset() { imageCalls = 0; approve = true; failImage = false; skipImage = false; idempotencyKey = nil }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var bytes = request.httpBody ?? Data()
        if bytes.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096)
            while true { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; bytes.append(contentsOf: buffer.prefix(n)) }
        }
        let body: Data; var status = 200
        if request.url?.path.hasSuffix("images/generations") == true {
            Self.imageCalls += 1; Self.idempotencyKey = request.value(forHTTPHeaderField: "Idempotency-Key")
            if Self.failImage { status = 503; body = Data(#"{"error":{"message":"simulated lost result"}}"#.utf8) }
            else { body = try! JSONSerialization.data(withJSONObject: ["data": [["b64_json": Self.png.base64EncodedString()]]]) }
        } else {
            let payload = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
            let messages = payload?["messages"] as? [[String: Any]] ?? []
            let system = messages.first?["content"] as? String ?? "", prompt = messages.last?["content"] as? String ?? ""
            let content: String
            if system.contains("执行用户已设定的邮件响应器") {
                let op: [String: Any] = !Self.skipImage && !prompt.contains("图片已生成，应用") ? ["type": "generateImage", "text": "A blue circle on a white background"] : ["type": "draft", "text": "图片已附上，请查看附件。"]
                content = String(decoding: try! JSONSerialization.data(withJSONObject: ["answer": "Actual image reply", "operations": [op]]), as: UTF8.self)
            } else if system.contains("核对待发回复") { content = Self.approve ? #"{"approved":true,"issues":[]}"# : #"{"approved":false,"issues":["fixture verification rejected"]}"# }
            else { content = "生成图片：白底蓝色圆形。" }
            body = try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
