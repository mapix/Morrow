import Foundation
import CMail

/// SQL over a scoped metadata snapshot with lazy body reads from the original
/// database. The query connection never attaches the private mail database.
public final class AgentMailData: @unchecked Sendable {
    private var queryDB: OpaquePointer?
    private var sourceDB: OpaquePointer?
    private let lock = NSLock()
    private let ids: Set<String>
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private var deadline = Date.distantFuture
    private var readIDs = Set<String>()
    public var observedIDs: Set<String> { lock.lock(); defer { lock.unlock() }; return readIDs }

    public init(root: URL, mails: [MailMessage], contacts: [ContactTriage], accounts: [MailAccount]) throws {
        ids = Set(mails.map(\.id))
        var initialized = false
        defer { if !initialized { sqlite3_close(queryDB); sqlite3_close(sourceDB); queryDB = nil; sourceDB = nil } }
        guard sqlite3_open_v2(root.appendingPathComponent("mail.sqlite").path, &sourceDB, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              sqlite3_open(":memory:", &queryDB) == SQLITE_OK else { throw MailError.message("无法打开只读邮件数据接口。") }
        sqlite3_busy_timeout(sourceDB, 1000)
        sqlite3_limit(queryDB, SQLITE_LIMIT_LENGTH, 2 * 1024 * 1024)
        sqlite3_limit(queryDB, SQLITE_LIMIT_SQL_LENGTH, 16000)
        sqlite3_limit(queryDB, SQLITE_LIMIT_COLUMN, 64)
        sqlite3_limit(queryDB, SQLITE_LIMIT_EXPR_DEPTH, 50)
        sqlite3_limit(queryDB, SQLITE_LIMIT_COMPOUND_SELECT, 16)
        sqlite3_limit(queryDB, SQLITE_LIMIT_ATTACHED, 0)
        try execute("CREATE TABLE mail_index(id TEXT PRIMARY KEY,canonical_id TEXT,account_id TEXT,folder TEXT,from_email TEXT,from_name TEXT,to_json TEXT,cc_json TEXT,date TEXT,subject TEXT,snippet TEXT,summary TEXT,category TEXT,is_read INTEGER,is_starred INTEGER,labels_json TEXT,in_reply_to TEXT)")
        try execute("CREATE TABLE contacts(email TEXT PRIMARY KEY,name TEXT,mail_count INTEGER,direct_received INTEGER,direct_sent INTEGER,copied INTEGER,last_seen TEXT,source_ids_json TEXT)")
        try execute("CREATE TABLE accounts(id TEXT PRIMARY KEY,email TEXT,name TEXT)")
        let encoder = JSONEncoder()
        func json<T: Encodable>(_ value: T) throws -> String { String(decoding: try encoder.encode(value), as: UTF8.self) }
        try execute("BEGIN")
        let insertMail = try prepare("INSERT INTO mail_index VALUES(" + Array(repeating: "?", count: 17).joined(separator: ",") + ")")
        defer { sqlite3_finalize(insertMail) }
        for mail in mails {
            try Task.checkCancellation()
            let fields = [mail.id, mail.canonicalID, mail.accountID, mail.folder, mail.from.email, mail.from.name, try json(mail.to.map(\.email)), try json(mail.cc.map(\.email)), mail.date.ISO8601Format(), mail.subject, String(mail.text.prefix(300)), mail.analysis?.summary ?? "", mail.analysis?.category.rawValue ?? "", mail.isRead ? "1" : "0", mail.isStarred ? "1" : "0", try json(mail.labels), mail.inReplyTo]
            try insert(insertMail, fields)
        }
        let insertContact = try prepare("INSERT INTO contacts VALUES(?,?,?,?,?,?,?,?)")
        defer { sqlite3_finalize(insertContact) }
        for contact in contacts {
            try insert(insertContact, [contact.profile.email, contact.profile.display, String(contact.mails.count), String(contact.directReceived), String(contact.directSent), String(contact.copied), contact.mails.first?.date.ISO8601Format() ?? "", try json(contact.samples.map(\.id))])
        }
        let insertAccount = try prepare("INSERT INTO accounts VALUES(?,?,?)")
        defer { sqlite3_finalize(insertAccount) }
        for account in accounts { try insert(insertAccount, [account.id, account.email, account.name]) }
        try execute("CREATE INDEX mail_sender ON mail_index(from_email); CREATE INDEX mail_account_date ON mail_index(account_id,date); COMMIT")
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard sqlite3_create_function_v2(queryDB, "mail_text", 1, SQLITE_UTF8, context, { context, count, arguments in
            guard let context, count == 1, let argument = arguments?[0], let bytes = sqlite3_value_text(argument), let owner = sqlite3_user_data(context) else { sqlite3_result_null(context); return }
            let data = Unmanaged<AgentMailData>.fromOpaque(owner).takeUnretainedValue()
            do { try data.body(String(cString: bytes), result: context) }
            catch { sqlite3_result_error(context, "Body read failed", -1) }
        }, nil, nil, nil) == SQLITE_OK else { throw MailError.message("无法配置邮件正文查询。") }
        try execute("CREATE VIEW mail AS SELECT *,mail_text(id) AS text FROM mail_index")
        sqlite3_set_authorizer(queryDB, { _, action, first, second, _, _ in
            switch action {
            case SQLITE_SELECT, SQLITE_RECURSIVE: return SQLITE_OK
            case SQLITE_READ:
                let table = first.map { String(cString: $0) } ?? ""
                return ["mail", "mail_index", "contacts", "accounts", "sqlite_master", "json_each", "json_tree"].contains(table) ? SQLITE_OK : SQLITE_DENY
            case SQLITE_FUNCTION:
                let name = second.map { String(cString: $0).lowercased() } ?? ""
                return ["mail_text", "count", "sum", "avg", "min", "max", "total", "group_concat", "json", "json_extract", "json_each", "json_tree", "json_array", "json_object", "json_array_length", "json_group_array", "json_group_object", "substr", "substring", "length", "instr", "lower", "upper", "trim", "ltrim", "rtrim", "coalesce", "ifnull", "nullif", "round", "abs", "datetime", "date", "time", "strftime", "julianday", "unixepoch", "replace", "like", "glob", "printf", "typeof", "hex"].contains(name) ? SQLITE_OK : SQLITE_DENY
            default: return SQLITE_DENY
            }
        }, nil)
        sqlite3_progress_handler(queryDB, 1000, { context in
            guard let context else { return 1 }
            return Date() >= Unmanaged<AgentMailData>.fromOpaque(context).takeUnretainedValue().deadline ? 1 : 0
        }, context)
        initialized = true
    }
    deinit { sqlite3_close(queryDB); sqlite3_close(sourceDB) }

    private func body(_ id: String, result: OpaquePointer) throws {
        guard ids.contains(id), Date() < deadline else { sqlite3_result_null(result); return }
        readIDs.insert(id)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(sourceDB, "SELECT json_extract(json,'$.text') FROM messages WHERE id=?", -1, &statement, nil) == SQLITE_OK else { throw MailError.message("邮件正文查询失败。") }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, id, -1, transient)
        if sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) { sqlite3_result_text(result, UnsafeRawPointer(text).assumingMemoryBound(to: CChar.self), sqlite3_column_bytes(statement, 0), transient) }
        else { sqlite3_result_null(result) }
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(queryDB, sql, nil, nil, nil) == SQLITE_OK else { throw MailError.message("邮件数据接口初始化失败。") }
    }
    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(queryDB, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw MailError.message("邮件数据查询无效：" + String(cString: sqlite3_errmsg(queryDB))) }
        return statement
    }
    private func insert(_ statement: OpaquePointer, _ fields: [String]) throws {
        sqlite3_reset(statement); sqlite3_clear_bindings(statement)
        for (index, value) in fields.enumerated() { sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw MailError.message("邮件数据索引准备失败。") }
    }
    public func query(_ sql: String, maximumRows: Int = 1000) throws -> OpenUIJSON {
        lock.lock(); defer { lock.unlock(); deadline = .distantFuture }
        guard !sql.isEmpty, sql.utf8.count <= 16000 else { throw MailError.message("SQL为空或超过16000字节。") }
        deadline = Date().addingTimeInterval(5)
        var statement: OpaquePointer?
        // Consume the tail while the original C string remains alive.
        try sql.withCString { start in
            var tail: UnsafePointer<CChar>?
            guard sqlite3_prepare_v2(queryDB, start, -1, &statement, &tail) == SQLITE_OK, statement != nil else { throw MailError.message("只读SQL查询无效：" + String(cString: sqlite3_errmsg(queryDB))) }
            if let tail, !String(cString: tail).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { sqlite3_finalize(statement); statement = nil; throw MailError.message("一次只能执行一条只读SQL查询。") }
        }
        guard let statement else { throw MailError.message("SQL未返回查询。") }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_stmt_readonly(statement) != 0 else { throw MailError.message("邮件数据接口只允许查询。") }
        let limit = min(2000, max(1, maximumRows)), count = sqlite3_column_count(statement)
        let columns = (0..<count).map { String(cString: sqlite3_column_name(statement, $0)) }
        var rows: [OpenUIJSON] = [], bytes = 0, truncated = false
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw MailError.message("只读SQL查询未完成（可能达到5秒预算），请缩小范围或先查询mail_index元数据。") }
            if rows.count == limit { truncated = true; break }
            var row: [String: OpenUIJSON] = [:]
            for column in 0..<count {
                let value: OpenUIJSON
                switch sqlite3_column_type(statement, column) {
                case SQLITE_NULL: value = .null
                case SQLITE_INTEGER: value = .number(Double(sqlite3_column_int64(statement, column)))
                case SQLITE_FLOAT: value = .number(sqlite3_column_double(statement, column))
                default:
                    let length = Int(sqlite3_column_bytes(statement, column)), bounded = min(length, 65536)
                    if length > bounded { truncated = true }
                    if let pointer = sqlite3_column_text(statement, column) { value = .string(String(decoding: UnsafeBufferPointer(start: pointer, count: bounded), as: UTF8.self)) } else { value = .null }
                }
                row[columns[Int(column)]] = value
            }
            let encoded = try JSONEncoder().encode(OpenUIJSON.object(row)).count
            if bytes + encoded > 512 * 1024 { truncated = true; break }
            bytes += encoded; rows.append(.object(row))
            for key in ["id", "messageID"] { if let id = row[key]?.text, ids.contains(id) { readIDs.insert(id) } }
            if let sources = row["source_ids_json"]?.text, let values = try? JSONDecoder().decode([String].self, from: Data(sources.utf8)) { readIDs.formUnion(values.filter(ids.contains)) }
        }
        return .object(["columns": .array(columns.map(OpenUIJSON.string)), "rows": .array(rows), "truncated": .bool(truncated), "coverage": .string("本轮允许邮件的元数据快照及按需读取的本机正文；truncated=true时结果未完整返回")])
    }
}
