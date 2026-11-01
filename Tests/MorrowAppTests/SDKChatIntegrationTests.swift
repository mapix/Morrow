import XCTest
import MorrowCore
@testable import MorrowApp

final class SDKChatIntegrationTests: XCTestCase {
    @MainActor private func fixture(mode: String) async throws -> (AppModel, MailMessage, MailMessage) {
        let runtime = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Runtime/AgentRuntime")
        guard FileManager.default.fileExists(atPath: runtime.appendingPathComponent("node_modules/deepagents/package.json").path) else { throw XCTSkip("Install pinned SDK dependencies") }
        SDKChatHTTPFixture.reset(mode)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SDKChatHTTPFixture.self]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = AppModel(root: root, agentToolModel: AgentToolModel(configuration: config))
        model.workspacePreferences.memoryEnabled = false; model.settings.provider = "openai"; model.settings.openAIURL = "https://sdk-chat-fixture.invalid/v1"; model.settings.openAIModel = "fixture"
        var ranking = RetrievalDecisionSettings(); ranking.enabled = false; model.settings.retrievalDecision = ranking
        var a = MailAccount(); a.id = "a"; a.email = "a@example.invalid"; a.isDemo = true; var b = a; b.id = "b"; model.accounts = [a, b]
        await model.restoreChatSessions()
        var selected = MailMessage(accountID: "a", from: .init(email: "a@example.invalid"), subject: "Current unrelated message", text: "Selected hint"); selected.id = "selected"
        var target = MailMessage(accountID: "b", from: .init(email: "b@example.invalid"), subject: "game monetization SDK_TARGET_SOURCE", text: "game monetization SDK_TARGET_SOURCE"); target.id = "target"; target.folder = "Archive"
        try await model.store.upsert(selected); try await model.store.upsert(target); model.mails = [selected, target]
        model.workspacePage = .mail; model.selectedID = selected.id
        return (model, selected, target)
    }
    @MainActor func testRealSDKUsesSearchOutsideHintAndKeepsReadFlags() async throws {
        let (model, selected, target) = try await fixture(mode: "search"); defer { try? FileManager.default.removeItem(at: model.store.root) }
        await model.askPartner("查找所有游戏变现邮件，只查询，不修改邮件", uiContext: model.currentContext)
        let reply = try XCTUnwrap(model.visibleChat.last)
        XCTAssertEqual(reply.text, "SDK verified source result"); XCTAssertTrue(reply.messageIDs.contains(target.id))
        XCTAssertEqual(model.selectedID, selected.id); XCTAssertFalse(model.partnerBusy); XCTAssertNil(model.sidebarToolStatus)
        let stored = try await model.store.message(target.id); XCTAssertEqual(stored?.isRead, target.isRead)
        XCTAssertEqual(SDKChatHTTPFixture.count, 2)
    }
    @MainActor func testSDKCanContinueBeyondFourRoundsAndSaveVisibleReplyDraft() async throws {
        let (model, _, target) = try await fixture(mode: "long-draft"); defer { try? FileManager.default.removeItem(at: model.store.root) }
        model.selectedID = target.id
        await model.askPartner("读取这封邮件，写完整回复草稿", uiContext: model.currentContext)
        let reply = try XCTUnwrap(model.visibleChat.last), id = try XCTUnwrap(reply.draftIDs?.first)
        XCTAssertEqual(reply.text, "SDK draft saved")
        XCTAssertGreaterThan(SDKChatHTTPFixture.count, 4)
        let draft = try XCTUnwrap(model.drafts.first(where: { $0.id == id }))
        XCTAssertEqual(draft.to, "b@example.invalid"); XCTAssertEqual(draft.body, "Thank you.\n\nPlease share the schedule.")
        XCTAssertEqual(model.composer?.id, id); XCTAssertEqual(draft.state, "draft")
    }
    @MainActor func testSDKExplicitScopeStillRejectsOutsideMail() async throws {
        let (model, _, _) = try await fixture(mode: "restricted"); defer { try? FileManager.default.removeItem(at: model.store.root) }
        model.pinCurrentChatScope()
        await model.askPartner("只读分析当前明确限定的邮件", uiContext: model.resolvedChatContext)
        XCTAssertEqual(model.visibleChat.last?.text, "SDK outside source refused")
        XCTAssertFalse(model.sidebarEvidenceMailIDs.contains("target")); XCTAssertTrue(model.drafts.isEmpty)
    }
    @MainActor func testSDKFormPausesThenResumesSameCheckpointWithoutDuplicatingUI() async throws {
        let (model, _, _) = try await fixture(mode: "form"); defer { try? FileManager.default.removeItem(at: model.store.root) }
        await model.askPartner("请先让我选择范围再继续", uiContext: model.currentContext)
        let first = try XCTUnwrap(model.visibleChat.last), uiID = try XCTUnwrap(first.openUIID)
        XCTAssertTrue(first.text.contains("选择")); XCTAssertFalse(model.partnerBusy)
        await model.askPartner("选择 A，继续", uiContext: model.currentContext)
        XCTAssertEqual(model.visibleChat.last?.text, "SDK choice resumed")
        XCTAssertEqual(model.openUIInteractions.filter { $0.id == uiID }.count, 1)
        let pending = try await model.store.object(OpenUIJSON.self, kind: "agent-sdk-waiting", id: model.activeSessionID)
        XCTAssertNil(pending)
    }
    @MainActor func testSDKResponderSetupUsesExplicitSenderAndStaysDisabled() async throws {
        let (model, _, _) = try await fixture(mode: "responder"); defer { try? FileManager.default.removeItem(at: model.store.root) }
        await model.askPartner("为trusted@example.invalid创建响应器，先让我审阅策略", uiContext: model.currentContext)
        XCTAssertEqual(model.visibleChat.last?.text, "SDK responder prepared")
        XCTAssertEqual(model.responderEditor?.senderAllowlist, ["trusted@example.invalid"])
        XCTAssertEqual(model.responderEditor?.enabled, false)
        XCTAssertEqual(model.workspacePage, .responders)
    }
    @MainActor func testSDKSmallRequestedPageDoesNotCauseTinyRepeatedReads() async throws {
        let (model, selected, original) = try await fixture(mode: "page-size"); defer { try? FileManager.default.removeItem(at: model.store.root) }
        var target = original; target.text = String(repeating: "Synthetic paragraph. ", count: 1000)
        try await model.store.upsert(target); model.mails = [selected, target]
        await model.askPartner("只读这封邮件的相关事实，不需要通读全文", uiContext: model.currentContext)
        let last = try XCTUnwrap(SDKChatHTTPFixture.lastBody)
        let messages = try XCTUnwrap(last["messages"] as? [[String: Any]])
        let output = try XCTUnwrap(messages.last(where: { $0["role"] as? String == "tool" })?["content"] as? String)
        let page = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        XCTAssertEqual((page["text"] as? String)?.count, 4000)
        XCTAssertEqual(page["nextOffset"] as? Int, 4000)
        XCTAssertEqual(SDKChatHTTPFixture.count, 2)
    }
}

