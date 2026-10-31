import XCTest
import Foundation
import MorrowCore
@testable import MorrowApp

final class ChatEvidenceTests: XCTestCase {
    @MainActor func testBrowsingInboxSendsNoMailBodiesToModel() async throws {
        let model = makeModel()
        defer { ContextFixtureProtocol.reset(); try? FileManager.default.removeItem(at: model.store.root) }
        await model.restoreChatSessions()
        let mail = MailMessage(accountID: "fixture", from: .init(email: "fixture@example.invalid"), subject: "A mail", text: "UNREQUESTED_BODY_SENTINEL")
        model.mails = [mail]; model.workspacePage = .mail; model.destination = .inbox
        let scope = model.currentContext
        XCTAssertNotNil(scope.mailList); XCTAssertTrue(scope.mailIDs.isEmpty)
        ContextFixtureProtocol.install()
        await model.askPartner("Explain the available app settings.", uiContext: scope)
        let prompt = try XCTUnwrap(ContextFixtureProtocol.lastPrompt)
        XCTAssertFalse(prompt.contains("UNREQUESTED_BODY_SENTINEL"))
        XCTAssertTrue(prompt.contains("<mail-data>\n\n</mail-data>"))
        XCTAssertEqual(model.visibleChat.last?.text, "Fixture answer")
    }
    @MainActor func testSelectedMessageIsProvidedWithoutOtherInboxBodies() async throws {
        let model = makeModel()
        defer { ContextFixtureProtocol.reset(); try? FileManager.default.removeItem(at: model.store.root) }
        await model.restoreChatSessions()
        let selected = MailMessage(accountID: "fixture", from: .init(email: "fixture@example.invalid"), subject: "Chosen", text: "SELECTED_BODY_SENTINEL")
        let other = MailMessage(accountID: "fixture", from: .init(email: "other@example.invalid"), subject: "Other", text: "UNRELATED_BODY_SENTINEL")
        model.mails = [selected, other]; model.workspacePage = .mail; model.destination = .inbox; model.selectedID = selected.id
        ContextFixtureProtocol.install()
        await model.askPartner("Summarize this message.", uiContext: model.currentContext)
        let prompt = try XCTUnwrap(ContextFixtureProtocol.lastPrompt)
        XCTAssertTrue(prompt.contains("SELECTED_BODY_SENTINEL"))
        XCTAssertFalse(prompt.contains("UNRELATED_BODY_SENTINEL"))
        XCTAssertEqual(model.sidebarEvidenceMailIDs, [selected.id])
    }
    @MainActor func testLegacyListIDsAndHostRoleMetadataNeverBecomeModelEvidence() async throws {
        let model = makeModel(); defer { try? FileManager.default.removeItem(at: model.store.root) }
        let mail = MailMessage(accountID: "fixture", from: .init(email: "fixture@example.invalid"), subject: "A", text: "Body")
        model.mails = [mail]
        var legacy = WorkspaceContext(page: "mail-list", label: "Old inbox", mailIDs: [mail.id])
        let initial = try await model.initialChatEvidence(legacy)
        XCTAssertTrue(initial.isEmpty)
        XCTAssertTrue(model.chatContextForModel(legacy).mailIDs.isEmpty)
        legacy.mailList = .init(accountIDs: ["fixture"], destination: "inbox", folderRoles: ["HOST_DIRECTORY_SENTINEL": "inbox"])
        let encoded = try JSONEncoder().encode(model.chatContextForModel(legacy))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("HOST_DIRECTORY_SENTINEL"))
        XCTAssertEqual(legacy.mailList?.folderRoles.count, 1)
    }
    @MainActor private func makeModel() -> AppModel {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [ContextFixtureProtocol.self]
        let model = AppModel(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), notifications: EvidenceNotifications(), partner: PartnerEngine(ai: AIEngine(httpConfiguration: configuration)))
        model.workspacePreferences.memoryEnabled = false; model.settings.autoAnalyze = false
        model.settings.provider = "openai"; model.settings.openAIURL = "https://morrow-context-fixture.invalid/v1"; model.settings.openAIModel = "fixture"
        var account = MailAccount(); account.id = "fixture"; account.email = "owner@example.invalid"; account.isDemo = true
        model.accounts = [account]; model.folders = [.init(accountID: account.id, path: "INBOX", role: "inbox")]
        return model
    }
}

private final class ContextFixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var prompt: String?
    static var lastPrompt: String? { lock.withLock { prompt } }
    static func install() { lock.withLock { prompt = nil }; URLProtocol.registerClass(Self.self) }
    static func reset() { URLProtocol.unregisterClass(Self.self); lock.withLock { prompt = nil } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "morrow-context-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; body.append(contentsOf: buffer.prefix(count)) }
        }
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let messages = object["messages"] as? [[String: Any]] {
            Self.lock.withLock { Self.prompt = messages.compactMap { $0["content"] as? String }.joined(separator: "\n") }
        }
        let plan = #"{"answer":"Fixture answer","operations":[],"messageIDs":[]}"#
        let payload = try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": plan]]]])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor private final class EvidenceNotifications: MailNotificationManaging {
    func removePending(_ ids: [String]) {}
    func requestAuthorization() async throws -> Bool { false }
    func add(id: String, title: String, body: String, at date: Date?) async throws {}
}
