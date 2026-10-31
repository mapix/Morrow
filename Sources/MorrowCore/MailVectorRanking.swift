import Foundation
import CMail

struct RankedMailVector: Sendable {
    var id: String
    var score: Float
    var snippet: String
}

/// Exact ranking owns a short-lived, read-only SQLite snapshot. CPU scoring
/// does not occupy MailStore's actor or delay an interactive message lookup.
enum MailVectorRanking {
    private struct Candidate {
        var id: String; var canonical: String; var folder: String
        var date: Double; var score: Float; var chunkID: String
    }
    static func rank(database: URL, query: [Float], model: String, limit: Int, allowedIDs: Set<String>?, minimumScore: Float?) throws -> [RankedMailVector] {
        try Task.checkCancellation()
        var databaseHandle: OpaquePointer?
        guard sqlite3_open_v2(database.path, &databaseHandle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db = databaseHandle else {
            if databaseHandle != nil { sqlite3_close(databaseHandle) }
            throw MailError.message("无法读取本地向量索引。")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)
        // Also interrupt SQL work while the scanner is cancelled, including
        // time before the next scored row. No long-lived connection is kept.
        sqlite3_progress_handler(db, 1000, { _ in Task.isCancelled ? 1 : 0 }, nil)
        func failure() -> Error {
            if Task.isCancelled { return CancellationError() }
            return MailError.message("本地向量检索失败：" + String(cString: sqlite3_errmsg(db)))
        }
        guard sqlite3_exec(db, "BEGIN", nil, nil, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        func statement(_ sql: String, _ parameters: [String]) throws -> OpaquePointer {
            var value: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &value, nil) == SQLITE_OK, let value else { throw failure() }
            for (index, parameter) in parameters.enumerated() { sqlite3_bind_text(value, Int32(index + 1), parameter, -1, transient) }
            return value
        }
        func string(_ statement: OpaquePointer, _ column: Int32) -> String { sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "" }
        var groups: [[String]?] = [nil]
        if let allowedIDs {
            let ordered = allowedIDs.sorted(); groups = []
            for start in stride(from: 0, to: ordered.count, by: 400) { groups.append(Array(ordered[start..<min(start + 400, ordered.count)])) }
        }
        var best: [String: Candidate] = [:], scanned = 0
        for group in groups {
            try Task.checkCancellation()
            let clause = group.map { " AND v.message IN (" + Array(repeating: "?", count: $0.count).joined(separator: ",") + ")" } ?? ""
            let cursor = try statement("SELECT v.message,m.canonical,m.folder,m.date,v.vector,v.id FROM vectors v JOIN messages m ON m.id=v.message WHERE v.model=?" + clause, [model] + (group ?? []))
            defer { sqlite3_finalize(cursor) }
            while true {
                let code = sqlite3_step(cursor); if code == SQLITE_DONE { break }
                guard code == SQLITE_ROW else { throw failure() }
                if scanned.isMultiple(of: 128) { try Task.checkCancellation() }; scanned += 1
                let count = Int(sqlite3_column_bytes(cursor, 4))
                guard count == query.count * MemoryLayout<Float>.size, let pointer = sqlite3_column_blob(cursor, 4) else { continue }
                let raw = UnsafeRawBufferPointer(start: pointer, count: count)
                var score: Float = 0
                for index in query.indices { score += query[index] * raw.loadUnaligned(fromByteOffset: index * MemoryLayout<Float>.size, as: Float.self) }
                guard score.isFinite, minimumScore.map({ score >= $0 }) ?? true else { continue }
                let id = string(cursor, 0)
                if score > (best[id]?.score ?? -.infinity) {
                    let canonical = string(cursor, 1)
                    best[id] = Candidate(id: id, canonical: canonical.isEmpty ? id : canonical, folder: string(cursor, 2), date: sqlite3_column_double(cursor, 3), score: score, chunkID: string(cursor, 5))
                }
            }
        }
        try Task.checkCancellation()
        var canonicalHits: [String: Candidate] = [:]
        for candidate in best.values {
            if let prior = canonicalHits[candidate.canonical] {
                if candidate.score > prior.score || (candidate.score == prior.score && candidate.folder.uppercased() == "INBOX" && prior.folder.uppercased() != "INBOX") || (candidate.score == prior.score && candidate.folder.uppercased() == prior.folder.uppercased() && candidate.id < prior.id) { canonicalHits[candidate.canonical] = candidate }
            } else { canonicalHits[candidate.canonical] = candidate }
        }
        let ranked = canonicalHits.values.sorted { first, second in
            if first.score != second.score { return first.score > second.score }
            return first.date == second.date ? first.id < second.id : first.date > second.date
        }.prefix(limit)
        var result: [RankedMailVector] = []
        for candidate in ranked {
            try Task.checkCancellation()
            let cursor = try statement("SELECT chunk FROM vectors WHERE id=?", [candidate.chunkID]); defer { sqlite3_finalize(cursor) }
            let code = sqlite3_step(cursor)
            guard code == SQLITE_ROW || code == SQLITE_DONE else { throw failure() }
            result.append(.init(id: candidate.id, score: candidate.score, snippet: code == SQLITE_ROW ? string(cursor, 0) : ""))
        }
        // All cursors above have finalized; releasing this snapshot before
        // MailStore hydration lets normal WAL checkpoints proceed immediately.
        guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw failure() }
        return result
    }
}
