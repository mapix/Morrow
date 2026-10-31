import XCTest
import CMail
@testable import MorrowCore

final class ProjectionStorageTests: XCTestCase {
    private func location() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("projection-storage-" + UUID().uuidString) }
    private func sql(_ root: URL, _ query: String) throws -> [String] {
        var db: OpaquePointer?, statement: OpaquePointer?
        guard sqlite3_open(root.appendingPathComponent("mail.sqlite").path, &db) == SQLITE_OK else { throw MailError.message("fixture open failed") }
        defer { sqlite3_finalize(statement); sqlite3_close(db) }
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { throw MailError.message("fixture statement failed") }
        var result: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW { result.append(sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "") }
        return result
    }
    private func fixture() -> MailMessage {
        var value = MailMessage(accountID: "synthetic", from: .init(name: "Synthetic Contact", email: "sender@example.invalid"), subject: "Synthetic fixture", text: String(repeating: "Full contact evidence and body.\n", count: 1000))
        value.id = "synthetic-mail"; value.html = String(repeating: "<p>Full HTML body</p>", count: 10000)
        value.to = [.init(email: "owner@example.invalid")]
        value.raw = Data("raw fixture".utf8)
        value.attachments = [.init(name: "inline.txt", mimeType: "text/plain", data: Data("inline fixture".utf8), contentID: "inline@fixture")]
        value.analysis = MailAnalysis(summary: "Synthetic summary", priority: 2, needsReply: true)
        value.analysis?.evidenceText = value.text; value.labels = ["fixture"]; value.note = "Fixture note"
        return value
    }
    func testSummaryDoesNotRetainBodyFilesOrEvidenceAndCannotOverwriteOriginal() async throws {
        let root = location(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try MailStore(root: root), saved = try await store.upsert(fixture())
        let summaries = try await store.messageSummaries()
        let summary = try XCTUnwrap(summaries.first), display = summary.displayMessage
        XCTAssertEqual(display.text.count, 300); XCTAssertTrue(display.html.isEmpty); XCTAssertTrue(display.raw.isEmpty)
        XCTAssertNil(display.analysis?.evidenceText); XCTAssertTrue(display.attachments.allSatisfy { $0.data.isEmpty })
        XCTAssertEqual(display.labels, saved.labels); XCTAssertEqual(display.note, saved.note)
        XCTAssertEqual(display.analysis?.summary, saved.analysis?.summary); XCTAssertTrue(summary.hasHTML)
        XCTAssertEqual(summary.contentRevision, saved.contentRevision); XCTAssertEqual(display.contentAvailability, .preview)
        do { _ = try await store.upsert(display); XCTFail("Partial mail overwritten") } catch { }
        let loadedFull = try await store.message(saved.id)
        let full = try XCTUnwrap(loadedFull)
        XCTAssertEqual(full.text, saved.text); XCTAssertEqual(full.html, saved.html)
        let contactValues = try await store.contactMessages()
        let textOnly = try XCTUnwrap(contactValues.first)
        XCTAssertEqual(textOnly.text, saved.text); XCTAssertEqual(textOnly.contentAvailability, .textOnly)
        XCTAssertTrue(textOnly.html.isEmpty); XCTAssertTrue(textOnly.raw.isEmpty); XCTAssertNil(textOnly.analysis?.evidenceText)
        do { _ = try await store.upsert(textOnly); XCTFail("Contact projection overwritten") } catch { }
        XCTAssertLessThan(try JSONEncoder().encode(summary).count, 4000)
    }
    func testBodyVersionStableForMetadataChangesAndUpdatesForTextHTMLAndInlineBytes() async throws {
        let root = location(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try MailStore(root: root); var saved = try await store.upsert(fixture())
        let revision = saved.bodyVersion, inventory = try await store.profileInventoryFingerprint()
        saved.isRead = true; saved.isStarred = true; saved.labels.append("changed"); saved.note = "Changed note"; saved.analysis?.reasoning = "Changed metadata"
        saved = try await store.upsert(saved)
        XCTAssertEqual(saved.bodyVersion, revision)
        let metadataInventory = try await store.profileInventoryFingerprint()
        XCTAssertEqual(metadataInventory, inventory)
        saved.subject = "Changed subject"; saved = try await store.upsert(saved)
        XCTAssertEqual(saved.bodyVersion, revision)
        let subjectInventory = try await store.profileInventoryFingerprint()
        XCTAssertNotEqual(subjectInventory, inventory)
        saved.text += "New evidence"; saved = try await store.upsert(saved)
        let textRevision = saved.bodyVersion; XCTAssertNotEqual(textRevision, revision)
        saved.html += "<p>New HTML</p>"; saved = try await store.upsert(saved)
        let htmlRevision = saved.bodyVersion; XCTAssertNotEqual(htmlRevision, textRevision)
        saved.attachments[0].data = Data("changed inline fixture".utf8); saved = try await store.upsert(saved)
        XCTAssertNotEqual(saved.bodyVersion, htmlRevision)
        let summary = try await store.messageSummaries().first
        XCTAssertEqual(summary?.contentRevision, saved.contentRevision)
    }
    func testReadUndoCacheRepairLegacyBackfillAndDeletionKeepOriginalSafe() async throws {
        let root = location(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try MailStore(root: root), saved = try await store.upsert(fixture())
        let legacy = "UPDATE messages SET json=json_remove(CAST(json AS TEXT),'$.contentRevision','$.attachments[0].contentRevision'); DELETE FROM message_projections"
        var db: OpaquePointer?; XCTAssertEqual(sqlite3_open(root.appendingPathComponent("mail.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, legacy, nil, nil, nil), SQLITE_OK)
        let originalBytes = try sql(root, "SELECT hex(json) FROM messages")
        let legacySummaries = try await store.messageSummaries()
        let summary = try XCTUnwrap(legacySummaries.first)
        XCTAssertNotNil(summary.contentRevision); XCTAssertEqual(try sql(root, "SELECT hex(json) FROM messages"), originalBytes)
        let full = try await store.message(saved.id); XCTAssertEqual(full?.bodyVersion, summary.displayMessage.bodyVersion)
        let changes = try await store.setReadState(ids: [saved.id], read: true)
        let read = try await store.messageSummaries().first
        XCTAssertEqual(read?.displayMessage.isRead, true); XCTAssertEqual(read?.contentRevision, summary.contentRevision)
        _ = try await store.restoreReadState(changes: changes)
        let unread = try await store.messageSummaries().first; XCTAssertEqual(unread?.displayMessage.isRead, false)
        XCTAssertEqual(sqlite3_exec(db, "UPDATE message_projections SET json='{}'", nil, nil, nil), SQLITE_OK)
        let rebuilt = try await store.messageSummaries().first; XCTAssertEqual(rebuilt?.displayMessage.text, summary.displayMessage.text)
        XCTAssertEqual(rebuilt?.contentRevision, summary.contentRevision)
        try await store.deleteMessage(saved.id)
        XCTAssertEqual(try sql(root, "SELECT count(*) FROM message_projections"), ["0"])
    }
    func testPaginationScopesAndBoundedAttachmentReads() async throws {
        let root = location(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try MailStore(root: root)
        for i in 0..<130 {
            var mail = MailMessage(accountID: i.isMultiple(of: 2) ? "a" : "b", from: .init(email: "sender@example.invalid"), subject: "Fixture", text: "Complete text")
            mail.id = "fixture-\(i)"; mail.date = Date(timeIntervalSince1970: Double(i)); mail.folder = i.isMultiple(of: 3) ? "Archive" : "INBOX"
            try await store.upsert(mail)
        }
        let scoped = try await store.messageSummaries(account: "a", folder: "INBOX", limit: 3, offset: 2)
        XCTAssertEqual(scoped.count, 3); XCTAssertTrue(scoped.allSatisfy { $0.displayMessage.accountID == "a" && $0.displayMessage.folder == "INBOX" })
        let large = root.appendingPathComponent("attachments/synthetic-large"); try Data(repeating: 1, count: 1024).write(to: large)
        var attachment = MailAttachment(name: "large.bin", mimeType: "application/octet-stream", data: Data())
        attachment.storedPath = large.path; attachment.byteCount = 1 // stale metadata cannot bypass the actual file cap
        do { _ = try await store.attachmentData(attachment, maximumBytes: 100); XCTFail("Oversized file read") } catch { }
    }
    private func executeFixtureSQL(_ root: URL, _ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(root.appendingPathComponent("mail.sqlite").path, &db) == SQLITE_OK else { throw MailError.message("fixture open failed") }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw MailError.message("fixture mutation failed") }
    }
    private func replacePreview(_ root: URL, id: String, text: String) throws {
        var db: OpaquePointer?, statement: OpaquePointer?
        guard sqlite3_open(root.appendingPathComponent("mail.sqlite").path, &db) == SQLITE_OK else { throw MailError.message("fixture open failed") }
        defer { sqlite3_finalize(statement); sqlite3_close(db) }
        guard sqlite3_prepare_v2(db, "UPDATE message_projections SET json=json_set(CAST(json AS TEXT),'$.projectedMessage.text',?) WHERE message=?", -1, &statement, nil) == SQLITE_OK else { throw MailError.message("fixture prepare failed") }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, text, -1, transient); sqlite3_bind_text(statement, 2, id, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw MailError.message("fixture update failed") }
    }
    func testCRLFAndCombiningEmojiNeverExpandSummaryBeyond300Graphemes() {
        let examples = [String(repeating: "\r\n", count: 300), String(repeating: "e\u{301}👨‍👩‍👧‍👦邮件\r\n", count: 300), String(repeating: "a\r\nb\rc\n", count: 200)]
        for text in examples {
            let message = MailMessage(accountID: "synthetic", from: .init(email: "source@example.invalid"), subject: "Unicode projection", text: text)
            let summary = MailMessageSummary(message: message)
            XCTAssertLessThanOrEqual(summary.displayMessage.text.count, 300)
            XCTAssertFalse(summary.displayMessage.text.contains("\r")); XCTAssertFalse(summary.displayMessage.text.contains("\n"))
            XCTAssertEqual(summary.displayMessage.contentAvailability, .preview)
        }
        let crlf = MailMessage(accountID: "synthetic", from: .init(email: "source@example.invalid"), subject: "CRLF", text: examples[0])
        XCTAssertEqual(MailMessageSummary(message: crlf).displayMessage.text.count, 300)
        XCTAssertEqual(String(crlf.text.prefix(300)).replacingOccurrences(of: "\n", with: " ").count, 600, "Reproduce the old permanent invalid-cache condition")
    }
    func testLegacyCRLFCacheIsRewrittenExactlyOnceThenRemainsValid() async throws {
        let root = location(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try MailStore(root: root)
        var original = MailMessage(accountID: "synthetic", from: .init(email: "source@example.invalid"), subject: "Legacy CRLF", text: String(repeating: "e\u{301}👨‍👩‍👧‍👦\r\n", count: 500))
        original.id = "legacy-crlf"; original.html = "<p>Complete original HTML</p>"
        let saved = try await store.upsert(original)
        let before = try sql(root, "SELECT hex(json) FROM messages")
        let oldPreview = String(original.text.prefix(300)).replacingOccurrences(of: "\n", with: " ")
        XCTAssertGreaterThan(oldPreview.count, 300); try replacePreview(root, id: saved.id, text: oldPreview)
        try executeFixtureSQL(root, "CREATE TABLE repair_attempts(count INTEGER NOT NULL); INSERT INTO repair_attempts VALUES(0); CREATE TRIGGER count_projection_repairs AFTER UPDATE ON message_projections BEGIN UPDATE repair_attempts SET count=count+1; END;")
        let repaired = try await store.messageSummaries()
        XCTAssertEqual(repaired.count, 1); XCTAssertLessThanOrEqual(repaired[0].displayMessage.text.count, 300)
        XCTAssertEqual(try sql(root, "SELECT count FROM repair_attempts"), ["1"])
        let warm = try await store.messageSummaries(); XCTAssertEqual(warm, repaired)
        XCTAssertEqual(try sql(root, "SELECT count FROM repair_attempts"), ["1"])
        XCTAssertEqual(try sql(root, "SELECT hex(json) FROM messages"), before)
        let full = try await store.message(saved.id); XCTAssertEqual(full?.text, saved.text); XCTAssertEqual(full?.html, saved.html)
    }
    func testUnrepairableCacheStopsAfterOneRewriteAndTwoScans() async throws {
        let root = location(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try MailStore(root: root)
        for index in 0..<64 {
            var value = MailMessage(accountID: "synthetic", from: .init(email: "source@example.invalid"), subject: "Valid projection", text: String(repeating: "Retained valid prefix ", count: 100))
            value.id = "valid-\(index)"; try await store.upsert(value)
        }
        var bad = MailMessage(accountID: "synthetic", from: .init(email: "source@example.invalid"), subject: "Persistent cache fault", text: "Complete body retained")
        bad.id = "persistently-invalid"; try await store.upsert(bad)
        let originalsBefore = try sql(root, "SELECT id||':'||hex(json) FROM messages ORDER BY id")
        try executeFixtureSQL(root, "UPDATE message_projections SET json='{}' WHERE message='persistently-invalid'; CREATE TABLE repair_attempts(count INTEGER NOT NULL); INSERT INTO repair_attempts VALUES(0); CREATE TRIGGER keep_projection_invalid AFTER UPDATE ON message_projections WHEN NEW.message='persistently-invalid' AND json_extract(CAST(NEW.json AS TEXT),'$.projectedMessage.id') IS NOT NULL BEGIN UPDATE repair_attempts SET count=count+1; UPDATE message_projections SET json='{}' WHERE message=NEW.message; END;")
        do { _ = try await store.messageSummaries(); XCTFail("Persistent corrupt cache accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("已停止重试")) }
        XCTAssertEqual(try sql(root, "SELECT count FROM repair_attempts"), ["1"], "Repair is bounded independently of a permanently invalid cache")
        XCTAssertEqual(try sql(root, "SELECT id||':'||hex(json) FROM messages ORDER BY id"), originalsBefore)
    }

}