private final class SDKChatHTTPFixture: URLProtocol {
    private static let lock = NSLock()
    private static var calls = 0
    private static var mode = "search"
    private static var body: [String: Any]?
    static var count: Int { lock.withLock { calls } }
    static var lastBody: [String: Any]? { lock.withLock { body } }
    static func reset(_ value: String) { lock.withLock { calls = 0; mode = value; body = nil } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "sdk-chat-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var bytes = request.httpBody ?? Data()
        if bytes.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var block = [UInt8](repeating: 0, count: 4096)
            while true { let n = stream.read(&block, maxLength: block.count); if n <= 0 { break }; bytes.append(contentsOf: block.prefix(n)) }
        }
        if let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] { Self.lock.withLock { Self.body = value } }
        let (call, mode) = Self.lock.withLock { Self.calls += 1; return (Self.calls, Self.mode) }
        let operation: (String, [String: Any])?
        let answer: String
        if mode == "page-size" {
            operation = call == 1 ? ("read_mail", ["messageID": "target", "limit": 256]) : nil
            answer = "SDK efficient page"
        } else if mode == "responder" {
            operation = call == 1 ? ("setup_responder", ["instruction": "只响应trusted@example.invalid", "title": "Synthetic rule", "accountID": "a", "senderAllowlist": ["trusted@example.invalid"]]) : nil
            answer = "SDK responder prepared"
        } else if mode == "form" {
            operation = call == 1 ? ("render_ui", ["source": "root = Form(\"choice\", [TextArea(\"response\", \"你的选择\", \"\"), Button(\"继续\", @ToAssistant(\"选择 A\"))])"]) : nil
            answer = "SDK choice resumed"
        } else if mode == "long-draft" {
            operation = call <= 5 ? ("read_mail", ["messageID": "target"]) : call == 6 ? ("prepare_draft", ["messageID": "target", "text": "Thank you.\n\nPlease share the schedule."]) : nil
            answer = "SDK draft saved"
        } else if mode == "restricted" { operation = call == 1 ? ("read_mail", ["messageID": "target"]) : nil; answer = "SDK outside source refused" }
        else { operation = call == 1 ? ("search_mail", ["query": "game monetization"]) : nil; answer = "SDK verified source result" }
        var delta: [String: Any] = ["content": operation == nil ? answer : ""]
        if let operation {
            let arguments = String(decoding: try! JSONSerialization.data(withJSONObject: operation.1), as: UTF8.self)
            delta["tool_calls"] = [["index": 0, "id": "fixture-call-\(call)", "type": "function", "function": ["name": operation.0, "arguments": arguments]]]
        }
        let record = try! JSONSerialization.data(withJSONObject: ["choices": [["delta": delta, "finish_reason": operation == nil ? "stop" : "tool_calls"]]])
        let data = Data(("data: " + String(decoding: record, as: UTF8.self) + "\n\ndata: [DONE]\n\n").utf8)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
