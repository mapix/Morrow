import XCTest
import MorrowCore
@testable import MorrowApp

final class MailAnalysisRoutingTests: XCTestCase {
    func testLiveLocalMailAnalysisUsesSyntheticPrefixAndAttachmentName() async throws {
        guard ProcessInfo.processInfo.environment["MORROW_LIVE_MAIL_ANALYSIS"] == "1" else { throw XCTSkip("Opt-in local Ollama test; synthetic mail only") }
        let mail = MailMessage(accountID: "synthetic", from: .init(email: "peer@example.invalid"), subject: "Synthetic review request", text: "Please review the proposed schedule and reply with your comments. This is synthetic test data.")
        var settings = AgentSettings(); settings.model = "qwen3.8:27b-mlx"
        let result = try await PartnerEngine().analyze(MailEvidence.forAutomaticAnalysis(mail), settings: settings.mailAnalysisModelSettings)
        XCTAssertTrue(result.source.hasPrefix("Ollama / qwen3.8:27b-mlx")); XCTAssertFalse(result.summary.isEmpty)
        print("LOCAL_MAIL_ANALYSIS: source=\(result.source); summary_characters=\(result.summary.count)")
    }
    func testAutomaticInputContainsOnlyFirstThousandCharactersAndAttachmentNames() {
        let prefix = String(repeating: "正文", count: 500)
        var mail = MailMessage(accountID: "fixture", from: .init(email: "source@example.invalid"), subject: "Synthetic", text: prefix + "DO_NOT_INCLUDE_TAIL")
        mail.html = "DO_NOT_INCLUDE_HTML"; mail.raw = Data("DO_NOT_INCLUDE_RAW".utf8)
        var attachment = MailAttachment(name: "report.pdf", mimeType: "application/pdf", data: Data("DO_NOT_INCLUDE_ATTACHMENT".utf8)); attachment.storedPath = "/not-a-real-file"
        mail.attachments = [attachment]
        let input = MailEvidence.forAutomaticAnalysis(mail)
        XCTAssertTrue(input.text.hasPrefix(prefix)); XCTAssertTrue(input.text.contains("report.pdf"))
        XCTAssertFalse(input.text.contains("DO_NOT_INCLUDE_TAIL")); XCTAssertTrue(input.html.isEmpty); XCTAssertTrue(input.raw.isEmpty); XCTAssertTrue(input.attachments[0].data.isEmpty); XCTAssertNil(input.attachments[0].storedPath)
        XCTAssertFalse(mail.attachments[0].data.isEmpty)
    }
    @MainActor func testMailAnalysisSettingsPersistSeparatelyFromChatAndBudget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(root: root); model.settings.enabled = false
        model.settings.provider = "openai"; model.settings.openAIURL = "https://chat-fixture.invalid/v1"; model.settings.openAIModel = "chat-model"; model.settings.model = "local-model"
        try await model.saveMailAnalysisConfiguration(.init(model: "local-parser"))
        XCTAssertEqual(model.settings.provider, "openai"); XCTAssertEqual(model.settings.openAIModel, "chat-model")
        XCTAssertEqual(model.settings.mailAnalysisModelSettings.provider, "ollama"); XCTAssertEqual(model.settings.mailAnalysisModelSettings.model, "local-parser")
        let saved = try await model.store.object(AgentSettings.self, kind: "settings", id: "main")
        XCTAssertEqual(saved?.mailAnalysis?.model, "local-parser")
    }
    func testLocalAnalysisUsesOllamaWithoutGatewayFallback() async throws {
        MailAnalysisFixture.paths = []
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MailAnalysisFixture.self]
        let ai = AIEngine(httpConfiguration: config)
        var chat = AgentSettings(); chat.provider = "openai"; chat.openAIURL = "https://gateway-fixture.invalid/v1"; chat.openAIModel = "expensive"; chat.model = "local-parser"
        let result = try await ai.complete(system: "Synthetic analysis", prompt: "No real mail", settings: chat.mailAnalysisModelSettings, maxTokens: 32)
        XCTAssertEqual(result.text, "Local result"); XCTAssertEqual(MailAnalysisFixture.paths, ["http://127.0.0.1:11434/api/chat"])
    }
}

private final class MailAnalysisFixture: URLProtocol {
    static var paths: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.paths.append(request.url!.absoluteString)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let data = Data(#"{"message":{"content":"Local result"},"done":true}"#.utf8)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
