import XCTest
import CMail
@testable import MorrowCore

final class SearchMetadataTests: XCTestCase {
    func testCoverageAndTopKDoNotDecodeUnselectedLargeBodies() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("metadata-search-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MailStore(root: root)
        let winner = MailMessage(accountID: "synthetic", from: .init(email: "team@example.invalid"), subject: "Contract review", text: "delivery")
        var copy = winner; copy.id = "archive-copy"; copy.folder = "Archive"; copy.messageID = "<same@example.invalid>"
        var primary = winner; primary.messageID = copy.messageID
        var lower = MailMessage(accountID: "synthetic", from: .init(email: "other@example.invalid"), subject: "Unrelated", text: "other")
        lower.id = "low-ranked"; lower.html = String(repeating: "<p>Long newsletter body</p>", count: 10_000)
        for (mail, vector) in [(primary, [Float(1), 0]), (copy, [Float(1), 0]), (lower, [Float(0), 1])] {
            try await store.upsert(mail)
            try await store.putVectors(messageID: mail.id, chunks: [mail.text], vectors: [vector], model: "fixture", hash: "fixture")
        }
        // A broken body outside Top-K must not make metadata counting or the
        // selected hit fail. This also catches accidental eager body decoding.
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("mail.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "UPDATE messages SET json=x'7b' WHERE id='low-ranked'", nil, nil, nil), SQLITE_OK)
        let coverage = try await store.searchIndexCoverage(model: "fixture", dimensions: 2)
        XCTAssertEqual(coverage.eligibleCount, 2); XCTAssertEqual(coverage.indexedCount, 2)
        let hits = try await store.vectorSearch([1, 0], model: "fixture", limit: 1)
        XCTAssertEqual(hits.map(\.id), [primary.id]); XCTAssertEqual(hits.first?.score, 1)
        let empty = try await store.searchIndexCoverage(model: "fixture", allowedIDs: [], dimensions: 2)
        XCTAssertEqual(empty.eligibleCount, 0); XCTAssertEqual(empty.indexedCount, 0)
    }
}
