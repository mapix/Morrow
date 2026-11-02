import XCTest
import CMail
@testable import MorrowCore

final class MailLiveReadOnlyPerformanceTests: XCTestCase {
    func testCurrentMailboxScopedKeywordLatencyUsesReadOnlyHelper() async throws {
        guard let path = ProcessInfo.processInfo.environment["MORROW_READONLY_PERFORMANCE_ROOT"] else { throw XCTSkip("Explicit private read-only mailbox root required") }
        let root = URL(fileURLWithPath: path), database = root.appendingPathComponent("mail.sqlite")
        var handle: OpaquePointer?
        guard sqlite3_open_v2(database.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db = handle else { throw MailError.message("Cannot open read-only benchmark source") }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT id FROM messages ORDER BY date DESC LIMIT 50", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        var ids = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW { if let text = sqlite3_column_text(statement, 0) { ids.insert(String(cString: text)) } }
        XCTAssertFalse(ids.isEmpty)
        var durations: [Double] = []
        for _ in 0..<8 {
            let started = ProcessInfo.processInfo.systemUptime
            _ = try await MailKeywordSearch.search(root: root, query: "morrow_readonly_unmatched_probe_20261102", limit: 10, allowedIDs: ids)
            durations.append((ProcessInfo.processInfo.systemUptime - started) * 1000)
        }
        let ordered = durations.sorted(), median = ordered[ordered.count / 2], p95 = ordered.last!
        print("READONLY_SCOPED_KEYWORD: ids=\(ids.count); median_ms=\(median); p95_ms=\(p95); attempts=8; sqlite_readonly=true")
        XCTAssertLessThan(p95, 250, "50-ID local query must not spend half a second scanning the mailbox")
    }
}
