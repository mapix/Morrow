import XCTest
import CMail
@testable import MorrowCore

final class LegacySearchCacheTests: XCTestCase {
    func testRemovingUnusedLegacyCachePreservesOriginalMailAndBothSearchSources() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MailStore(root: root)
        let saved = try await store.upsert(MailMessage(accountID: "fixture", from: .init(email: "sender@example.invalid"), subject: "contract", text: "original contract evidence"))
        try await store.putVectors(messageID: saved.id, chunks: ["contract"], vectors: [[1, 0]], model: "fixture", hash: "original")
        var db: OpaquePointer?; XCTAssertEqual(sqlite3_open(root.appendingPathComponent("mail.sqlite").path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "CREATE VIRTUAL TABLE mail_fts USING fts5(id UNINDEXED,body); INSERT INTO mail_fts(id,body) VALUES('legacy','unused cache')", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let reopened = try MailStore(root: root)
        let full = try await reopened.message(saved.id)
        XCTAssertEqual(full, saved)
        let hits = try await reopened.keywordSearch("contract")
        XCTAssertEqual(hits.first?.id, saved.id)
        let indexed = try await reopened.isIndexed(saved.id, hash: "original", model: "fixture")
        XCTAssertTrue(indexed)
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("mail.sqlite").path, &db), SQLITE_OK)
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE name='mail_fts'", -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        sqlite3_finalize(statement); sqlite3_close(db)
    }
}
