import XCTest
@testable import MorrowCore

final class ConversationMemoryTests: XCTestCase {
    func testSessionOrderIgnoresActivityAndPinSurvivesStaleMetadataAndDraftSaves() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let store = try MailStore(root: root)
        var older = ChatSession(id: "older", title: "Earlier"); older.createdAt = Date(timeIntervalSince1970: 100)
        var newer = ChatSession(id: "newer", title: "Later"); newer.createdAt = Date(timeIntervalSince1970: 200)
        older.updatedAt = Date(timeIntervalSince1970: 999)
        XCTAssertEqual([older, newer].sorted(by: ChatSession.sidebarPrecedes).map(\.id), ["newer", "older"])
        try await store.save(older, kind: "chat-session", id: older.id)
        let pinned = try await store.setSessionPinned(older.id, pinned: true, at: Date(timeIntervalSince1970: 300))
        XCTAssertEqual([newer, pinned].sorted(by: ChatSession.sidebarPrecedes).first?.id, older.id)
        older.title = "Renamed"; _ = try await store.saveSessionMetadata(older)
        older.input = "Unsent draft"; older.draftRevision = 1; _ = try await store.saveSessionDraft(older)
        let stored = try await store.object(ChatSession.self, kind: "chat-session", id: older.id)
        let restored = try XCTUnwrap(stored)
        XCTAssertEqual(restored.pinnedAt, pinned.pinnedAt); XCTAssertEqual(restored.title, "Renamed"); XCTAssertEqual(restored.input, "Unsent draft")
        var message = PartnerChat(role: "partner", text: "Background result"); message.sessionID = older.id
        let committed = try await store.commitChat(message, session: older)
        XCTAssertEqual(committed.pinnedAt, pinned.pinnedAt)
        let unpinned = try await store.setSessionPinned(older.id, pinned: false)
        XCTAssertEqual([unpinned, newer].sorted(by: ChatSession.sidebarPrecedes).map(\.id), ["newer", "older"])
        var encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(older)) as? [String: Any]); encoded.removeValue(forKey: "pinnedAt")
        XCTAssertFalse(try JSONDecoder().decode(ChatSession.self, from: JSONSerialization.data(withJSONObject: encoded)).isPinned)
    }
    func testMemoryScopesExpiryAndInactiveVersionsNeverLeak() {
        var global = AgentMemory(content: "默认简洁中文", kind: .preference); global.confirmed = true
        let a = AgentMemory(content: "本会话项目", scope: .session, scopeID: "a")
        let b = AgentMemory(content: "另一个会话", scope: .session, scopeID: "b")
        let contact = AgentMemory(content: "林舟的角色", scope: .contact, scopeID: "lin@example.com")
        var expired = AgentMemory(content: "过去期限"); expired.expiresAt = .distantPast
        var paused = AgentMemory(content: "已停用"); paused.status = "paused"
        var old = AgentMemory(content: "旧版本"); old.status = "superseded"
        let hits = MemoryRanking.search([global,a,b,contact,expired,paused,old],query:"",sessionID:"a",contactEmail:"lin@example.com")
        XCTAssertEqual(Set(hits.map(\.id)),Set([global.id,a.id,contact.id]))
    }
    func testDenseRecallUsesMeaningAndRejectsWrongVectorShape() {
        var relevant = AgentMemory(content:"验收条款"); relevant.embedding = [1,0]
        var unrelated = AgentMemory(content:"产品周刊"); unrelated.embedding = [0,1]
        let hits = MemoryRanking.search([relevant,unrelated],query:"合同核对",vector:[1,0],sessionID:nil,contactEmail:nil)
        XCTAssertEqual(hits.first?.id,relevant.id)
        XCTAssertTrue(MemoryRanking.search([relevant],query:"无匹配",vector:[1,0,0],sessionID:nil,contactEmail:nil).isEmpty)
    }
    func testSessionDraftUpdatesPreserveTitleAndRejectStaleWrites() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
        let first = try MailStore(root:root), second = try MailStore(root:root)
        let session = ChatSession(id:"s",title:"原始标题"); try await first.save(session,kind:"chat-session",id:session.id)
        var draft = session; draft.input = "新输入"; draft.draftRevision = 2
        _ = try await first.saveSessionDraft(draft)
        var title = session; title.title = "改名后的标题"; _ = try await second.saveSessionMetadata(title)
        var stale = session; stale.input = "旧输入"; stale.draftRevision = 1; _ = try await second.saveSessionDraft(stale)
        let stored = try await first.object(ChatSession.self,kind:"chat-session",id:"s")
        XCTAssertEqual(stored?.title,"改名后的标题"); XCTAssertEqual(stored?.input,"新输入")
    }
    func testLegacyChatAndSettingsDecodeWithoutNewFields() throws {
        let chat = try JSONDecoder().decode(PartnerChat.self,from:Data(#"{"id":"old","role":"user","text":"hello","date":0,"messageIDs":[]}"#.utf8)); XCTAssertNil(chat.sessionID)
        let settings = AgentSettings(); let encoded = try JSONEncoder().encode(settings); XCTAssertNil(try JSONDecoder().decode(AgentSettings.self,from:encoded).openAIURL)
        XCTAssertThrowsError(try ModelEndpoint.url("http://remote.example.com/v1",path:"models"))
        XCTAssertThrowsError(try ModelEndpoint.url("https://api.example.com/v1?key=secret",path:"models"))
        XCTAssertEqual(try ModelEndpoint.url("http://127.0.0.1:1234/v1/",path:"chat/completions").path,"/v1/chat/completions")
    }
}
