import XCTest
import CMail
@testable import MorrowCore

final class MailKeywordSearchTests: XCTestCase {
    func testScopeFiltersRankingAndOriginalBodyArePreserved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("keyword-contract-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MailStore(root: root)
        var inbox = MailMessage(accountID: "a", from: .init(email: "author@example.invalid"), subject: "Contract", text: "Complete contract delivery evidence \n with detail beyond the header.")
        inbox.id = "inbox"; inbox.messageID = "<canonical@example.invalid>"; inbox.date = Date()
        var sent = inbox; sent.id = "sent"; sent.folder = "Sent"; sent.text = "Contract"; sent.date = inbox.date.addingTimeInterval(1)
        var foreign = inbox; foreign.id = "foreign"; foreign.accountID = "b"
        _ = try await store.upsert(inbox); _ = try await store.upsert(sent); _ = try await store.upsert(foreign)
        let scoped = try await store.keywordSearch("from:author contract delivery", allowedIDs: [inbox.id, sent.id])
        XCTAssertEqual(scoped.count, 1); XCTAssertEqual(scoped.first?.id, inbox.id); XCTAssertEqual(scoped.first?.message.text, inbox.text)
        XCTAssertEqual(scoped.first?.message.contentAvailability, nil)
        let isolated = try await store.keywordSearch("contract", allowedIDs: [sent.id])
        XCTAssertEqual(isolated.map(\.id), [sent.id])
        let empty = try await store.keywordSearch("contract", allowedIDs: [])
        XCTAssertTrue(empty.isEmpty)
    }

    private func seed(_ root: URL) throws {
        var db: OpaquePointer?, insert: OpaquePointer?
        guard sqlite3_open(root.appendingPathComponent("mail.sqlite").path, &db) == SQLITE_OK else { throw MailError.message("Fixture open failed") }
        defer { sqlite3_finalize(insert); sqlite3_close(db) }
        guard sqlite3_exec(db, "PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF; PRAGMA max_page_count=23040; BEGIN", nil, nil, nil) == SQLITE_OK,
              sqlite3_prepare_v2(db, "INSERT INTO messages(id,account,folder,uid,validity,date,search,json,canonical) VALUES(?,'fixture','INBOX',1,1,?,?,?,?)", -1, &insert, nil) == SQLITE_OK else { throw MailError.message("Fixture prepare failed") }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self), encoder = JSONEncoder()
        let search = String(repeating: "synthetic searchable mail text ", count: 256)
        for i in 0..<8000 {
            var mail = MailMessage(accountID: "fixture", from: .init(email: "test@example.invalid"), subject: "Fixture", text: "Original source")
            mail.id = "fixture-\(i)"
            let bytes = try encoder.encode(mail)
            sqlite3_bind_text(insert, 1, mail.id, -1, transient); sqlite3_bind_double(insert, 2, Double(i))
            sqlite3_bind_text(insert, 3, search, -1, transient)
            bytes.withUnsafeBytes { _ = sqlite3_bind_blob(insert, 4, $0.baseAddress, Int32(bytes.count), transient) }
            sqlite3_bind_text(insert, 5, mail.id, -1, transient)
            guard sqlite3_step(insert) == SQLITE_DONE else { throw MailError.message("Fixture exceeded disk budget") }
            sqlite3_reset(insert); sqlite3_clear_bindings(insert)
        }
        guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw MailError.message("Fixture commit failed") }
    }

    func testLargeKeywordScanDoesNotBlockStoreAndCancelsPromptly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("keyword-performance-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MailStore(root: root); try seed(root)
        let query = (0..<20).map { "unmatched-probe-\($0)" }.joined(separator: " ")
        let scan = Task { try await store.keywordSearch(query) }
        try await Task.sleep(for: .milliseconds(20))
        let lookupStart = Date(); let mail = try await store.message("fixture-0")
        XCTAssertNotNil(mail); XCTAssertLessThan(Date().timeIntervalSince(lookupStart), 0.2, "Ranking must not monopolize the delivery/write actor")
        let cancelStart = Date(); scan.cancel()
        do { _ = try await scan.value; XCTFail("Cancelled full scan finished") } catch is CancellationError { }
        XCTAssertLessThan(Date().timeIntervalSince(cancelStart), 0.5)
        let scopedStart = Date()
        let scoped = try await store.keywordSearch(query, allowedIDs: Set((0..<50).map { "fixture-\($0)" }))
        XCTAssertTrue(scoped.isEmpty); XCTAssertLessThan(Date().timeIntervalSince(scopedStart), 0.2)
        let dataSize = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("mail.sqlite").path)[.size] as? NSNumber
        XCTAssertLessThan(dataSize?.intValue ?? Int.max, 96 * 1024 * 1024)
    }
}
