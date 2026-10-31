import Foundation
import CMail

/// Legacy text conditions are evaluated against full stored text without
/// retaining mailbox bodies in the view model or blocking its Store actor.
public enum MailInventorySearch {
    public static func matchingIDs(root: URL, text: String) async throws -> Set<String>? {
        let terms = WorkScope.terms(text)
        guard !terms.isEmpty else { return nil }
        let scan = Task.detached(priority: .utility) {
            var database: OpaquePointer?
            guard sqlite3_open_v2(root.appendingPathComponent("mail.sqlite").path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let database else { if let database { sqlite3_close(database) }; throw MailError.message("无法读取邮件筛选目录。") }
            defer { sqlite3_close(database) }
            sqlite3_busy_timeout(database, 1000)
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "SELECT id,canonical,json_extract(CAST(json AS TEXT),'$.subject'),json_extract(CAST(json AS TEXT),'$.text'),json_extract(CAST(json AS TEXT),'$.from.email') FROM messages", -1, &statement, nil) == SQLITE_OK, let statement else { throw MailError.message("无法读取邮件筛选目录。") }
            defer { sqlite3_finalize(statement) }
            func string(_ column: Int32) -> String { sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "" }
            var result = Set<String>()
            while true {
                try Task.checkCancellation()
                let status = sqlite3_step(statement); if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw MailError.message("邮件筛选目录读取未完成。") }
                let content = string(2) + " " + string(3) + " " + string(4)
                if terms.contains(where: { content.localizedCaseInsensitiveContains($0) }) { result.insert(string(0)); result.insert(string(1)) }
            }
            return result
        }
        return try await withTaskCancellationHandler { try await scan.value } onCancel: { scan.cancel() }
    }
}
