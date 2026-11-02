import Foundation
import CMail

private let mailKeywordGate = NetworkOperationGate(capacity: 2, maximumWaiters: 8)

/// A query owns a read-only WAL snapshot. Full-text ranking must not occupy the
/// store actor used by delivery acknowledgements and visible flag mutations.
enum MailKeywordSearch {
    private struct Candidate {
        let id: String
        let canonical: String
        let folder: String
        let date: Double
        let score: Float
    }

    static func search(root: URL, query: String, limit: Int, allowedIDs: Set<String>?) async throws -> [SearchHit] {
        guard limit > 0, allowedIDs?.isEmpty != true else { return [] }
        let parsed = MailQuery(query)
        guard !parsed.text.isEmpty || parsed.hasFilters else { return [] }
        let worker = Task.detached(priority: .userInitiated) {
            try await mailKeywordGate.withPermit {
                try scan(database: root.appendingPathComponent("mail.sqlite"), parsed: parsed, limit: limit, allowedIDs: allowedIDs)
            }
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    private static func scan(database: URL, parsed: MailQuery, limit: Int, allowedIDs: Set<String>?) throws -> [SearchHit] {
        try Task.checkCancellation()
        var handle: OpaquePointer?
        guard sqlite3_open_v2(database.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db = handle else {
            if let handle { sqlite3_close(handle) }
            throw MailError.message("无法读取本地邮件检索目录。")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)
        sqlite3_progress_handler(db, 1000, { _ in Task.isCancelled ? 1 : 0 }, nil)
        func failure() -> Error {
            Task.isCancelled ? CancellationError() : MailError.message("本地邮件检索失败：" + String(cString: sqlite3_errmsg(db)))
        }
        guard sqlite3_exec(db, "BEGIN", nil, nil, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        func statement(_ sql: String, _ parameters: [String]) throws -> OpaquePointer {
            var value: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &value, nil) == SQLITE_OK, let value else { throw failure() }
            for (offset, parameter) in parameters.enumerated() { sqlite3_bind_text(value, Int32(offset + 1), parameter, -1, transient) }
            return value
        }
        func string(_ cursor: OpaquePointer, _ column: Int32) -> String { sqlite3_column_text(cursor, column).map { String(cString: $0) } ?? "" }
        func data(_ cursor: OpaquePointer, _ column: Int32) -> Data? {
            guard let pointer = sqlite3_column_blob(cursor, column) else { return nil }
            return Data(bytes: pointer, count: Int(sqlite3_column_bytes(cursor, column)))
        }
        let decoder = JSONDecoder()
        func fullMessage(_ id: String) throws -> MailMessage? {
            let cursor = try statement("SELECT m.json,p.content_revision FROM messages m LEFT JOIN message_projections p ON p.message=m.id WHERE m.id=?", [id]); defer { sqlite3_finalize(cursor) }
            let code = sqlite3_step(cursor)
            if code == SQLITE_DONE { return nil }
            guard code == SQLITE_ROW, let value = data(cursor, 0) else { throw failure() }
            var mail = try decoder.decode(MailMessage.self, from: value)
            if sqlite3_column_type(cursor, 1) != SQLITE_NULL { mail.contentRevision = string(cursor, 1) }
            return mail
        }
        func groups(_ ids: Set<String>?) -> [[String]?] {
            guard let ids else { return [nil] }
            let ordered = ids.sorted()
            return stride(from: 0, to: ordered.count, by: 400).map { Array(ordered[$0..<min($0 + 400, ordered.count)]) }
        }
        func scopeClause(_ group: [String]?) -> String {
            group.map { " AND m.id IN (" + Array(repeating: "?", count: $0.count).joined(separator: ",") + ")" } ?? ""
        }
        var scope = allowedIDs
        if parsed.hasFilters {
            var matching = Set<String>()
            for group in groups(allowedIDs) {
                try Task.checkCancellation()
                let cursor = try statement("SELECT m.id,p.json FROM messages m LEFT JOIN message_projections p ON p.message=m.id WHERE 1" + scopeClause(group), group ?? [])
                defer { sqlite3_finalize(cursor) }
                while true {
                    try Task.checkCancellation()
                    let code = sqlite3_step(cursor); if code == SQLITE_DONE { break }
                    guard code == SQLITE_ROW else { throw failure() }
                    let id = string(cursor, 0)
                    let projected = data(cursor, 1).flatMap { try? decoder.decode(MailMessageSummary.self, from: $0) }
                    let mail: MailMessage?
                    if let projected, projected.id == id, projected.displayMessage.contentAvailability == .preview,
                       projected.displayMessage.text.count <= 300, projected.displayMessage.html.isEmpty, projected.displayMessage.raw.isEmpty,
                       projected.displayMessage.analysis?.evidenceText == nil, projected.displayMessage.attachments.allSatisfy({ $0.data.isEmpty }) { mail = projected.displayMessage }
                    else { mail = try fullMessage(id) }
                    if let mail, parsed.matches(mail) { matching.insert(id) }
                }
            }
            scope = matching
            if matching.isEmpty { return [] }
        }
        let tokens = parsed.text.split(whereSeparator: \.isWhitespace).map(String.init)
        let normalizedTokens = tokens.map { $0.lowercased() }
        let terms = tokens.isEmpty ? "1" : tokens.map { _ in "instr(lower(m.search),lower(?))>0" }.joined(separator: " OR ")
        var candidates: [Candidate] = []
        for group in groups(scope) {
            try Task.checkCancellation()
            // Bind the scope before scoring. Small scopes use exact primary-key
            // lookups rather than scanning the complete mailbox body corpus.
            let cap = scope == nil ? " LIMIT " + String(min(limit, Int.max / 4) * 4) : ""
            let cursor = try statement("SELECT m.id,m.search,m.canonical,m.folder,m.date FROM messages m WHERE (" + terms + ")" + scopeClause(group) + " ORDER BY m.date DESC,m.id ASC" + cap, tokens + (group ?? []))
            defer { sqlite3_finalize(cursor) }
            while true {
                try Task.checkCancellation()
                let code = sqlite3_step(cursor); if code == SQLITE_DONE { break }
                guard code == SQLITE_ROW else { throw failure() }
                let id = string(cursor, 0), canonical = string(cursor, 2)
                let body = tokens.isEmpty ? "" : string(cursor, 1).lowercased()
                let score = tokens.isEmpty ? Float(1) : Float(normalizedTokens.filter { body.contains($0) }.count) / Float(tokens.count)
                candidates.append(.init(id: id, canonical: canonical.isEmpty ? id : canonical, folder: string(cursor, 3), date: sqlite3_column_double(cursor, 4), score: score))
            }
        }
        try Task.checkCancellation()
        var order: [String] = [], best: [String: Candidate] = [:]
        for candidate in candidates.sorted(by: { first, second in
            if first.score != second.score { return first.score > second.score }
            return first.date == second.date ? first.id < second.id : first.date > second.date
        }) {
            if best[candidate.canonical] == nil { order.append(candidate.canonical); best[candidate.canonical] = candidate }
            else if candidate.folder == "INBOX" { best[candidate.canonical] = candidate }
        }
        var hits: [SearchHit] = []
        for key in order.prefix(limit) {
            try Task.checkCancellation()
            guard let candidate = best[key], let mail = try fullMessage(candidate.id) else { continue }
            hits.append(.init(message: mail, score: candidate.score, method: parsed.hasFilters ? "条件检索" : "关键词"))
        }
        return hits
    }
}
