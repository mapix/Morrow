import XCTest
import MorrowCore
@testable import MorrowApp

final class ChatPlanRecoveryTests: XCTestCase {
    @MainActor func testMalformedPlanRepairsThenSearchesOutsideUIAndReturnsActualEvidence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        RecoveryPlanFixture.reset()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RecoveryPlanFixture.self]
        let model = AppModel(root: root, partner: PartnerEngine(ai: AIEngine(httpConfiguration: config)))
        model.settings.provider = "openai"; model.settings.openAIURL = "https://recovery-fixture.invalid/v1"; model.settings.openAIModel = "fixture"
        model.workspacePreferences.memoryEnabled = false
        var decision = RetrievalDecisionSettings(); decision.enabled = false; model.settings.retrievalDecision = decision
        var a = MailAccount(); a.id = "a"; a.email = "a@example.invalid"; a.isDemo = true; var b = a; b.id = "b"; model.accounts = [a, b]
        await model.restoreChatSessions()
        var selected = MailMessage(accountID: "a", from: .init(email: "peer@example.invalid"), subject: "Unrelated mail", text: "Current selected mail"); selected.id = "selected"
        var target = MailMessage(accountID: "b", from: .init(email: "peer@example.invalid"), subject: "Game monetization", text: "Game monetization RECOVERED_TARGET_BODY"); target.id = "target"; target.folder = "Archive"
        try await model.store.upsert(selected); try await model.store.upsert(target); model.mails = [selected, target]
        model.workspacePage = .mail; model.selectedID = selected.id
        await model.askPartner("找出今年所有游戏变现邮件并整理，保留未读状态", uiContext: model.currentContext)
        let reply = try XCTUnwrap(model.visibleChat.last)
        XCTAssertEqual(reply.text, "Recovered evidence-based result"); XCTAssertEqual(reply.messageIDs, ["target"])
        XCTAssertTrue(model.sidebarEvidenceMailIDs.contains("target")); XCTAssertEqual(model.selectedID, selected.id)
        XCTAssertEqual(RecoveryPlanFixture.count, 3)
        let unchanged = try await model.store.message(target.id); XCTAssertEqual(unchanged?.isRead, target.isRead)
        XCTAssertFalse(model.partnerBusy)
        XCTAssertNil(model.sidebarToolStatus)
    }
}

private final class RecoveryPlanFixture: URLProtocol {
    private static let lock = NSLock()
    private static var calls = 0
    static var count: Int { lock.withLock { calls } }
    static func reset() { lock.withLock { calls = 0 } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "recovery-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var bytes = request.httpBody ?? Data()
        if bytes.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096)
            while true { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; bytes.append(contentsOf: buffer.prefix(n)) }
        }
        let call = Self.lock.withLock { Self.calls += 1; return Self.calls }
        let object = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
        let prompt = (object?["messages"] as? [[String: Any]])?.compactMap { $0["content"] as? String }.joined(separator: "\n") ?? ""
        let content: String
        if call == 1 { content = "root = Steps(\"计划\", [\"搜索邮件\"])" }
        else {
            let plan: [String: Any] = prompt.contains("RECOVERED_TARGET_BODY")
                ? ["answer": "Recovered evidence-based result", "messageIDs": ["target"], "operations": []]
                : ["answer": "Searching", "messageIDs": [], "operations": [["type": "search", "text": "game monetization"]]]
            content = String(decoding: try! JSONSerialization.data(withJSONObject: plan), as: UTF8.self)
        }
        let data = try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content], "finish_reason": "stop"]]])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
