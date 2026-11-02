import XCTest
import AppKit
import MorrowCore
@testable import MorrowApp

final class ChatPresentationTests: XCTestCase {
    func testLongMarkdownPreviewIsExplicitAndCopyRetainsTheTail() {
        let text = String(repeating: "Long evidence paragraph.\n\n", count: 6000) + "FINAL_EVIDENCE_MARKER"
        let document = WorkMarkdownDocument(text)
        XCTAssertTrue(document.isTruncated)
        XCTAssertTrue(document.fullSource.hasSuffix("FINAL_EVIDENCE_MARKER"))
        XCTAssertTrue(document.plainText.hasSuffix("FINAL_EVIDENCE_MARKER"))
    }
    func testMarkdownParsesSeparateBlocksNestedListsCodeAndTables() {
        let source = "## 结论\n第一行\n第二行\n\n- 一项\n  - 子项\n\n```swift\nlet value = \"\\n\"\n```\n\n| 来源 | 数量 |\n| --- | ---: |\n| 邮件 | 12 |"
        let blocks = WorkMarkdownDocument(source).blocks
        XCTAssertTrue(blocks.contains { if case .heading = $0 { return true }; return false })
        XCTAssertTrue(blocks.contains { if case .paragraph(let t) = $0 { return String(t.characters).contains("第一行\n第二行") }; return false })
        XCTAssertTrue(blocks.contains { if case .listItem(_, _, let children) = $0 { return children.contains { if case .listItem = $0 { return true }; return false } }; return false })
        XCTAssertTrue(blocks.contains { if case .code(let language, let code) = $0 { return language == "swift" && code.contains("\\n") }; return false })
        XCTAssertTrue(blocks.contains { if case .table(let rows) = $0 { return rows.count == 2 && rows[0].count == 2 }; return false })
        XCTAssertTrue(WorkMarkdownDocument("```markdown\n# 标题\n\n正文\n```").blocks.contains { if case .heading = $0 { return true }; return false })
    }
    @MainActor func testNativeChatSendChordsDoNotSubmitCompositionOrRepeat() {
        let text = MediaTextView(frame: .zero); text.isEditable = true; text.string = "你好"
        var sent = 0; var committed = ""; text.submitChat = { sent += 1 }; text.committedEdit = { committed = $0.string }
        func event(_ flags: NSEvent.ModifierFlags, code: UInt16 = 36, repeated: Bool = false) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: repeated, keyCode: code)!
        }
        XCTAssertTrue(text.performKeyEquivalent(with: event(.command))); XCTAssertEqual(sent, 1); XCTAssertEqual(committed, "你好")
        XCTAssertTrue(text.performKeyEquivalent(with: event(.control, code: 76))); XCTAssertEqual(sent, 2)
        XCTAssertTrue(text.performKeyEquivalent(with: event(.command, repeated: true))); XCTAssertEqual(sent, 2)
        text.setMarkedText("zhongwen", selectedRange: .init(location: 8, length: 0), replacementRange: .init(location: NSNotFound, length: 0))
        let composing = text.string
        XCTAssertTrue(text.performKeyEquivalent(with: event(.command))); XCTAssertEqual(sent, 2); XCTAssertEqual(text.string, composing); XCTAssertTrue(text.hasMarkedText())
    }
    @MainActor func testCreatedDraftIsPersistedAndOnlyFollowsUnchangedUserContext() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(root: root); model.settings.enabled = false; await model.restoreChatSessions()
        var account = MailAccount(); account.id = "demo"; account.isDemo = true; account.email = "owner@example.com"; model.accounts = [account]
        let context = model.currentContext, owner = model.activeSessionID
        let draft = try await model.createAgentDraft(.init(type: "draft", text: "第一段\n\n第二段", recipient: "peer@example.com", subject: "Reply"))
        let stored = try await model.store.object(ComposeDraft.self, kind: "draft", id: draft.id)
        XCTAssertEqual(stored?.body, draft.body); XCTAssertEqual(model.drafts.count, 1)
        model.followPreparedDraft(draft, submittedContext: context, sessionID: owner)
        XCTAssertEqual(model.composer?.id, draft.id); XCTAssertEqual(model.destination, .drafts)
        model.composer = nil; model.workspacePage = .people
        model.followPreparedDraft(draft, submittedContext: context, sessionID: owner)
        XCTAssertNil(model.composer); XCTAssertEqual(model.workspacePage, .people)
    }
    func testChartsUseActualAggregatesAndRejectInvalidSeries() throws {
        var first = MailMessage(accountID: "demo", from: .init(email: "peer@example.com"), subject: "One", text: ""); first.analysis = .init(summary: "", category: .work)
        let second = MailMessage(accountID: "demo", from: .init(email: "peer@example.com"), subject: "Two", text: "")
        let result = ChatStatisticsPresentation.make(mails: [first, second], mode: "categories", scope: "Synthetic")
        let root = try OpenUILang.parse(result.chartSource).root(); try root.validatePresentation()
        guard case .node(let node) = root else { return XCTFail("Chart missing") }
        XCTAssertEqual(try OpenUIChartData(node: node).points.reduce(0) { $0 + $1.value }, 2)
        XCTAssertFalse(root.needsUserInput)
        XCTAssertThrowsError(try OpenUILang.parse("root = PieChart(\"Invalid\", [{label: \"x\", value: -1}])").root().validatePresentation())
        XCTAssertTrue(try OpenUILang.parse("root = Form(\"x\", [Input(\"name\", \"\", \"\")])").root().needsUserInput)
    }
    @MainActor func testChartAndReplyPersistAtomicallyWithTheirConversation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(root: root); model.settings.enabled = false; await model.restoreChatSessions()
        var reply = PartnerChat(role: "partner", text: "Summary"); reply.sessionID = model.activeSessionID
        var page = OpenUIInteraction(source: "root = BarChart(\"Counts\", [{label:\"a\",value:2}])"); page.chatID = reply.id; page.sessionID = reply.sessionID; reply.openUIID = page.id
        try await model.recordChat(reply, presentation: page)
        let storedReply = try await model.store.object(PartnerChat.self, kind: "chat", id: reply.id)
        let storedPage = try await model.store.object(OpenUIInteraction.self, kind: "openui-interaction", id: page.id)
        XCTAssertEqual(storedReply?.openUIID, page.id); XCTAssertEqual(storedPage?.chatID, reply.id)
        XCTAssertEqual(storedPage?.sessionID, reply.sessionID)
    }
}

