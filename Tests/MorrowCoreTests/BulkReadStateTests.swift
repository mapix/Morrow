import XCTest
import CMail
@testable import MorrowCore

final class BulkReadStateTests: XCTestCase {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("bulk-read-" + UUID().uuidString) }
    private func query(_ root: URL, _ sql: String) throws -> [String] {
        var db: OpaquePointer?, s: OpaquePointer?
        guard sqlite3_open(root.appendingPathComponent("mail.sqlite").path, &db) == SQLITE_OK else { throw MailError.message("fixture open failed") }
        defer { sqlite3_finalize(s); sqlite3_close(db) }
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { throw MailError.message("fixture query failed") }
        var result: [String] = []
        while sqlite3_step(s) == SQLITE_ROW { result.append(sqlite3_column_text(s, 0).map { String(cString: $0) } ?? "") }
        return result
    }
    private func indexes(_ root: URL) throws -> [[String]] {
        try [
            query(root, "SELECT id || ':' || hex(body) FROM mail_fts ORDER BY id"),
            query(root, "SELECT id || ':' || message || ':' || hex(chunk) || ':' || hex(vector) || ':' || model || ':' || hash FROM vectors ORDER BY id"),
            query(root, "SELECT message || ':' || model || ':' || hash FROM index_state ORDER BY message"),
            query(root, "SELECT id || ':' || hex(search) FROM messages ORDER BY id")
        ]
    }
    func testHundredsOfReadChangesPreservePayloadAndIndexesAndUndoOnlyChangedRows() async throws {
        let location = root(); defer { try? FileManager.default.removeItem(at: location) }
        let store = try MailStore(root: location)
        let oldTimestamp = Date(timeIntervalSinceReferenceDate: 1000), changedTimestamp = Date(timeIntervalSinceReferenceDate: 2000)
        var ids = Set<String>(), expected = Set<String>()
        var reference: MailMessage?
        for i in 0..<850 {
            var mail = MailMessage(accountID: "synthetic", from: .init(email: "team@example.invalid"), subject: "fixture \(i)", text: "Synthetic body with whitespace\n retained.")
            mail.id = String(format: "mail-%04d", i); mail.isRead = i.isMultiple(of: 3); mail.isStarred = true; mail.labels = ["synthetic-label"]; mail.note = "Synthetic note"
            mail.html = "<p>Synthetic <strong>HTML</strong></p>"; mail.analysis = PartnerEngine.baseline(mail); mail.localFlagModifiedAt = oldTimestamp
            if i == 1 { mail.raw = Data("synthetic raw MIME".utf8); mail.attachments = [.init(name: "fixture.txt", mimeType: "text/plain", data: Data("synthetic file".utf8))] }
            let stored = try await store.upsert(mail)
            if i == 1 { reference = stored; try await store.putVectors(messageID: stored.id, chunks: [stored.text], vectors: [[1, 0, 0]], model: "fixture", hash: "unchanged-body") }
            ids.insert(mail.id); if !mail.isRead { expected.insert(mail.id) }
        }
        ids.insert("missing-id")
        let before = try indexes(location)
        let changes = try await store.setReadState(ids: ids, read: true, modifiedAt: changedTimestamp)
        XCTAssertEqual(Set(changes.map(\.id)), expected)
        XCTAssertTrue(changes.allSatisfy { !$0.wasRead })
        let alreadyRead = try await store.message("mail-0000")
        XCTAssertEqual(alreadyRead?.localFlagModifiedAt, oldTimestamp)
        var altered = try await store.message(reference!.id)
        XCTAssertEqual(altered?.isRead, true); XCTAssertEqual(altered?.localFlagModifiedAt, changedTimestamp)
        altered?.isRead = reference!.isRead; altered?.localFlagModifiedAt = reference!.localFlagModifiedAt
        XCTAssertEqual(altered, reference)
        let raw = try await store.rawData(reference!)
        let attachment = try await store.attachmentData(reference!.attachments[0])
        XCTAssertEqual(raw, Data("synthetic raw MIME".utf8)); XCTAssertEqual(attachment, Data("synthetic file".utf8))
        XCTAssertEqual(try indexes(location), before)
        let restored = try await store.restoreReadState(changes: changes, modifiedAt: Date(timeIntervalSinceReferenceDate: 3000))
        XCTAssertEqual(restored, expected)
        let remaining = try await store.messages()
        XCTAssertTrue(remaining.enumerated().allSatisfy { _, mail in mail.isRead == (Int(mail.id.suffix(4))!.isMultiple(of: 3)) })
        XCTAssertEqual(try indexes(location), before)
    }
    func testCanonicalCopiesStayWithinAccountAndReverseReadOperationRestoresTrue() async throws {
        let location = root(); defer { try? FileManager.default.removeItem(at: location) }
        let store = try MailStore(root: location)
        var inbox = MailMessage(accountID: "synthetic-a", from: .init(email: "team@example.invalid"), subject: "mirror fixture", text: "Synthetic body")
        inbox.messageID = "<same-message@example.invalid>"; inbox.isRead = true
        var mirror = inbox; mirror.id = "archive-copy"; mirror.folder = "Archive"
        var other = inbox; other.id = "unrelated-account"; other.accountID = "synthetic-b"
        try await store.upsert(inbox); try await store.upsert(mirror); try await store.upsert(other)
        let changes = try await store.setReadState(ids: [inbox.id], read: false, includeCanonicalCopies: true)
        XCTAssertEqual(Set(changes.map(\.id)), [inbox.id, mirror.id]); XCTAssertTrue(changes.allSatisfy(\.wasRead))
        let unrelated = try await store.message(other.id); XCTAssertEqual(unrelated?.isRead, true)
        let restored = try await store.restoreReadState(changes: changes)
        XCTAssertEqual(restored, [inbox.id, mirror.id])
        let restoredInbox = try await store.message(inbox.id), restoredMirror = try await store.message(mirror.id)
        XCTAssertEqual(restoredInbox?.isRead, true); XCTAssertEqual(restoredMirror?.isRead, true)
    }
    func testMalformedJSONRollsBackWholeBatchAndRestore() async throws {
        let location = root(); defer { try? FileManager.default.removeItem(at: location) }
        let store = try MailStore(root: location)
        var good = MailMessage(accountID: "synthetic", from: .init(email: "team@example.invalid"), subject: "good fixture", text: "Synthetic body")
        good.id = "a-good"; var damaged = good; damaged.id = "z-damaged"
        try await store.upsert(good); try await store.upsert(damaged)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(location.appendingPathComponent("mail.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "UPDATE messages SET json=x'7b' WHERE id='z-damaged'", nil, nil, nil), SQLITE_OK)
        do { _ = try await store.setReadState(ids: [good.id, damaged.id], read: true); XCTFail("Malformed JSON accepted") } catch { }
        let untouched = try await store.message(good.id); XCTAssertEqual(untouched?.isRead, false); XCTAssertNil(untouched?.localFlagModifiedAt)
        let changes = try await store.setReadState(ids: [good.id], read: true)
        do { _ = try await store.restoreReadState(changes: changes + [.init(id: damaged.id, wasRead: false)]); XCTFail("Malformed restore accepted") } catch { }
        let stillRead = try await store.message(good.id); XCTAssertEqual(stillRead?.isRead, true)
    }
}
