import XCTest
import CMail
@testable import MorrowCore

final class BulkMetadataMutationTests: XCTestCase {
    private func location() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("bulk-metadata-" + UUID().uuidString) }
    private func sql(_ root: URL, _ query: String) throws -> [String] {
        var db: OpaquePointer?, statement: OpaquePointer?
        guard sqlite3_open(root.appendingPathComponent("mail.sqlite").path, &db) == SQLITE_OK else { throw MailError.message("fixture open failed") }
        defer { sqlite3_finalize(statement); sqlite3_close(db) }
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { throw MailError.message("fixture statement failed") }
        var result: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW { result.append(sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "") }
        return result
    }
    private func indexes(_ root: URL) throws -> [[String]] {
        try [sql(root, "SELECT id||':'||hex(search) FROM messages ORDER BY id"), sql(root, "SELECT id||':'||hex(vector)||':'||hash FROM vectors ORDER BY id"), sql(root, "SELECT message||':'||hash FROM index_state ORDER BY message")]
    }
    func testBulkStarsUseMetadataAndUndoOnlyChangedCanonicalRows() async throws {
        let root = location(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try MailStore(root: root), oldDate = Date(timeIntervalSinceReferenceDate: 100), modified = Date(timeIntervalSinceReferenceDate: 200)
        var ids = Set<String>(), expected = Set<String>(), reference: MailMessage?
        for i in 0..<430 {
            var mail = MailMessage(accountID: "a", from: .init(email: "source@example.invalid"), subject: "Synthetic star fixture", text: "Original Unicode body\n邮件正文")
            mail.id = String(format: "star-%03d", i); mail.messageID = "<\(i)@example.invalid>"; mail.html = "<p>Original <b>HTML</b></p>"; mail.labels = ["existing"]
            mail.isStarred = i.isMultiple(of: 3); mail.isRead = true; mail.localFlagModifiedAt = oldDate
            let saved = try await store.upsert(mail); ids.insert(mail.id)
            if !mail.isStarred { expected.insert(mail.id) }
            if i == 1 { reference = saved }
        }
        var copy = reference!; copy.id = "canonical-copy"; copy.folder = "Archive"; try await store.upsert(copy); expected.insert(copy.id)
        var other = copy; other.id = "other-account"; other.accountID = "b"; try await store.upsert(other)
        try await store.putVectors(messageID: reference!.id, chunks: ["fixture"], vectors: [[1, 0]], model: "fixture", hash: "unchanged")
        let before = try indexes(root)
        let changes = try await store.setStarState(ids: ids, starred: true, modifiedAt: modified, includeCanonicalCopies: true)
        XCTAssertEqual(Set(changes.map(\.id)), expected); XCTAssertTrue(changes.allSatisfy { !$0.wasEnabled })
        XCTAssertEqual(try indexes(root), before)
        let alreadyStarred = try await store.message("star-000"); XCTAssertEqual(alreadyStarred?.localFlagModifiedAt, oldDate)
        let unrelated = try await store.message(other.id); XCTAssertEqual(unrelated?.isStarred, false)
        let altered = try await store.message(reference!.id)
        XCTAssertEqual(altered?.text, reference?.text); XCTAssertEqual(altered?.html, reference?.html); XCTAssertEqual(altered?.bodyVersion, reference?.bodyVersion)
        let projected = try await store.messageSummaries().first { $0.id == reference!.id }
        XCTAssertEqual(projected?.displayMessage.isStarred, true); XCTAssertEqual(projected?.contentRevision, reference?.contentRevision)
        let restored = try await store.restoreStarState(changes: changes, modifiedAt: Date(timeIntervalSinceReferenceDate: 300))
        XCTAssertEqual(restored, expected); XCTAssertEqual(try indexes(root), before)
        let restoredProjection = try await store.messageSummaries().first { $0.id == reference!.id }
        XCTAssertEqual(restoredProjection?.displayMessage.isStarred, false)
    }
    func testBulkLabelsKeepFTSExactlyAlignedAndOnlyAppendNewTags() async throws {
        let root = location(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try MailStore(root: root), target = "Review \"2026\" 邮件", untouchedDate = Date(timeIntervalSinceReferenceDate: 100)
        var ids = Set<String>(), expected = Set<String>(), reference: MailMessage?
        for i in 0..<430 {
            var mail = MailMessage(accountID: "a", from: .init(email: "source@example.invalid"), subject: "Synthetic label fixture", text: "Original complete text and body evidence.")
            mail.id = String(format: "label-%03d", i); mail.messageID = "<\(i)@example.invalid>"; mail.html = "<p>Original complete HTML</p>"; mail.labels = i.isMultiple(of: 3) ? ["existing", target] : ["existing"]
            mail.note = "Keep note"; mail.localFlagModifiedAt = untouchedDate
            let saved = try await store.upsert(mail); ids.insert(mail.id)
            if !mail.labels.contains(target) { expected.insert(mail.id) }; if i == 1 { reference = saved }
        }
        var copy = reference!; copy.id = "canonical-label-copy"; copy.folder = "Archive"; try await store.upsert(copy); expected.insert(copy.id)
        var other = copy; other.id = "unrelated-label-account"; other.accountID = "b"; try await store.upsert(other)
        try await store.putVectors(messageID: reference!.id, chunks: ["fixture"], vectors: [[1, 0]], model: "fixture", hash: "unchanged")
        let vectorBefore = try sql(root, "SELECT hex(vector)||':'||hash FROM vectors")
        let alreadySearch = try sql(root, "SELECT hex(search) FROM messages WHERE id='label-000'")
        let changes = try await store.addLabel(ids: ids, label: target)
        XCTAssertEqual(Set(changes.map(\.id)), expected); XCTAssertTrue(changes.allSatisfy { $0.labels == ["existing"] })
        let keywordHits = try await store.keywordSearch(target, allowedIDs: ids)
        XCTAssertFalse(keywordHits.isEmpty)
        XCTAssertEqual(try sql(root, "SELECT hex(search) FROM messages WHERE id='label-000'"), alreadySearch)
        XCTAssertEqual(try sql(root, "SELECT hex(vector)||':'||hash FROM vectors"), vectorBefore)
        let full = try await store.message(reference!.id)
        XCTAssertEqual(full?.labels, ["existing", target]); XCTAssertEqual(full?.text, reference?.text); XCTAssertEqual(full?.html, reference?.html)
        XCTAssertEqual(full?.note, reference?.note); XCTAssertEqual(full?.localFlagModifiedAt, untouchedDate); XCTAssertEqual(full?.bodyVersion, reference?.bodyVersion)
        let unrelated = try await store.message(other.id); XCTAssertEqual(unrelated?.labels, ["existing"])
        let projection = try await store.messageSummaries().first { $0.id == reference!.id }; XCTAssertEqual(projection?.displayMessage.labels, ["existing", target])
        let beforeNoop = try indexes(root), empty = try await store.addLabel(ids: ids, label: target)
        XCTAssertTrue(empty.isEmpty); XCTAssertEqual(try indexes(root), beforeNoop)
        let searched = try await store.keywordSearch("label:Review", limit: 500)
        XCTAssertEqual(searched.count, 430)
    }
    func testMalformedFlagOrLabelMetadataRollsBackWholeMutation() async throws {
        let root = location(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try MailStore(root: root)
        var good = MailMessage(accountID: "a", from: .init(email: "source@example.invalid"), subject: "Synthetic rollback", text: "Original body")
        good.id = "good"; var damaged = good; damaged.id = "damaged"
        try await store.upsert(good); try await store.upsert(damaged)
        var db: OpaquePointer?; XCTAssertEqual(sqlite3_open(root.appendingPathComponent("mail.sqlite").path, &db), SQLITE_OK); defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "UPDATE messages SET json=json_set(CAST(json AS TEXT),'$.isStarred','invalid') WHERE id='damaged'", nil, nil, nil), SQLITE_OK)
        do { _ = try await store.setStarState(ids: [good.id, damaged.id], starred: true); XCTFail("Invalid flag accepted") } catch { }
        let unchanged = try await store.message(good.id); XCTAssertEqual(unchanged?.isStarred, false)
        XCTAssertEqual(sqlite3_exec(db, "UPDATE messages SET json=json_set(CAST(json AS TEXT),'$.isStarred',json('false'),'$.labels',json('[1]')) WHERE id='damaged'", nil, nil, nil), SQLITE_OK)
        let before = try indexes(root)
        do { _ = try await store.addLabel(ids: [good.id, damaged.id], label: "new"); XCTFail("Invalid label accepted") } catch { }
        XCTAssertEqual(try indexes(root), before)
        let goodProjection = try await store.messageSummaries().first { $0.id == good.id }; XCTAssertEqual(goodProjection?.displayMessage.labels, [])
    }
}