extension ChatPresentationTests {
    @MainActor func testChartDoesNotBlockDraftAndResponseLinksVisibleSavedDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [PresentationPlanFixture.self]
        let model = AppModel(root: root, partner: PartnerEngine(ai: AIEngine(httpConfiguration: config)))
        model.workspacePreferences.memoryEnabled = false; model.settings.provider = "openai"; model.settings.openAIURL = "https://presentation-fixture.invalid/v1"; model.settings.openAIModel = "fixture"
        await model.restoreChatSessions()
        var account = MailAccount(); account.id = "demo"; account.email = "owner@example.com"; account.isDemo = true; model.accounts = [account]
        var mail = MailMessage(accountID: "demo", from: .init(email: "peer@example.com"), subject: "Synthetic reply", text: "Please reply."); mail.id = "synthetic-message"; model.mails = [mail]; try await model.store.upsert(mail)
        model.workspacePage = .mail; model.selectedID = mail.id
        let context = model.currentContext
        await model.askPartner("Display the chart and prepare a reply", uiContext: context)
        let reply = try XCTUnwrap(model.visibleChat.last)
        let id = try XCTUnwrap(reply.draftIDs?.first)
        XCTAssertEqual(model.composer?.id, id)
        XCTAssertEqual(model.drafts.first(where: { $0.id == id })?.to, "peer@example.com")
        let page = try XCTUnwrap(model.openUIInteractions.first(where: { $0.id == reply.openUIID }))
        XCTAssertEqual(page.chatID, reply.id); XCTAssertEqual(page.sessionID, model.activeSessionID)
        XCTAssertEqual(model.drafts.count, 1); XCTAssertEqual(model.drafts.first?.state, "draft")
    }
}
private final class PresentationPlanFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "presentation-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let plan: [String: Any] = ["answer": "## 已准备\n\n草稿已经保存，尚未发送。", "messageIDs": ["synthetic-message"], "operations": [["type": "draft", "messageID": "synthetic-message", "text": "Thank you.\n\nPlease send the schedule."]], "openUI": "root = BarChart(\"Synthetic chart\", [{label:\"a\",value:2}])"]
        let content = String(decoding: try! JSONSerialization.data(withJSONObject: plan), as: UTF8.self)
        let body = try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
