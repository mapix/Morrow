import Foundation
import CryptoKit
import CMail

public actor MailStore {
    public nonisolated let root: URL
    private var db: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(root: URL? = nil) throws {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Morrow", isDirectory: true)
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for name in ["raw", "attachments", "models"] { try FileManager.default.createDirectory(at: self.root.appendingPathComponent(name), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        let code = sqlite3_open_v2(self.root.appendingPathComponent("mail.sqlite").path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard code == SQLITE_OK else { throw MailError.message("无法打开本地邮件库。") }
        sqlite3_busy_timeout(db, 5000)
        let schema = """
        PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;
        CREATE TABLE IF NOT EXISTS objects(kind TEXT NOT NULL,id TEXT NOT NULL,json BLOB NOT NULL,PRIMARY KEY(kind,id));
        CREATE TABLE IF NOT EXISTS messages(id TEXT PRIMARY KEY, account TEXT NOT NULL, folder TEXT NOT NULL, uid INTEGER NOT NULL, validity INTEGER NOT NULL, date REAL NOT NULL, search TEXT NOT NULL, json BLOB NOT NULL,canonical TEXT NOT NULL DEFAULT '');
        CREATE INDEX IF NOT EXISTS folder_uid ON messages(account,folder,validity,uid);
        CREATE INDEX IF NOT EXISTS message_date ON messages(date DESC);
        CREATE VIRTUAL TABLE IF NOT EXISTS mail_fts USING fts5(id UNINDEXED,body,tokenize='unicode61');
        CREATE TABLE IF NOT EXISTS vectors(id TEXT PRIMARY KEY,message TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,chunk TEXT NOT NULL,vector BLOB NOT NULL,model TEXT NOT NULL,hash TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS vector_message ON vectors(message);
        CREATE TABLE IF NOT EXISTS index_state(message TEXT PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,hash TEXT NOT NULL,model TEXT NOT NULL);
        """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else { throw MailError.message("本地邮件库初始化失败。") }
        var columns: OpaquePointer?; var hasCanonical = false
        sqlite3_prepare_v2(db, "PRAGMA table_info(messages)", -1, &columns, nil)
        while sqlite3_step(columns) == SQLITE_ROW { if let name = sqlite3_column_text(columns, 1), String(cString: name) == "canonical" { hasCanonical = true } }; sqlite3_finalize(columns)
        if !hasCanonical { guard sqlite3_exec(db, "ALTER TABLE messages ADD COLUMN canonical TEXT NOT NULL DEFAULT ''", nil, nil, nil) == SQLITE_OK else { throw MailError.message("邮件库升级失败。") } }
        let migration = "UPDATE messages SET canonical=CASE WHEN coalesce(json_extract(CAST(json AS TEXT),'$.messageID'),'')='' THEN id ELSE account || ':message:' || trim(json_extract(CAST(json AS TEXT),'$.messageID')) END WHERE canonical=''; CREATE INDEX IF NOT EXISTS message_canonical ON messages(canonical);"
        guard sqlite3_exec(db, migration, nil, nil, nil) == SQLITE_OK else { throw MailError.message("邮件库标识升级失败。") }
        try Self.initializeCloudJournal(db)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.root.appendingPathComponent("mail.sqlite").path)
    }
    deinit { sqlite3_close(db) }

    private enum Value { case text(String), blob(Data), int(Int64), real(Double) }
    private func statement(_ sql: String, _ parameters: [Value] = []) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw databaseError() }
        for (i, p) in parameters.enumerated() {
            let n = Int32(i + 1)
            switch p {
            case .text(let s): sqlite3_bind_text(stmt, n, s, -1, transient)
            case .blob(let d): d.withUnsafeBytes { b in _ = sqlite3_bind_blob(stmt, n, b.baseAddress, Int32(d.count), transient) }
            case .int(let v): sqlite3_bind_int64(stmt, n, v)
            case .real(let v): sqlite3_bind_double(stmt, n, v)
            }
        }; return stmt
    }
    private func execute(_ sql: String, _ parameters: [Value] = []) throws {
        let s = try statement(sql, parameters); defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_DONE else { throw databaseError() }
    }
    private func databaseError() -> MailError { .message("本地邮件库操作失败：" + String(cString: sqlite3_errmsg(db))) }
    private func bytes(_ s: OpaquePointer, _ index: Int32) -> Data { guard let p = sqlite3_column_blob(s, index) else { return Data() }; return Data(bytes: p, count: Int(sqlite3_column_bytes(s, index))) }
    private func string(_ s: OpaquePointer, _ index: Int32) -> String { guard let p = sqlite3_column_text(s, index) else { return "" }; return String(cString: p) }

    public func save<T: Encodable>(_ value: T, kind: String, id: String) throws { try execute("INSERT OR REPLACE INTO objects(kind,id,json) VALUES(?,?,?)", [.text(kind), .text(id), .blob(try encoder.encode(value))]) }
    public func load<T: Decodable>(_ type: T.Type, kind: String) throws -> [T] {
        let s = try statement("SELECT json FROM objects WHERE kind=? ORDER BY rowid", [.text(kind)]); defer { sqlite3_finalize(s) }
        var result: [T] = []; while sqlite3_step(s) == SQLITE_ROW { result.append(try decoder.decode(type, from: bytes(s, 0))) }; return result
    }
    public func remove(kind: String, id: String) throws { try execute("DELETE FROM objects WHERE kind=? AND id=?", [.text(kind), .text(id)]) }
    public func commitMailboxConnection(_ account: MailAccount, folders: [MailFolder]) throws {
        guard folders.allSatisfy({ $0.accountID == account.id }) else { throw MailError.message("Mailbox folders do not belong to this account.") }
        try execute("BEGIN IMMEDIATE")
        do {
            try save(account, kind: "account", id: account.id)
            for folder in folders { try save(folder, kind: "folder", id: folder.id) }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    public func object<T: Decodable>(_ type: T.Type, kind: String, id: String) throws -> T? {
        let s = try statement("SELECT json FROM objects WHERE kind=? AND id=?", [.text(kind), .text(id)]); defer { sqlite3_finalize(s) }
        return sqlite3_step(s) == SQLITE_ROW ? try decoder.decode(type, from: bytes(s, 0)) : nil
    }
    public func commitDelegation(_ delegation: Delegation, draft: ComposeDraft?, event: PartnerEvent) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try save(delegation, kind: "delegation", id: delegation.id)
            if let draft { try save(draft, kind: "draft", id: draft.id) }
            try save(event, kind: "event", id: event.id)
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    public func claimDraft(_ id: String, now: Date = Date()) throws -> ComposeDraft? {
        try execute("BEGIN IMMEDIATE")
        do {
            let s = try statement("SELECT json FROM objects WHERE kind='draft' AND id=?", [.text(id)])
            let data = sqlite3_step(s) == SQLITE_ROW ? bytes(s, 0) : nil; sqlite3_finalize(s)
            guard let data else { try execute("COMMIT"); return nil }
            var draft = try decoder.decode(ComposeDraft.self, from: data)
            guard draft.state == "queued", (draft.scheduledAt ?? .distantFuture) <= now else { try execute("COMMIT"); return nil }
            draft.state = "sending"; draft.updatedAt = now
            try save(draft, kind: "draft", id: id); try execute("COMMIT"); return draft
        } catch { try? execute("ROLLBACK"); throw error }
    }
    public func queueReviewedDraft(_ reviewed: ComposeDraft, now: Date = Date()) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            let existing = try object(ComposeDraft.self, kind: "draft", id: reviewed.id)
            let protected = ["sent", "sending", "queued", "uncertain"]
            guard !protected.contains(reviewed.state), existing.map({ !protected.contains($0.state) }) ?? true else { throw MailError.message("This draft is already queued, sent, or awaiting delivery verification.") }
            var queued = reviewed; queued.state = "queued"; queued.scheduledAt = max(reviewed.scheduledAt ?? now, now); queued.updatedAt = now
            try save(queued, kind: "draft", id: queued.id); try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    public func cancelQueuedDraft(_ id: String) throws -> ComposeDraft {
        try execute("BEGIN IMMEDIATE")
        do {
            guard var draft = try object(ComposeDraft.self, kind: "draft", id: id), draft.state == "queued" else { throw MailError.message("This draft has already left the queue. Check its delivery state before retrying.") }
            draft.state = "draft"; draft.scheduledAt = nil; draft.updatedAt = Date()
            try save(draft, kind: "draft", id: id); try execute("COMMIT"); return draft
        } catch { try? execute("ROLLBACK"); throw error }
    }
    public func discardEditableDraft(_ id: String) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            if let draft = try object(ComposeDraft.self, kind: "draft", id: id), ["sent", "sending", "uncertain"].contains(draft.state) { throw MailError.message("A sent or unverified delivery cannot be discarded as an editable draft.") }
            try remove(kind: "draft", id: id); try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    public func claimResponder(_ receipt: ResponderReceipt) throws -> Bool {
        try execute("BEGIN IMMEDIATE")
        do {
            if try object(ResponderReceipt.self, kind: "responder-receipt", id: receipt.id) != nil { try execute("COMMIT"); return false }
            try save(receipt, kind: "responder-receipt", id: receipt.id); try execute("COMMIT"); return true
        } catch { try? execute("ROLLBACK"); throw error }
    }
    public func commitResponder(_ rule: MailResponder, receipt: ResponderReceipt, draft: ComposeDraft, event: PartnerEvent) throws {
        try execute("BEGIN IMMEDIATE")
        do { try save(rule, kind: "responder", id: rule.id); try save(receipt, kind: "responder-receipt", id: receipt.id); try save(draft, kind: "draft", id: draft.id); try save(event, kind: "event", id: event.id); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }
    public func updateOpenUIState(_ values: [String: OpenUIJSON], id: String, revision: Int) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            if var page = try object(OpenUIInteraction.self, kind: "openui-interaction", id: id), page.completedAt == nil, page.stateRevision <= revision { page.values = values; page.stateRevision = revision; try save(page, kind: "openui-interaction", id: id) }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    @discardableResult public func upsert(_ value: MailMessage) throws -> MailMessage {
        var m = value
        if !m.raw.isEmpty { try privateWrite(m.raw, to: rawURL(m.id)); m.raw = Data() }
        for i in m.attachments.indices where !m.attachments[i].data.isEmpty {
            let a = m.attachments[i]; let url = root.appendingPathComponent("attachments/" + a.id)
            try privateWrite(a.data, to: url); m.attachments[i].storedPath = url.path; m.attachments[i].byteCount = a.data.count; m.attachments[i].data = Data()
        }
        let search = [m.subject, m.from.name, m.from.email, m.to.map(\.email).joined(separator: " "), m.text, m.note, m.analysis?.summary ?? "", m.labels.joined(separator: " ")].joined(separator: "\n")
        let ownsTransaction = sqlite3_get_autocommit(db) != 0
        if ownsTransaction { try execute("BEGIN IMMEDIATE") }
        do {
            try execute("INSERT INTO messages(id,account,folder,uid,validity,date,search,json,canonical) VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET account=excluded.account,folder=excluded.folder,uid=excluded.uid,validity=excluded.validity,date=excluded.date,search=excluded.search,json=excluded.json,canonical=excluded.canonical", [.text(m.id), .text(m.accountID), .text(m.folder), .int(Int64(m.uid)), .int(Int64(m.uidValidity)), .real(m.date.timeIntervalSince1970), .text(search), .blob(try encoder.encode(m)), .text(m.canonicalID)])
            try execute("DELETE FROM mail_fts WHERE id=?", [.text(m.id)])
            try execute("INSERT INTO mail_fts(id,body) VALUES(?,?)", [.text(m.id), .text(search)])
            if ownsTransaction { try execute("COMMIT") }
        } catch { if ownsTransaction { try? execute("ROLLBACK") }; throw error }
        return m
    }

    /// Persist an incoming message and its local processing job atomically.
    /// Files are local cache; the message row and durable job share one commit.
    public func commitIncoming<T: Encodable>(_ mail: MailMessage, object: T, kind: String, id: String) throws -> MailMessage {
        try execute("BEGIN IMMEDIATE")
        do {
            let saved = try upsert(mail)
            try save(object, kind: kind, id: id)
            try execute("COMMIT")
            return saved
        } catch { try? execute("ROLLBACK"); throw error }
    }

    /// IMAP calls supply a folder and read only indexed inventory columns.
    /// Account-wide POP calls additionally extract UIDL from one row at a time,
    /// without decoding a MailMessage or holding its body across a sync pass.
    public func syncRecords(account: String, folder: String? = nil) throws -> [MailSyncRecord] {
        let popField = folder == nil ? "json_extract(CAST(json AS TEXT),'$.popUID')" : "NULL"
        var sql = "SELECT id,uid,validity," + popField + " FROM messages WHERE account=?"
        var parameters: [Value] = [.text(account)]
        if let folder { sql += " AND folder=?"; parameters.append(.text(folder)) }
        sql += " ORDER BY date DESC,id"
        let s = try statement(sql, parameters); defer { sqlite3_finalize(s) }
        var result: [MailSyncRecord] = []
        while true {
            let code = sqlite3_step(s)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw databaseError() }
            let uid = sqlite3_column_int64(s, 1), validity = sqlite3_column_int64(s, 2)
            guard uid >= 0, validity >= 0 else { throw MailError.message("本地邮件同步标识无效。") }
            let popUID = sqlite3_column_type(s, 3) == SQLITE_NULL ? nil : string(s, 3)
            result.append(MailSyncRecord(id: string(s, 0), uid: UInt64(uid), uidValidity: UInt64(validity), popUID: popUID))
        }
        return result
    }
    public func messages(account: String? = nil, folder: String? = nil) throws -> [MailMessage] {
        var sql = "SELECT json FROM messages"; var clauses: [String] = []; var params: [Value] = []
        if let account { clauses.append("account=?"); params.append(.text(account)) }
        if let folder { clauses.append("folder=?"); params.append(.text(folder)) }
        if !clauses.isEmpty { sql += " WHERE " + clauses.joined(separator: " AND ") }; sql += " ORDER BY date DESC"
        let s = try statement(sql, params); defer { sqlite3_finalize(s) }; var out: [MailMessage] = []
        while sqlite3_step(s) == SQLITE_ROW { out.append(try decoder.decode(MailMessage.self, from: bytes(s, 0))) }; return out
    }
    public func message(_ id: String) throws -> MailMessage? {
        let s = try statement("SELECT json FROM messages WHERE id=?", [.text(id)]); defer { sqlite3_finalize(s) }
        return sqlite3_step(s) == SQLITE_ROW ? try decoder.decode(MailMessage.self, from: bytes(s, 0)) : nil
    }
    public func deleteMessage(_ id: String) throws {
        if let m = try message(id) { for a in m.attachments { if let path = a.storedPath { try? FileManager.default.removeItem(atPath: path) }; try remove(kind: "attachment-text", id: a.id) }; try? FileManager.default.removeItem(at: rawURL(id)) }
        try execute("DELETE FROM messages WHERE id=?", [.text(id)]); try execute("DELETE FROM mail_fts WHERE id=?", [.text(id)])
    }
    public func deleteAccount(_ id: String) throws {
        for m in try messages(account: id) { try deleteMessage(m.id) }
        try remove(kind: "account", id: id)
        for f in try load(MailFolder.self, kind: "folder") where f.accountID == id { try remove(kind: "folder", id: f.id) }
    }
    public func rawData(_ message: MailMessage) throws -> Data { message.raw.isEmpty ? try Data(contentsOf: rawURL(message.id)) : message.raw }
    public func attachmentData(_ attachment: MailAttachment) throws -> Data { if !attachment.data.isEmpty { return attachment.data }; guard let path = attachment.storedPath else { return Data() }; return try Data(contentsOf: URL(fileURLWithPath: path)) }
    public func hydrate(_ message: MailMessage) throws -> MailMessage {
        var m = message; m.raw = (try? rawData(m)) ?? Data(); for i in m.attachments.indices { m.attachments[i].data = try attachmentData(m.attachments[i]) }; return m
    }
    public func rawURL(_ id: String) -> URL { root.appendingPathComponent("raw/" + Self.hash(id) + ".eml") }
    private func privateWrite(_ data: Data, to url: URL) throws { try data.write(to: url, options: .atomic); try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
    public nonisolated static func hash(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    public nonisolated static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    public func keywordSearch(_ query: String, limit: Int = 60, allowedIDs: Set<String>? = nil) throws -> [SearchHit] {
        if allowedIDs?.isEmpty == true { return [] }
        let parsed = MailQuery(query)
        if parsed.hasFilters {
            let tokens = parsed.text.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
            let values = try messages().filter { m in (allowedIDs?.contains(m.id) ?? true) && parsed.matches(m) && (tokens.isEmpty || tokens.contains(where: { (m.subject + " " + m.text + " " + m.from.email).lowercased().contains($0) })) }.map { SearchHit(message: $0, score: 1, method: "条件检索") }
            return deduplicate(values, limit: limit)
        }
        let tokens = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return [] }
        let clauses = tokens.map { _ in "instr(lower(search),lower(?))>0" }.joined(separator: " OR ")
        let sqlLimit = allowedIDs == nil ? " LIMIT ?" : ""
        let bindings = tokens.map(Value.text) + (allowedIDs == nil ? [.int(Int64(limit * 4))] : [])
        let s = try statement("SELECT json,search FROM messages WHERE \(clauses) ORDER BY date DESC" + sqlLimit, bindings); defer { sqlite3_finalize(s) }
        var out: [SearchHit] = []
        while sqlite3_step(s) == SQLITE_ROW {
            let m = try decoder.decode(MailMessage.self, from: bytes(s, 0)); guard allowedIDs?.contains(m.id) ?? true else { continue }; let body = string(s, 1).lowercased(); let score = Float(tokens.filter { body.contains($0.lowercased()) }.count) / Float(tokens.count)
            out.append(.init(message: m, score: score, method: "关键词"))
        }; return deduplicate(out.sorted { $0.score > $1.score }, limit: limit)
    }
    private func deduplicate(_ values: [SearchHit], limit: Int) -> [SearchHit] {
        var ordered: [String] = []; var best: [String: SearchHit] = [:]
        for hit in values { let key = hit.message.canonicalID; if best[key] == nil { ordered.append(key); best[key] = hit } else if hit.message.folder == "INBOX" { best[key] = hit } }
        return ordered.prefix(limit).compactMap { best[$0] }
    }
    public func isIndexed(_ id: String, hash: String, model: String) throws -> Bool {
        let s = try statement("SELECT 1 FROM index_state WHERE message=? AND hash=? AND model=?", [.text(id), .text(hash), .text(model)]); defer { sqlite3_finalize(s) }; return sqlite3_step(s) == SQLITE_ROW
    }
    public func putVectors(messageID: String, chunks: [String], vectors: [[Float]], model: String, hash: String) throws {
        guard chunks.count == vectors.count, vectors.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isFinite) }) else { throw MailError.message("模型返回的向量无效。") }
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("DELETE FROM vectors WHERE message=?", [.text(messageID)])
            for i in chunks.indices { let data = vectors[i].withUnsafeBytes { Data($0) }; try execute("INSERT INTO vectors VALUES(?,?,?,?,?,?)", [.text(messageID + ":" + String(i)), .text(messageID), .text(chunks[i]), .blob(data), .text(model), .text(hash)]) }
            try execute("INSERT OR REPLACE INTO index_state VALUES(?,?,?)", [.text(messageID), .text(hash), .text(model)]); try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    public func reuseVectors(canonical: String, targetID: String, model: String, hash: String) throws -> Bool {
        try execute("BEGIN IMMEDIATE")
        do {
            let source = try statement("SELECT i.message FROM index_state i JOIN messages m ON m.id=i.message WHERE m.canonical=? AND m.id<>? AND i.model=? AND i.hash=? LIMIT 1", [.text(canonical), .text(targetID), .text(model), .text(hash)])
            let sourceID = sqlite3_step(source) == SQLITE_ROW ? string(source, 0) : nil; sqlite3_finalize(source)
            guard let sourceID else { try execute("COMMIT"); return false }
            let s = try statement("SELECT chunk,vector FROM vectors WHERE message=? ORDER BY id", [.text(sourceID)])
            var values: [(String, Data)] = []; while sqlite3_step(s) == SQLITE_ROW { values.append((string(s, 0), bytes(s, 1))) }; sqlite3_finalize(s)
            guard !values.isEmpty else { try execute("COMMIT"); return false }
            try execute("DELETE FROM vectors WHERE message=?", [.text(targetID)])
            for (i, value) in values.enumerated() { try execute("INSERT INTO vectors VALUES(?,?,?,?,?,?)", [.text(targetID + ":" + String(i)), .text(targetID), .text(value.0), .blob(value.1), .text(model), .text(hash)]) }
            try execute("INSERT OR REPLACE INTO index_state VALUES(?,?,?)", [.text(targetID), .text(hash), .text(model)]); try execute("COMMIT"); return true
        } catch { try? execute("ROLLBACK"); throw error }
    }
    public func searchIndexCoverage(model: String, allowedIDs: Set<String>? = nil, dimensions: Int = 768) throws -> (eligibleCount: Int, indexedCount: Int) {
        if allowedIDs?.isEmpty == true { return (0, 0) }
        // Coverage is metadata, not message rendering. Avoid decoding every
        // HTML payload just to count which canonical messages have vectors.
        let metadata = try statement("SELECT id,canonical FROM messages"); defer { sqlite3_finalize(metadata) }
        var canonicalByID: [String: String] = [:]
        while sqlite3_step(metadata) == SQLITE_ROW {
            let id = string(metadata, 0); guard allowedIDs?.contains(id) ?? true else { continue }
            let canonical = string(metadata, 1); canonicalByID[id] = canonical.isEmpty ? id : canonical
        }
        let s = try statement("SELECT DISTINCT v.message FROM vectors v JOIN index_state i ON i.message=v.message WHERE v.model=? AND i.model=? AND length(v.vector)=?", [.text(model), .text(model), .int(Int64(dimensions * MemoryLayout<Float>.size))]); defer { sqlite3_finalize(s) }
        var indexed = Set<String>()
        while sqlite3_step(s) == SQLITE_ROW { if let canonical = canonicalByID[string(s, 0)] { indexed.insert(canonical) } }
        return (Set(canonicalByID.values).count, indexed.count)
    }
    public func vectorSearch(_ query: [Float], model: String, limit: Int = 30, allowedIDs: Set<String>? = nil, minimumScore: Float? = nil) throws -> [SearchHit] {
        if allowedIDs?.isEmpty == true { return [] }
        guard !query.isEmpty, query.allSatisfy(\.isFinite) else { throw MailError.message("检索向量无效。") }
        guard limit > 0 else { return [] }
        struct Candidate {
            var id: String; var canonical: String; var folder: String; var date: Double; var score: Float; var snippet: String
        }
        let s = try statement("SELECT v.message,m.canonical,m.folder,m.date,v.vector,v.chunk FROM vectors v JOIN messages m ON m.id=v.message WHERE v.model=?", [.text(model)]); defer { sqlite3_finalize(s) }
        var best: [String: Candidate] = [:]
        while sqlite3_step(s) == SQLITE_ROW {
            let id = string(s, 0); guard allowedIDs?.contains(id) ?? true else { continue }
            let count = Int(sqlite3_column_bytes(s, 4))
            guard count == query.count * MemoryLayout<Float>.size, let pointer = sqlite3_column_blob(s, 4) else { continue }
            // SQLite owns this blob until step/finalize. Score it in place;
            // allocating a Data and Float array for every chunk is unnecessary.
            let raw = UnsafeRawBufferPointer(start: pointer, count: count)
            var score: Float = 0
            for i in query.indices { score += query[i] * raw.loadUnaligned(fromByteOffset: i * MemoryLayout<Float>.size, as: Float.self) }
            guard score.isFinite, minimumScore.map({ score >= $0 }) ?? true else { continue }
            if score > (best[id]?.score ?? -.infinity) {
                let canonical = string(s, 1)
                best[id] = Candidate(id: id, canonical: canonical.isEmpty ? id : canonical, folder: string(s, 2), date: sqlite3_column_double(s, 3), score: score, snippet: string(s, 5))
            }
        }
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
        // Decode only the final Top-K bodies after ranking and deduplication.
        return try ranked.compactMap { candidate -> SearchHit? in
            guard let mail = try message(candidate.id) else { return nil }
            return SearchHit(message: mail, score: candidate.score, method: "语义（EmbeddingGemma 2）", snippet: candidate.snippet)
        }
    }
    public func indexCount() throws -> Int {
        let s = try statement("SELECT count(DISTINCT m.canonical) FROM index_state i JOIN messages m ON m.id=i.message"); defer { sqlite3_finalize(s) }; return sqlite3_step(s) == SQLITE_ROW ? Int(sqlite3_column_int(s, 0)) : 0
    }
}

extension MailStore {
    public func saveSessionDraft(_ snapshot: ChatSession) throws -> ChatSession {
        try execute("BEGIN IMMEDIATE")
        do {
            var current = try object(ChatSession.self, kind: "chat-session", id: snapshot.id) ?? snapshot
            if snapshot.draftRevision >= current.draftRevision {
                current.input = snapshot.input; current.materials = snapshot.materials; current.pinnedContext = snapshot.pinnedContext; current.newWork = snapshot.newWork; current.draftRevision = snapshot.draftRevision
            }
            try save(current, kind: "chat-session", id: current.id); try execute("COMMIT"); return current
        } catch { try? execute("ROLLBACK"); throw error }
    }
    public func saveSessionMetadata(_ snapshot: ChatSession) throws -> ChatSession {
        try execute("BEGIN IMMEDIATE")
        do {
            var current = try object(ChatSession.self, kind: "chat-session", id: snapshot.id) ?? snapshot
            current.title = snapshot.title; current.archived = snapshot.archived; current.summary = snapshot.summary; current.summaryThrough = snapshot.summaryThrough; current.updatedAt = max(current.updatedAt, snapshot.updatedAt)
            try save(current, kind: "chat-session", id: current.id); try execute("COMMIT"); return current
        } catch { try? execute("ROLLBACK"); throw error }
    }
    public func commitChat(_ message: PartnerChat, session: ChatSession) throws -> ChatSession {
        try execute("BEGIN IMMEDIATE")
        do {
            var current = try object(ChatSession.self, kind: "chat-session", id: session.id) ?? session
            if current.title == "新对话" && message.role == "user" { current.title = String(message.text.replacingOccurrences(of: "\n", with: " ").prefix(24)) }
            current.updatedAt = max(current.updatedAt, message.date)
            try save(message, kind: "chat", id: message.id); try save(current, kind: "chat-session", id: current.id); try execute("COMMIT"); return current
        } catch { try? execute("ROLLBACK"); throw error }
    }
    public func commitSubmittedChat(_ user: PartnerChat, session: ChatSession) throws -> ChatSession {
        guard user.role == "user", user.sessionID == session.id else { throw MailError.message("The submitted message does not belong to this conversation.") }
        try execute("BEGIN IMMEDIATE")
        do {
            var current = try object(ChatSession.self, kind: "chat-session", id: session.id) ?? session
            if session.draftRevision >= current.draftRevision {
                current.input = session.input; current.materials = session.materials
                current.pinnedContext = session.pinnedContext; current.newWork = session.newWork
                current.draftRevision = session.draftRevision
            }
            if ["新对话", "New chat", "New conversation", "新しい会話", "新規チャット"].contains(current.title) {
                current.title = String(user.text.replacingOccurrences(of: "\n", with: " ").prefix(24))
            }
            current.updatedAt = max(current.updatedAt, user.date)
            try save(user, kind: "chat", id: user.id); try save(current, kind: "chat-session", id: current.id)
            try execute("COMMIT"); return current
        } catch { try? execute("ROLLBACK"); throw error }
    }
    public func commitMemories(_ values: [AgentMemory]) throws {
        try execute("BEGIN IMMEDIATE")
        do { for value in values { try save(value, kind: "agent-memory", id: value.id) }; try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }
    public func commitWorkingDraft(_ draft: ComposeDraft, artifact: AgentArtifact?) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            let existing = try object(ComposeDraft.self, kind: "draft", id: draft.id)
            let protected = ["sent", "queued", "sending", "uncertain"]
            guard !protected.contains(draft.state), existing.map({ !protected.contains($0.state) }) ?? true else { throw MailError.message("This draft is in the delivery workflow and cannot be overwritten by an editor.") }
            try save(draft, kind: "draft", id: draft.id)
            if let artifact { try save(artifact, kind: "agent-artifact", id: artifact.id) }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    private nonisolated static func initializeCloudJournal(_ db: OpaquePointer?) throws {
        func execute(_ sql: String) throws {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw MailError.message("Unable to initialize the local iCloud journal.") }
        }
        try execute("CREATE TABLE IF NOT EXISTS cloud_context(singleton INTEGER PRIMARY KEY CHECK(singleton=1),device TEXT NOT NULL,clock INTEGER NOT NULL,importing INTEGER NOT NULL DEFAULT 0)")
        try execute("INSERT OR IGNORE INTO cloud_context VALUES(1,'" + UUID().uuidString + "',0,0)")
        try execute("CREATE TABLE IF NOT EXISTS cloud_journal(kind TEXT NOT NULL,id TEXT NOT NULL,payload BLOB,clock INTEGER NOT NULL,device TEXT NOT NULL,dirty INTEGER NOT NULL DEFAULT 1,PRIMARY KEY(kind,id))")
        let included = CloudWorkspacePolicy.kinds.sorted().map { "'" + $0 + "'" }.joined(separator: ",")
        for (name, operation, row, payload) in [("insert", "INSERT", "NEW", "NEW.json"), ("update", "UPDATE", "NEW", "NEW.json"), ("delete", "DELETE", "OLD", "NULL")] {
            let sql = """
            CREATE TRIGGER IF NOT EXISTS cloud_object_\(name) AFTER \(operation) ON objects
            WHEN \(row).kind IN (\(included)) AND (SELECT importing FROM cloud_context WHERE singleton=1)=0
            BEGIN
              UPDATE cloud_context SET clock=max(clock+1,CAST((julianday('now')-2440587.5)*86400000 AS INTEGER)) WHERE singleton=1;
              INSERT INTO cloud_journal(kind,id,payload,clock,device,dirty)
              SELECT \(row).kind,\(row).id,\(payload),clock,device,1 FROM cloud_context WHERE singleton=1
              ON CONFLICT(kind,id) DO UPDATE SET payload=excluded.payload,clock=excluded.clock,device=excluded.device,dirty=1;
            END;
            """
            try execute(sql)
        }
    }
    public func seedCloudJournal() throws {
        try execute("BEGIN IMMEDIATE")
        do {
            for kind in CloudWorkspacePolicy.kinds {
                try execute("INSERT OR IGNORE INTO cloud_journal(kind,id,payload,clock,device,dirty) SELECT kind,id,json,max(clock,CAST((julianday('now')-2440587.5)*86400000 AS INTEGER)),device,1 FROM objects CROSS JOIN cloud_context WHERE kind=? AND singleton=1", [.text(kind)])
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    public func cloudChanges(dirtyOnly: Bool = true) throws -> [CloudWorkspaceChange] {
        let s = try statement("SELECT kind,id,payload,clock,device,dirty FROM cloud_journal" + (dirtyOnly ? " WHERE dirty=1" : "") + " ORDER BY clock,kind,id"); defer { sqlite3_finalize(s) }
        var result: [CloudWorkspaceChange] = []
        while sqlite3_step(s) == SQLITE_ROW {
            result.append(.init(kind: string(s, 0), objectID: string(s, 1), payload: sqlite3_column_type(s, 2) == SQLITE_NULL ? nil : bytes(s, 2), clock: sqlite3_column_int64(s, 3), deviceID: string(s, 4), dirty: sqlite3_column_int(s, 5) == 1))
        }
        return result
    }
    public func acknowledgeCloudChange(_ change: CloudWorkspaceChange) throws {
        try execute("UPDATE cloud_journal SET dirty=0 WHERE kind=? AND id=? AND clock=? AND device=?", [.text(change.kind), .text(change.objectID), .int(change.clock), .text(change.deviceID)])
    }
    /// Imports never echo, and an upload acknowledgement cannot clear a newer local edit.
    @discardableResult public func importCloudChange(_ incoming: CloudWorkspaceChange) throws -> Bool {
        guard CloudWorkspacePolicy.kinds.contains(incoming.kind), incoming.clock > 0, !incoming.deviceID.isEmpty else { throw MailError.message("Invalid iCloud record.") }
        let safe = try incoming.payload.map { try CloudWorkspacePolicy.preparedPayload($0, kind: incoming.kind) }
        if let safe, try CloudWorkspacePolicy.objectID(safe, kind: incoming.kind) != incoming.objectID { throw MailError.message("iCloud payload identity mismatch.") }
        try execute("BEGIN IMMEDIATE")
        do {
            let local = try cloudChanges(dirtyOnly: false).first { $0.kind == incoming.kind && $0.objectID == incoming.objectID }
            try execute("UPDATE cloud_context SET clock=max(clock,?) WHERE singleton=1", [.int(incoming.clock)])
            guard local == nil || local!.precedes(incoming) else { try execute("COMMIT"); return false }
            if let local, local.dirty, try local.payload.map({ try CloudWorkspacePolicy.preparedPayload($0, kind: local.kind) }) != safe {
                let conflict = CloudWorkspaceConflict(local: local, remote: incoming)
                try save(conflict, kind: "cloud-conflict", id: conflict.id)
            }
            try execute("UPDATE cloud_context SET importing=1 WHERE singleton=1")
            if let safe { try execute("INSERT OR REPLACE INTO objects(kind,id,json) VALUES(?,?,?)", [.text(incoming.kind), .text(incoming.objectID), .blob(safe)]) }
            else { try remove(kind: incoming.kind, id: incoming.objectID) }
            try execute("INSERT INTO cloud_journal(kind,id,payload,clock,device,dirty) VALUES(?,?,?,?,?,0) ON CONFLICT(kind,id) DO UPDATE SET payload=excluded.payload,clock=excluded.clock,device=excluded.device,dirty=0", [.text(incoming.kind), .text(incoming.objectID), safe.map(Value.blob) ?? .blob(Data()), .int(incoming.clock), .text(incoming.deviceID)])
            if safe == nil { try execute("UPDATE cloud_journal SET payload=NULL WHERE kind=? AND id=?", [.text(incoming.kind), .text(incoming.objectID)]) }
            try execute("UPDATE cloud_context SET importing=0 WHERE singleton=1")
            try execute("COMMIT"); return true
        } catch { try? execute("ROLLBACK"); throw error }
    }
    public func restoreCloudConflict(_ id: String) throws {
        guard let conflict = try object(CloudWorkspaceConflict.self, kind: "cloud-conflict", id: id) else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            if let data = conflict.localPayload { try execute("INSERT OR REPLACE INTO objects(kind,id,json) VALUES(?,?,?)", [.text(conflict.kind), .text(conflict.objectID), .blob(try CloudWorkspacePolicy.preparedPayload(data, kind: conflict.kind))]) }
            else { try remove(kind: conflict.kind, id: conflict.objectID) }
            try remove(kind: "cloud-conflict", id: id); try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
}
