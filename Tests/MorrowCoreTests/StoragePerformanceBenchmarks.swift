import XCTest
import CMail
import Darwin
@testable import MorrowCore

final class StoragePerformanceBenchmarks: XCTestCase {
    private func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        return status == KERN_SUCCESS ? info.phys_footprint : 0
    }
    private func bytes(_ root: URL) -> Int {
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])
        return files?.compactMap { ($0 as? URL).flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } }.reduce(0, +) ?? 0
    }
    private func denseVector(_ row: Int) -> [Float] {
        var vector = (0..<768).map { Float(($0 * 31 + row * 17) % 257 - 128) }
        let norm = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
        for index in vector.indices { vector[index] /= norm }; return vector
    }
    private func peakRSS() -> Int64 {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage); return Int64(usage.ru_maxrss)
    }
    private func seed(_ root: URL, count: Int, dimensions: Int = 16, richBodies: Bool = true) throws -> Int {
        var db: OpaquePointer?, mailStatement: OpaquePointer?, vectorStatement: OpaquePointer?
        guard sqlite3_open(root.appendingPathComponent("mail.sqlite").path, &db) == SQLITE_OK else { throw MailError.message("benchmark fixture open failed") }
        defer { sqlite3_finalize(mailStatement); sqlite3_finalize(vectorStatement); sqlite3_close(db) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        // Synthetic fixture only: a WAL checkpoint can temporarily retain both
        // the 96MB database and its WAL. The read-only 768D benchmark needs no
        // recovery journal and must stay below the user's total disk budget.
        if dimensions == 768 {
            guard sqlite3_exec(db, "PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF", nil, nil, nil) == SQLITE_OK else { throw MailError.message("benchmark journal setup failed") }
        }
        var maximumFixtureBytes = bytes(root)
        guard sqlite3_prepare_v2(db, "INSERT INTO messages(id,account,folder,uid,validity,date,search,json,canonical) VALUES(?,'synthetic','INBOX',?,1,?,?,?,?)", -1, &mailStatement, nil) == SQLITE_OK,
              sqlite3_prepare_v2(db, "INSERT INTO vectors(id,message,chunk,vector,model,hash) VALUES(?,?,?,?,'synthetic-\(dimensions)d','fixture')", -1, &vectorStatement, nil) == SQLITE_OK,
              sqlite3_exec(db, "PRAGMA max_page_count=24576; BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw MailError.message("benchmark fixture prepare failed") }
        func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: String) { sqlite3_bind_text(statement, index, value, -1, transient) }
        let encoder = JSONEncoder()
        for i in 0..<count {
            let id = String(format: "synthetic-%05d", i)
            var mail = MailMessage(accountID: "synthetic", from: .init(email: "contact-\(i % 20)@example.invalid"), subject: richBodies ? "Synthetic delivery \(i)" : "Fixture", text: richBodies ? "Synthetic acceptance criteria and milestone review. Confirm delivery by the agreed date." : "")
            mail.id = id; mail.uid = UInt64(i + 1); mail.uidValidity = 1; mail.date = Date(timeIntervalSince1970: Double(i)); mail.html = richBodies ? String(repeating: "<p>Synthetic delivery milestone and review criteria.</p>", count: 12) : ""
            let data = try encoder.encode(mail)
            bind(mailStatement, 1, id); sqlite3_bind_int64(mailStatement, 2, Int64(i + 1)); sqlite3_bind_double(mailStatement, 3, Double(i))
            bind(mailStatement, 4, mail.subject + " " + mail.text)
            data.withUnsafeBytes { _ = sqlite3_bind_blob(mailStatement, 5, $0.baseAddress, Int32(data.count), transient) }
            bind(mailStatement, 6, id)
            guard sqlite3_step(mailStatement) == SQLITE_DONE else { throw MailError.message("benchmark fixture insert failed") }
            sqlite3_reset(mailStatement); sqlite3_clear_bindings(mailStatement)
            var vector = dimensions == 768 ? denseVector(i) : Array(repeating: Float(0), count: 16)
            if dimensions == 16 { vector[0] = Float(i % 100) / 100; vector[1] = sqrt(1 - vector[0] * vector[0]) }
            bind(vectorStatement, 1, id + ":0"); bind(vectorStatement, 2, id); bind(vectorStatement, 3, mail.text)
            vector.withUnsafeBytes { _ = sqlite3_bind_blob(vectorStatement, 4, $0.baseAddress, Int32($0.count), transient) }
            guard sqlite3_step(vectorStatement) == SQLITE_DONE else { throw MailError.message("benchmark vector insert failed") }
            sqlite3_reset(vectorStatement); sqlite3_clear_bindings(vectorStatement)
            if i.isMultiple(of: 256) {
                maximumFixtureBytes = max(maximumFixtureBytes, bytes(root))
                guard maximumFixtureBytes < 100 * 1024 * 1024 else { throw MailError.message("benchmark exceeded fixture disk budget") }
            }
        }
        guard sqlite3_exec(db, "COMMIT; PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil) == SQLITE_OK else { throw MailError.message("benchmark fixture commit failed") }
        return max(maximumFixtureBytes, bytes(root))
    }
    func testTwentyThousandSyntheticMessagesColdWarmAndScopedSearch() async throws {
        guard ProcessInfo.processInfo.environment["MORROW_STORAGE_BENCHMARK"] == "1" else { throw XCTSkip("Set MORROW_STORAGE_BENCHMARK=1 for the bounded synthetic 20k benchmark") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("morrow-storage-benchmark-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MailStore(root: root); _ = try seed(root, count: 20000)
        XCTAssertLessThan(bytes(root), 100 * 1024 * 1024)
        let initialFootprint = footprint()
        let fullStart = Date(); let fullCount = try await store.messages().count; let fullSeconds = Date().timeIntervalSince(fullStart)
        XCTAssertEqual(fullCount, 20000)
        let coldStart = Date(); let coldCount = try await store.messageSummaries().count; let coldSeconds = Date().timeIntervalSince(coldStart)
        XCTAssertEqual(coldCount, 20000)
        let warmStart = Date(); let warmCount = try await store.messageSummaries().count; let warmSeconds = Date().timeIntervalSince(warmStart)
        XCTAssertEqual(warmCount, 20000)
        let inventoryStart = Date(); let fingerprint = try await store.profileInventoryFingerprint(); let inventorySeconds = Date().timeIntervalSince(inventoryStart)
        XCTAssertFalse(fingerprint.isEmpty)
        let pageStart = Date(); let page = try await store.messageSummaries(limit: 40, offset: 100); let pageSeconds = Date().timeIntervalSince(pageStart)
        XCTAssertEqual(page.count, 40)
        var query = Array(repeating: Float(0), count: 16); query[0] = 1
        let vectorStart = Date(); let vectorHits = try await store.vectorSearch(query, model: "synthetic-16d", limit: 20); let vectorSeconds = Date().timeIntervalSince(vectorStart)
        XCTAssertEqual(vectorHits.count, 20); XCTAssertEqual(vectorHits.first?.score ?? 0, 0.99, accuracy: 0.001)
        let scope = Set((0..<50).map { String(format: "synthetic-%05d", $0) })
        let scopedStart = Date(); let scopedHits = try await store.vectorSearch(query, model: "synthetic-16d", limit: 10, allowedIDs: scope); let scopedSeconds = Date().timeIntervalSince(scopedStart)
        XCTAssertTrue(scopedHits.allSatisfy { scope.contains($0.id) })
        let keywordStart = Date(); let keyword = try await store.keywordSearch("from:contact-1@ acceptance", limit: 20); let keywordSeconds = Date().timeIntervalSince(keywordStart)
        XCTAssertEqual(keyword.count, 20)
        let finalBytes = bytes(root); XCTAssertLessThan(finalBytes, 100 * 1024 * 1024)
        print("STORAGE_BENCHMARK rows=20000 vectorDimension=16 fixtureBytes=\(finalBytes) initialFootprint=\(initialFootprint) finalFootprint=\(footprint()) fullSeconds=\(fullSeconds) coldBackfillAndReadSeconds=\(coldSeconds) warmSummarySeconds=\(warmSeconds) inventorySeconds=\(inventorySeconds) page40Seconds=\(pageSeconds) exactVectorSeconds=\(vectorSeconds) scopedVectorSeconds=\(scopedSeconds) filteredKeywordSeconds=\(keywordSeconds) cleanup=defer")
    }
    func testTwentyThousandDense768VectorsExactAndSparseScope() async throws {
        guard ProcessInfo.processInfo.environment["MORROW_STORAGE_768_BENCHMARK"] == "1" else { throw XCTSkip("Set MORROW_STORAGE_768_BENCHMARK=1 for the bounded 768-dimensional synthetic benchmark") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("morrow-vector768-benchmark-" + UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: root)
            let remaining = FileManager.default.fileExists(atPath: root.path)
            XCTAssertFalse(remaining)
            print("VECTOR768_FIXTURE_CLEANUP remaining=\(remaining)")
        }
        let store = try MailStore(root: root)
        let peakFixtureBytes = try seed(root, count: 20000, dimensions: 768, richBodies: false)
        XCTAssertLessThan(peakFixtureBytes, 100 * 1024 * 1024)
        let fixtureBytes = bytes(root); XCTAssertLessThan(fixtureBytes, 100 * 1024 * 1024)
        let initialFootprint = footprint(), initialPeakRSS = peakRSS()
        let query = denseVector(0)
        XCTAssertEqual(query.count, 768); XCTAssertTrue(query.allSatisfy(\.isFinite))
        XCTAssertEqual(query.reduce(Float(0)) { $0 + $1 * $1 }, 1, accuracy: 0.0001)
        let exactStart = Date()
        let exactTask = Task { try await store.vectorSearch(query, model: "synthetic-768d", limit: 20) }
        try await Task.sleep(for: .milliseconds(30))
        let lookupStart = Date(); let interactive = try await store.message("synthetic-00000")
        let concurrentLookupSeconds = Date().timeIntervalSince(lookupStart)
        XCTAssertNotNil(interactive); XCTAssertLessThan(concurrentLookupSeconds, 0.25, "Vector CPU ranking must not occupy MailStore's actor")
        let exact = try await exactTask.value
        let exactSeconds = Date().timeIntervalSince(exactStart), afterExactFootprint = footprint(), afterExactPeakRSS = peakRSS()
        XCTAssertEqual(exact.count, 20); XCTAssertEqual(exact.first?.score ?? 0, 1, accuracy: 0.0001)
        let scope = Set((0..<50).map { String(format: "synthetic-%05d", $0) })
        let scopedStart = Date()
        let scoped = try await store.vectorSearch(query, model: "synthetic-768d", limit: 10, allowedIDs: scope)
        let scopedSeconds = Date().timeIntervalSince(scopedStart)
        XCTAssertEqual(scoped.count, 10); XCTAssertTrue(scoped.allSatisfy { scope.contains($0.id) })
        XCTAssertEqual(scoped.first?.id, "synthetic-00000")
        XCTAssertEqual(scoped.first?.score ?? 0, 1, accuracy: 0.0001)
        let cancelledScan = Task { try await store.vectorSearch(query, model: "synthetic-768d", limit: 20) }
        try await Task.sleep(for: .milliseconds(20)); let cancelStart = Date(); cancelledScan.cancel()
        do { _ = try await cancelledScan.value; XCTFail("Cancelled exact scan completed") } catch is CancellationError { }
        let cancellationSeconds = Date().timeIntervalSince(cancelStart)
        XCTAssertLessThan(cancellationSeconds, 1)
        let afterCancellation = try await store.message("synthetic-00000"); XCTAssertNotNil(afterCancellation)
        print("VECTOR768_STORAGE_BENCHMARK rows=20000 dimensions=768 finiteNormalized=true fixtureBytes=\(fixtureBytes) peakFixtureBytes=\(peakFixtureBytes) initialFootprint=\(initialFootprint) afterExactFootprint=\(afterExactFootprint) afterScopedFootprint=\(footprint()) initialPeakRSS=\(initialPeakRSS) afterExactPeakRSS=\(afterExactPeakRSS) afterScopedPeakRSS=\(peakRSS()) exactSeconds=\(exactSeconds) scoped50IDsSeconds=\(scopedSeconds) concurrentMessageLookupSeconds=\(concurrentLookupSeconds) cancellationSeconds=\(cancellationSeconds) cleanup=defer")
    }

    func testTwentyThousandMetadataMutationsStayLinearAndIdempotent() async throws {
        guard ProcessInfo.processInfo.environment["MORROW_STORAGE_METADATA_BENCHMARK"] == "1" else { throw XCTSkip("Set MORROW_STORAGE_METADATA_BENCHMARK=1 for the bounded 20k metadata mutation benchmark") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("morrow-metadata20k-benchmark-" + UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: root)
            let remaining = FileManager.default.fileExists(atPath: root.path); XCTAssertFalse(remaining)
            print("METADATA20K_FIXTURE_CLEANUP remaining=\(remaining)")
        }
        let store = try MailStore(root: root); _ = try seed(root, count: 20000, richBodies: false)
        let before = try await store.messageSummaries().count; XCTAssertEqual(before, 20000)
        let ids = Set((0..<20000).map { String(format: "synthetic-%05d", $0) })
        let initialFootprint = footprint()
        let starStart = Date(); let stars = try await store.setStarState(ids: ids, starred: true)
        let starSeconds = Date().timeIntervalSince(starStart); XCTAssertEqual(stars.count, 20000)
        XCTAssertTrue(stars.allSatisfy { !$0.wasEnabled }); XCTAssertLessThan(bytes(root), 100 * 1024 * 1024)
        let labelStart = Date(); let labels = try await store.addLabel(ids: ids, label: "synthetic-batch-label")
        let labelSeconds = Date().timeIntervalSince(labelStart); XCTAssertEqual(labels.count, 20000)
        XCTAssertTrue(labels.allSatisfy { $0.labels.isEmpty }); XCTAssertLessThan(bytes(root), 100 * 1024 * 1024)
        let duplicateStart = Date(); let duplicateLabels = try await store.addLabel(ids: ids, label: "synthetic-batch-label")
        let duplicateSeconds = Date().timeIntervalSince(duplicateStart); XCTAssertTrue(duplicateLabels.isEmpty)
        let duplicateStars = try await store.setStarState(ids: ids, starred: true); XCTAssertTrue(duplicateStars.isEmpty)
        let summaries = try await store.messageSummaries()
        XCTAssertEqual(summaries.count, 20000); XCTAssertTrue(summaries.allSatisfy { $0.displayMessage.isStarred && $0.displayMessage.labels == ["synthetic-batch-label"] })
        let fixtureBytes = bytes(root); XCTAssertLessThan(fixtureBytes, 100 * 1024 * 1024)
        print("METADATA20K_BENCHMARK rows=20000 starChangedCount=\(stars.count) labelChangedCount=\(labels.count) repeatedChangedCount=\(duplicateLabels.count + duplicateStars.count) fixtureBytes=\(fixtureBytes) initialFootprint=\(initialFootprint) finalFootprint=\(footprint()) starSeconds=\(starSeconds) labelSeconds=\(labelSeconds) repeatedLabelSeconds=\(duplicateSeconds) cleanup=defer")
    }

}
