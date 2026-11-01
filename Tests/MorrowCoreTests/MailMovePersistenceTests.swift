import XCTest
import CMail
@testable import MorrowCore

final class MailMovePersistenceTests: XCTestCase {
    private func fixture() async throws -> (MailStore, MailMessage, MailMessage) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("move-persistence-" + UUID().uuidString)
        let store = try MailStore(root: root)
        var source = MailMessage(accountID: "a", from: .init(email: "sender@example.invalid"), subject: "Preserved source", text: "Original body\nwith whitespace")
        source.id = "source"; source.uid = 7; source.uidValidity = 42; source.messageID = "<source@example.invalid>"
        source.raw = Data("Original fixture MIME\r\n".utf8); source.html = "<p>Original body</p>"
        source.attachments = [.init(name: "proof.txt", mimeType: "text/plain", data: Data("Original asset".utf8))]
        let raw = source.raw; source = try await store.upsert(source)
        var alias = source; alias.id = "alias"; alias.folder = "All Mail"; alias.uid = 81; alias.uidValidity = 43; alias.raw = raw
        alias = try await store.upsert(alias)
        try await store.putVectors(messageID: source.id, chunks: [source.text], vectors: [[1, 0]], model: "fixture", hash: source.bodyVersion)
        return (store, source, alias)
    }
    func testConfirmedMovePreservesBodyFilesAliasesVectorsAndKeywordEvidence() async throws {
        let (store, source, alias) = try await fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
        let moved = try await store.commitMovedMessage(source: source, destination: .init(accountID: "a", path: "Archive", role: "archive"), receipt: .parse("[COPYUID 99 7 9]"))
        XCTAssertEqual(moved.id, "a:Archive:99:9"); XCTAssertEqual(moved.bodyVersion, source.bodyVersion)
        XCTAssertEqual(moved.text, source.text); XCTAssertEqual(moved.html, source.html)
        XCTAssertNotEqual(moved.attachments[0].storedPath, alias.attachments[0].storedPath)
        let old = try await store.message(source.id), count = try await store.indexCount()
        XCTAssertNil(old); XCTAssertEqual(count, 1)
        let hits = try await store.keywordSearch("Preserved source", allowedIDs: [moved.id]); XCTAssertEqual(hits.first?.id, moved.id)
        try await store.deleteMessage(alias.id)
        let raw = try await store.rawData(moved), attachment = try await store.attachmentData(moved.attachments[0])
        XCTAssertEqual(raw, Data("Original fixture MIME\r\n".utf8)); XCTAssertEqual(attachment, Data("Original asset".utf8))
    }
    func testSQLiteFailureRollsBackRowsAndNewHardlinks() async throws {
        let (store, source, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(store.root.appendingPathComponent("mail.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TRIGGER abort_fixture_move BEFORE INSERT ON messages WHEN new.id='a:Archive:99:9' BEGIN SELECT RAISE(ABORT,'synthetic failure'); END", nil, nil, nil), SQLITE_OK)
        do {
            _ = try await store.commitMovedMessage(source: source, destination: .init(accountID: "a", path: "Archive"), receipt: .parse("[COPYUID 99 7 9]"))
            XCTFail("Failed transaction accepted")
        } catch {}
        let current = try await store.message(source.id), destination = try await store.message("a:Archive:99:9")
        XCTAssertEqual(current?.folder, "INBOX"); XCTAssertNil(destination)
        let raw = try await store.rawData(source); XCTAssertEqual(raw, Data("Original fixture MIME\r\n".utf8))
        let destinationRaw = await store.rawURL("a:Archive:99:9")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationRaw.path))
        let count = try await store.indexCount(); XCTAssertEqual(count, 1)
    }
    func testStaleSourceOrWrongCopyUIDCannotCommitAnotherLocation() async throws {
        let (store, source, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
        var stale = source; stale.uidValidity = 41
        for (original, receipt) in [(stale, MailMoveReceipt.parse("[COPYUID 99 7 9]")), (source, .parse("[COPYUID 99 8 9]"))] {
            do { _ = try await store.commitMovedMessage(source: original, destination: .init(accountID: "a", path: "Archive"), receipt: receipt); XCTFail("Wrong mapping accepted") } catch {}
        }
        let original = try await store.message(source.id); XCTAssertEqual(original?.folder, "INBOX")
    }
    func testDeletingOneSharedLegacyAttachmentPathDoesNotDamageAnotherAlias() async throws {
        let (store, source, alias) = try await fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
        XCTAssertEqual(source.attachments[0].storedPath, alias.attachments[0].storedPath)
        try await store.deleteMessage(source.id)
        let bytes = try await store.attachmentData(alias.attachments[0]), raw = try await store.rawData(alias)
        XCTAssertEqual(bytes, Data("Original asset".utf8)); XCTAssertEqual(raw, Data("Original fixture MIME\r\n".utf8))
    }
}
