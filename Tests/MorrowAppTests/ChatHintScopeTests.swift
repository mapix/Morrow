import XCTest
import MorrowCore
@testable import MorrowApp

final class ChatHintScopeTests: XCTestCase {
    @MainActor func testBrowsingIsHintAndIntentionalPinRemainsAConstraint() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(root: root); model.settings.enabled = false
        var a = MailAccount(); a.id = "a"; a.email = "owner@example.invalid"; var b = a; b.id = "b"
        model.accounts = [a,b]
        let selected = MailMessage(accountID: "a", from: .init(email: "a@example.invalid"), subject: "Selected", text: "Selected")
        let elsewhere = MailMessage(accountID: "b", from: .init(email: "b@example.invalid"), subject: "Elsewhere", text: "Elsewhere")
        model.mails = [selected, elsewhere]; model.workspacePage = .mail; model.selectedID = selected.id
        let hint = model.currentContext
        XCTAssertEqual(hint.scopeMode, "hint"); XCTAssertFalse(hint.enforcesMailScope)
        XCTAssertNoThrow(try model.validateChatOperation(.init(type: "read", messageID: elsewhere.id), context: hint))
        XCTAssertNil(try model.workContextLimit(hint, instruction: "整理所有邮件"))
        model.pinCurrentChatScope(); let scope = model.resolvedChatContext
        XCTAssertEqual(scope.scopeMode, "scope"); XCTAssertTrue(scope.enforcesMailScope)
        XCTAssertThrowsError(try model.validateChatOperation(.init(type: "read", messageID: elsewhere.id), context: scope))
    }
    @MainActor func testGlobalSearchFindsAnotherAccountWhileLeftIsOnOneMessage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [HintSearchFixture.self]
        let model = AppModel(root: root, partner: PartnerEngine(ai: AIEngine(httpConfiguration: config)))
        model.settings.provider = "openai"; model.settings.openAIURL = "https://hint-fixture.invalid/v1"; model.settings.openAIModel = "fixture"; model.workspacePreferences.memoryEnabled = false
        var decision = RetrievalDecisionSettings(); decision.enabled = false; model.settings.retrievalDecision = decision
        var a = MailAccount(); a.id = "a"; a.email = "a@example.invalid"; a.isDemo = true; var b = a; b.id = "b"; model.accounts = [a,b]
        await model.restoreChatSessions()
        var selected = MailMessage(accountID: "a", from: .init(email: "a@example.invalid"), subject: "Current unrelated email", text: "LEFT_HINT_ONLY"); selected.id = "selected"
        var target = MailMessage(accountID: "b", from: .init(email: "b@example.invalid"), subject: "budget opportunity", text: "budget opportunity GLOBAL_TARGET_BODY"); target.id = "global-target"; target.folder = "Archive"
        try await model.store.upsert(selected); try await model.store.upsert(target); model.mails = [selected,target]
        model.workspacePage = .mail; model.selectedID = selected.id
        await model.askPartner("查找所有邮件中的 budget opportunity", uiContext: model.currentContext)
        XCTAssertEqual(model.visibleChat.last?.text, "Found outside the current UI")
        XCTAssertEqual(model.visibleChat.last?.messageIDs, [target.id])
        XCTAssertTrue(model.sidebarEvidenceMailIDs.contains(target.id)); XCTAssertEqual(model.selectedID, selected.id)
    }
}
private final class HintSearchFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "hint-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var bytes = request.httpBody ?? Data()
        if bytes.isEmpty, let stream = request.httpBodyStream { stream.open(); defer { stream.close() }; var buffer=[UInt8](repeating:0,count:4096); while stream.hasBytesAvailable { let n=stream.read(&buffer,maxLength:buffer.count); if n<=0 {break}; bytes.append(contentsOf:buffer.prefix(n)) } }
        let object = (try? JSONSerialization.jsonObject(with: bytes)) as? [String:Any]
        let prompt = (object?["messages"] as? [[String:Any]])?.compactMap { $0["content"] as? String }.joined(separator:"\n") ?? ""
        let found = prompt.contains("GLOBAL_TARGET_BODY")
        let plan: [String:Any] = found ? ["answer":"Found outside the current UI","messageIDs":["global-target"],"operations":[]] : ["answer":"Searching all mail","messageIDs":[],"operations":[["type":"search","text":"budget opportunity"]]]
        let content = String(decoding:try! JSONSerialization.data(withJSONObject:plan),as:UTF8.self)
        let data = try! JSONSerialization.data(withJSONObject:["choices":[["message":["content":content]]]])
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:"HTTP/1.1",headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
