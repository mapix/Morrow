import Foundation
import CMail

private let mailReaderGate = NetworkOperationGate(capacity: 1, maximumWaiters: 8)

extension MailStore {
    /// A selected body's read must not queue behind a bulk metadata/index pass.
    /// Its private read-only WAL connection is closed before returning the body.
    public nonisolated func readerMessage(_ id: String) async throws -> MailMessage? {
        let location = root.appendingPathComponent("mail.sqlite")
        let worker = Task.detached(priority: .userInitiated) { () async throws -> MailMessage? in
            try await mailReaderGate.withPermit { () async throws -> MailMessage? in
            try Task.checkCancellation()
            var db: OpaquePointer?
            guard sqlite3_open_v2(location.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else { if let db { sqlite3_close(db) }; throw MailError.message("读取邮件正文失败。") }
            defer { sqlite3_close(db) }
            sqlite3_busy_timeout(db, 1500)
            sqlite3_progress_handler(db, 1000, { _ in Task.isCancelled ? 1 : 0 }, nil)
            var statement: OpaquePointer?
            let sql = "SELECT m.json,p.content_revision FROM messages m LEFT JOIN message_projections p ON p.message=m.id WHERE m.id=?"
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw MailError.message("正文读取查询失败。") }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, id, -1, transient)
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return nil }
            guard step == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { throw MailError.message("正文读取暂时忙，请重试。") }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
            var message = try JSONDecoder().decode(MailMessage.self, from: data)
            if let revision = sqlite3_column_text(statement, 1) { message.contentRevision = String(cString: revision) }
            try Task.checkCancellation()
            return message
            }
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
}
