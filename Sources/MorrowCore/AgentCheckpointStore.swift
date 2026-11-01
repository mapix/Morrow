import Foundation
import CMail

/// LangGraph's opaque checkpoints share the existing private mail database.
/// No mail rows, raw messages, or separate database copies are created here.
public actor AgentCheckpointStore {
    private var db: OpaquePointer?
    private let maximumBytes = 128 * 1024 * 1024
    private enum Value { case text(String), blob(Data), int(Int64) }
    public init(root: URL) throws {
        guard sqlite3_open_v2(root.appendingPathComponent("mail.sqlite").path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw MailError.message("无法打开 Agent 状态存储。") }
        sqlite3_busy_timeout(db, 5000)
        let schema = """
        PRAGMA foreign_keys=ON;
        CREATE TABLE IF NOT EXISTS agent_sdk_usage(id INTEGER PRIMARY KEY CHECK(id=1),bytes INTEGER NOT NULL);
        INSERT OR IGNORE INTO agent_sdk_usage VALUES(1,0);
        CREATE TABLE IF NOT EXISTS agent_sdk_checkpoints(thread TEXT NOT NULL,ns TEXT NOT NULL,id TEXT NOT NULL,json BLOB NOT NULL,PRIMARY KEY(thread,ns,id));
        CREATE TABLE IF NOT EXISTS agent_sdk_writes(thread TEXT NOT NULL,ns TEXT NOT NULL,checkpoint TEXT NOT NULL,task TEXT NOT NULL,slot INTEGER NOT NULL,path TEXT NOT NULL,json BLOB NOT NULL,PRIMARY KEY(thread,ns,checkpoint,task,slot));
        CREATE TRIGGER IF NOT EXISTS agent_sdk_cp_insert AFTER INSERT ON agent_sdk_checkpoints BEGIN UPDATE agent_sdk_usage SET bytes=bytes+length(new.json) WHERE id=1; END;
        CREATE TRIGGER IF NOT EXISTS agent_sdk_cp_update AFTER UPDATE OF json ON agent_sdk_checkpoints BEGIN UPDATE agent_sdk_usage SET bytes=bytes+length(new.json)-length(old.json) WHERE id=1; END;
        CREATE TRIGGER IF NOT EXISTS agent_sdk_cp_delete AFTER DELETE ON agent_sdk_checkpoints BEGIN UPDATE agent_sdk_usage SET bytes=bytes-length(old.json) WHERE id=1; END;
        CREATE TRIGGER IF NOT EXISTS agent_sdk_wr_insert AFTER INSERT ON agent_sdk_writes BEGIN UPDATE agent_sdk_usage SET bytes=bytes+length(new.json) WHERE id=1; END;
        CREATE TRIGGER IF NOT EXISTS agent_sdk_wr_update AFTER UPDATE OF json ON agent_sdk_writes BEGIN UPDATE agent_sdk_usage SET bytes=bytes+length(new.json)-length(old.json) WHERE id=1; END;
        CREATE TRIGGER IF NOT EXISTS agent_sdk_wr_delete AFTER DELETE ON agent_sdk_writes BEGIN UPDATE agent_sdk_usage SET bytes=bytes-length(old.json) WHERE id=1; END;
        """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else { throw MailError.message("Agent 状态存储初始化失败。") }
    }
    deinit { sqlite3_close(db) }
    private func statement(_ sql: String, _ values: [Value] = []) throws -> OpaquePointer {
        var result: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &result, nil) == SQLITE_OK, let result else { throw MailError.message("Agent 状态查询失败。") }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let text): sqlite3_bind_text(result, index, text, -1, transient)
            case .blob(let bytes): bytes.withUnsafeBytes { _ = sqlite3_bind_blob(result, index, $0.baseAddress, Int32(bytes.count), transient) }
            case .int(let number): sqlite3_bind_int64(result, index, number)
            }
        }
        return result
    }
    private func execute(_ sql: String, _ values: [Value] = []) throws {
        let query = try statement(sql, values); defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_DONE else { throw MailError.message("Agent 状态写入失败：" + String(cString: sqlite3_errmsg(db))) }
    }
    private func bytes(_ query: OpaquePointer, _ index: Int32) -> Data {
        guard let pointer = sqlite3_column_blob(query, index) else { return Data() }
        return Data(bytes: pointer, count: Int(sqlite3_column_bytes(query, index)))
    }
    public func usageBytes() throws -> Int {
        let query = try statement("SELECT bytes FROM agent_sdk_usage WHERE id=1"); defer { sqlite3_finalize(query) }
        return sqlite3_step(query) == SQLITE_ROW ? Int(sqlite3_column_int64(query, 0)) : 0
    }
    private func budget(_ bytes: Data) throws {
        guard bytes.count <= 2 * 1024 * 1024, try usageBytes() <= maximumBytes - bytes.count else { throw MailError.message("Agent 会话状态达到缓存预算，请清理旧会话的运行状态后继续。") }
    }
    public func handle(method: String, params: OpenUIJSON, sessionID: String) throws -> OpenUIJSON {
        let fields = params.object
        if method == "checkpoint.delete" {
            guard fields["threadId"]?.text == sessionID else { throw MailError.message("Agent 状态不属于当前会话。") }
            try execute("BEGIN IMMEDIATE")
            do {
                try execute("DELETE FROM agent_sdk_writes WHERE thread=?", [.text(sessionID)])
                try execute("DELETE FROM agent_sdk_checkpoints WHERE thread=?", [.text(sessionID)])
                try execute("COMMIT"); return .null
            } catch { try? execute("ROLLBACK"); throw error }
        }
        let rawConfig = fields["config"]?.object ?? [:]
        let config = rawConfig["configurable"]?.object ?? rawConfig
        guard config["thread_id"]?.text == sessionID, sessionID.utf8.count <= 256 else { throw MailError.message("Agent 状态不属于当前会话。") }
        let ns = config["checkpoint_ns"]?.text ?? "", id = config["checkpoint_id"]?.text ?? ""
        guard ns.utf8.count <= 4096, id.utf8.count <= 256 else { throw MailError.message("Agent 状态标识超过限制。") }
        switch method {
        case "checkpoint.get":
            let sql = "SELECT id,json FROM agent_sdk_checkpoints WHERE thread=? AND ns=?" + (id.isEmpty ? " ORDER BY id DESC LIMIT 1" : " AND id=?")
            let query = try statement(sql, [.text(sessionID), .text(ns)] + (id.isEmpty ? [] : [.text(id)])); defer { sqlite3_finalize(query) }
            guard sqlite3_step(query) == SQLITE_ROW else { return .null }
            let found = String(cString: sqlite3_column_text(query, 0))
            var checkpoint = try JSONDecoder().decode(OpenUIJSON.self, from: bytes(query, 1)).object
            let writes = try statement("SELECT json FROM agent_sdk_writes WHERE thread=? AND ns=? AND checkpoint=? ORDER BY path,task,slot", [.text(sessionID), .text(ns), .text(found)]); defer { sqlite3_finalize(writes) }
            var values: [OpenUIJSON] = []
            while sqlite3_step(writes) == SQLITE_ROW { values.append(try JSONDecoder().decode(OpenUIJSON.self, from: bytes(writes, 0))) }
            checkpoint["writes"] = .array(values); return .object(checkpoint)
        case "checkpoint.put":
            guard !id.isEmpty, fields["checkpoint"] != nil, fields["metadata"] != nil else { throw MailError.message("Agent 状态记录不完整。") }
            let data = try JSONEncoder().encode(params); try budget(data)
            try execute("INSERT INTO agent_sdk_checkpoints(thread,ns,id,json) VALUES(?,?,?,?) ON CONFLICT(thread,ns,id) DO UPDATE SET json=excluded.json", [.text(sessionID), .text(ns), .text(id), .blob(data)])
            return .null
        case "checkpoint.writes":
            guard !id.isEmpty, case .array(let writes) = fields["writes"], writes.count <= 256 else { throw MailError.message("Agent 状态写入批次无效。") }
            try execute("BEGIN IMMEDIATE")
            do {
                for write in writes {
                    let value = write.object, task = value["taskId"]?.text ?? "", path = value["taskPath"]?.text ?? ""
                    guard !task.isEmpty, task.utf8.count <= 256, path.utf8.count <= 4096, let slot = Int(value["index"]?.text ?? ""), value["value"] != nil else { throw MailError.message("Agent 状态写入记录无效。") }
                    let data = try JSONEncoder().encode(write); try budget(data)
                    let insert = slot < 0 ? "INSERT INTO" : "INSERT OR IGNORE INTO"
                    let update = slot < 0 ? " ON CONFLICT(thread,ns,checkpoint,task,slot) DO UPDATE SET json=excluded.json,path=excluded.path" : ""
                    try execute(insert + " agent_sdk_writes(thread,ns,checkpoint,task,slot,path,json) VALUES(?,?,?,?,?,?,?)" + update, [.text(sessionID), .text(ns), .text(id), .text(task), .int(Int64(slot)), .text(path), .blob(data)])
                }
                try execute("COMMIT"); return .null
            } catch { try? execute("ROLLBACK"); throw error }
        case "checkpoint.list":
            let options = fields["options"]?.object ?? [:], limit = min(50, max(1, Int(options["limit"]?.text ?? "20") ?? 20))
            let before = options["before"]?.object["configurable"]?.object["checkpoint_id"]?.text
            let query = try statement("SELECT id FROM agent_sdk_checkpoints WHERE thread=? AND ns=?" + (before == nil ? "" : " AND id<?") + " ORDER BY id DESC LIMIT ?", [.text(sessionID), .text(ns)] + (before.map { [.text($0)] } ?? []) + [.int(Int64(limit))]); defer { sqlite3_finalize(query) }
            var result: [OpenUIJSON] = []
            while sqlite3_step(query) == SQLITE_ROW {
                let found = String(cString: sqlite3_column_text(query, 0))
                result.append(.object(["configurable": .object(["thread_id": .string(sessionID), "checkpoint_ns": .string(ns), "checkpoint_id": .string(found)])]))
            }
            return .array(result)
        default: throw MailError.message("未知 Agent 状态操作。")
        }
    }
}
