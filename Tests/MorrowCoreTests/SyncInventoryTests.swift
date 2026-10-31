import XCTest
import CMail
@testable import MorrowCore

final class SyncInventoryTests: XCTestCase {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("sync-inventory-" + UUID().uuidString) }

    func testIMAPInventoryScopesAndPreservesUIDValidityBodyAndFlags() async throws {
        let location = root(); defer { try? FileManager.default.removeItem(at: location) }
        let store = try MailStore(root: location)
        var current = MailMessage(accountID: "synthetic-a", from: .init(email: "team@example.invalid"), subject: "Inventory fixture", text: String(repeating: "synthetic text\n", count: 1000))
        current.uid = UInt64(UInt32.max); current.uidValidity = UInt64(UInt32.max)
        current.html = "<html><body>" + current.text + "</body></html>"; current.raw = Data("synthetic raw MIME".utf8)
        current.isRead = true; current.isStarred = true; current.note = "Synthetic note"
        current.attachments = [.init(name: "fixture.txt", mimeType: "text/plain", data: Data("synthetic attachment".utf8))]
        let stored = try await store.upsert(current)
        var older = current; older.id = UUID().uuidString; older.uidValidity -= 1; older.raw = Data(); older.attachments = []
        try await store.upsert(older)
        var archive = current; archive.id = UUID().uuidString; archive.folder = "Archive"; archive.raw = Data(); archive.attachments = []
        try await store.upsert(archive)
        var other = current; other.id = UUID().uuidString; other.accountID = "synthetic-b"; other.raw = Data(); other.attachments = []
        try await store.upsert(other)
        let rawBefore = try await store.rawData(stored)
        let attachmentBefore = try await store.attachmentData(stored.attachments[0])

        let records = try await store.syncRecords(account: current.accountID, folder: "INBOX")
        XCTAssertEqual(Set(records.map(\.id)), [current.id, older.id])
        let valid = records.filter { $0.uidValidity == current.uidValidity }
        XCTAssertEqual(valid, [.init(id: current.id, uid: current.uid, uidValidity: current.uidValidity)])
        XCTAssertTrue(records.allSatisfy { $0.popUID == nil })
        let after = try await store.message(current.id)
        let rawAfter = try await store.rawData(stored)
        let attachmentAfter = try await store.attachmentData(stored.attachments[0])
        XCTAssertEqual(after, stored)
        XCTAssertEqual(rawAfter, rawBefore)
        XCTAssertEqual(attachmentAfter, attachmentBefore)
    }

    func testPOPAccountInventoryExtractsStableUIDLWithoutChangingMail() async throws {
        let location = root(); defer { try? FileManager.default.removeItem(at: location) }
        let store = try MailStore(root: location)
        var first = MailMessage(accountID: "synthetic-pop", from: .init(email: "team@example.invalid"), subject: "POP fixture", text: "Synthetic body")
        first.popUID = "uidl-escaped-\"-中文"; first.isRead = true
        let stored = try await store.upsert(first)
        var second = first; second.id = UUID().uuidString; second.popUID = "uidl-other"; second.folder = "LocalArchive"
        try await store.upsert(second)
        var other = first; other.id = UUID().uuidString; other.accountID = "synthetic-other"
        try await store.upsert(other)

        let records = try await store.syncRecords(account: first.accountID)
        XCTAssertEqual(Set(records.compactMap(\.popUID)), [first.popUID!, second.popUID!])
        XCTAssertEqual(Set(records.map(\.id)), [first.id, second.id])
        XCTAssertTrue(records.allSatisfy { $0.uid == 0 && $0.uidValidity == 0 })
        let after = try await store.message(first.id)
        XCTAssertEqual(after, stored)
    }

    func testIMAPInventoryDoesNotDecodeMessageJSON() async throws {
        let location = root(); defer { try? FileManager.default.removeItem(at: location) }
        let store = try MailStore(root: location)
        var mail = MailMessage(accountID: "synthetic", from: .init(email: "team@example.invalid"), subject: "Column fixture", text: "Synthetic body")
        mail.uid = 42; mail.uidValidity = 123
        try await store.upsert(mail)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(location.appendingPathComponent("mail.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "UPDATE messages SET json=x'7b'", nil, nil, nil), SQLITE_OK)
        let records = try await store.syncRecords(account: mail.accountID, folder: "INBOX")
        XCTAssertEqual(records, [.init(id: mail.id, uid: 42, uidValidity: 123)])
        do { _ = try await store.message(mail.id); XCTFail("Malformed fixture JSON unexpectedly decoded") } catch { }
    }
}
