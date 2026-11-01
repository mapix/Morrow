import XCTest
import CMail
@testable import MorrowCore

final class BackgroundMailPerformanceTests: XCTestCase {
    func testRemoteFlagsPreserveSourceVectorsAndConcurrentLocalEdits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MailStore(root: root)
        var mail = MailMessage(accountID: "fixture", from: .init(email: "sender@example.invalid"), subject: "Full source", text: String(repeating: "source\n", count: 1000))
        mail.html = "<table><tr><td>original</td></tr></table>"; mail.note = "keep note"; mail.labels = ["keep label"]
        mail = try await store.upsert(mail)
        try await store.putVectors(messageID: mail.id, chunks: ["source"], vectors: [[1, 0]], model: "fixture", hash: "index-hash")
        let beginning = Date(timeIntervalSince1970: 100)
        let changed = try await store.applyRemoteFlagStates([.init(id: mail.id, read: true, starred: true)], inventoryStarted: beginning)
        XCTAssertEqual(changed, 1)
        let source = try await store.message(mail.id)
        XCTAssertEqual(source?.text, mail.text); XCTAssertEqual(source?.html, mail.html)
        XCTAssertEqual(source?.note, mail.note); XCTAssertEqual(source?.labels, mail.labels)
        XCTAssertEqual(source?.contentRevision, mail.contentRevision); XCTAssertNil(source?.localFlagModifiedAt)
        let summaries = try await store.messageSummaries()
        XCTAssertTrue(summaries[0].displayMessage.isRead); XCTAssertTrue(summaries[0].displayMessage.isStarred)
        let indexed = try await store.isIndexed(mail.id, hash: "index-hash", model: "fixture")
        XCTAssertTrue(indexed)
        _ = try await store.setReadState(ids: [mail.id], read: false, modifiedAt: beginning.addingTimeInterval(1))
        let stale = try await store.applyRemoteFlagStates([.init(id: mail.id, read: true, starred: false)], inventoryStarted: beginning)
        XCTAssertEqual(stale, 0)
        let after = try await store.message(mail.id)
        XCTAssertEqual(after?.isRead, false); XCTAssertEqual(after?.isStarred, true)
    }

    func testIndexReceiptSkipsBodiesAndSurvivesRestartButRejectsChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MailStore(root: root)
        var mail = MailMessage(accountID: "fixture", from: .init(email: "sender@example.invalid"), subject: "source", text: "original")
        mail = try await store.upsert(mail)
        try await store.putVectors(messageID: mail.id, chunks: ["original"], vectors: [[1, 0]], model: EmbeddingIndex.checkpoint, hash: "current-hash")
        try await store.rememberIndexInput(mail, attachments: false, model: EmbeddingIndex.checkpoint, hash: "current-hash")
        let reopened = try MailStore(root: root), index = EmbeddingIndex()
        var header = try await reopened.messageSummaries()[0].displayMessage
        // Corrupt only full JSON after creating the projection: the eligibility
        // check must operate without decoding that body.
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("mail.sqlite").path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "UPDATE messages SET json=x'7b'", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        var pending = try await index.pendingMessageIDs([header], store: reopened, attachments: false)
        XCTAssertTrue(pending.isEmpty)
        header.isRead.toggle(); header.isStarred.toggle()
        pending = try await index.pendingMessageIDs([header], store: reopened, attachments: false)
        XCTAssertTrue(pending.isEmpty)
        header.note = "new evidence"
        pending = try await index.pendingMessageIDs([header], store: reopened, attachments: false)
        XCTAssertEqual(pending, [mail.id])
        pending = try await index.pendingMessageIDs([mail], store: reopened, attachments: true)
        XCTAssertEqual(pending, [mail.id])
        try await store.putVectors(messageID: mail.id, chunks: ["replaced"], vectors: [[0, 1]], model: EmbeddingIndex.checkpoint, hash: "different-hash")
        pending = try await index.pendingMessageIDs([mail], store: reopened, attachments: false)
        XCTAssertEqual(pending, [mail.id])
    }

    func testIndexReceiptDoesNotCertifyStaleContentAfterConcurrentEdit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MailStore(root: root)
        let original = try await store.upsert(MailMessage(accountID: "fixture", from: .init(email: "sender@example.invalid"), subject: "source", text: "original"))
        var edited = original; edited.note = "new evidence"; edited = try await store.upsert(edited)
        try await store.putVectors(messageID: original.id, chunks: ["original"], vectors: [[1, 0]], model: EmbeddingIndex.checkpoint, hash: "old-hash")
        try await store.rememberIndexInput(original, attachments: false, model: EmbeddingIndex.checkpoint, hash: "old-hash")
        let pending = try await EmbeddingIndex().pendingMessageIDs([edited], store: store, attachments: false)
        XCTAssertEqual(pending, [original.id])
    }
}
