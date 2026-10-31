import XCTest
@testable import MorrowCore

final class SubmittedChatTests: XCTestCase {
    func testSubmissionAtomicallyClearsCapturedInputAndKeepsUserMessage() async throws {
        let store = try MailStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var session = ChatSession(id: "a", title: "New chat"); session.input = "Review invoices"; session.draftRevision = 1
        try await store.save(session, kind: "chat-session", id: session.id)
        var user = PartnerChat(role: "user", text: session.input); user.sessionID = session.id
        session.input = ""; session.draftRevision += 1
        let committed = try await store.commitSubmittedChat(user, session: session)
        XCTAssertEqual(committed.input, ""); XCTAssertEqual(committed.title, "Review invoices")
        let saved = try await store.object(PartnerChat.self, kind: "chat", id: user.id)
        XCTAssertEqual(saved?.text, "Review invoices"); XCTAssertEqual(saved?.sessionID, "a")
    }
    func testSubmissionCannotEraseNewerInputInSameOrAnotherSession() async throws {
        let store = try MailStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var captured = ChatSession(id: "a", title: "Thread"); captured.input = "First request"; captured.draftRevision = 1
        var user = PartnerChat(role: "user", text: captured.input); user.sessionID = captured.id
        var newer = captured; newer.input = "Next request while waiting"; newer.draftRevision = 3
        try await store.save(newer, kind: "chat-session", id: newer.id)
        var other = ChatSession(id: "b", title: "Other"); other.input = "Other draft"
        try await store.save(other, kind: "chat-session", id: other.id)
        captured.input = ""; captured.draftRevision = 2
        let committed = try await store.commitSubmittedChat(user, session: captured)
        XCTAssertEqual(committed.input, newer.input); XCTAssertEqual(committed.draftRevision, 3)
        let untouched = try await store.object(ChatSession.self, kind: "chat-session", id: other.id)
        XCTAssertEqual(untouched?.input, "Other draft")
    }
}
