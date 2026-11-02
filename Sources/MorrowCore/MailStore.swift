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
        CREATE TABLE IF NOT EXISTS message_projections(message TEXT PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,account TEXT NOT NULL,folder TEXT NOT NULL,date REAL NOT NULL,json BLOB NOT NULL,content_revision TEXT NOT NULL,profile_signature TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS projection_scope_date ON message_projections(account,folder,date DESC);
        CREATE INDEX IF NOT EXISTS projection_date ON message_projections(date DESC,message);
        -- Legacy FTS cache was never queried. Its unindexed ID made every
        -- message save scan the corpus. Keyword search uses messages.search.
        DROP TABLE IF EXISTS mail_fts;
        CREATE TABLE IF NOT EXISTS vectors(id TEXT PRIMARY KEY,message TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,chunk TEXT NOT NULL,vector BLOB NOT NULL,model TEXT NOT NULL,hash TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS vector_message ON vectors(message);
        CREATE INDEX IF NOT EXISTS vector_model_message ON vectors(model,message);
        CREATE TABLE IF NOT EXISTS index_state(message TEXT PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,hash TEXT NOT NULL,model TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS index_inputs(message TEXT PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,model TEXT NOT NULL,input_key TEXT NOT NULL,hash TEXT NOT NULL);
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
    /// Only the delivery owner may finish a claim. Content stays immutable;
    /// terminal state and SMTP acknowledgement commit before saving any copy.
    public func finishDraftDelivery(_ claimed: ComposeDraft, outcome: DraftDeliveryOutcome, error: String? = nil, now: Date = Date()) throws -> ComposeDraft {
        try finishDelivery(claimed, outcome: outcome, error: error, now: now, source: "smtp")
    }
    private func finishDelivery(_ claimed: ComposeDraft, outcome: DraftDeliveryOutcome, error: String?, now: Date, source: String) throws -> ComposeDraft {
        try execute("BEGIN IMMEDIATE")
        do {
            guard var current = try object(ComposeDraft.self, kind: "draft", id: claimed.id), current.accountID == claimed.accountID else { throw MailError.message("投递记录不存在或邮箱不匹配。") }
            if current.state == "sent" {
                guard outcome == .sent else { throw MailError.message("已确认发送的邮件不能退回发送队列。") }
            } else {
                guard current.state == claimed.state, current.updatedAt == claimed.updatedAt,
                      current.state == "sending" || (source == "synced-mail" && current.state == "uncertain") else { throw MailError.message("投递状态已经变化，未覆盖现有记录。") }
            }
            current.state = outcome == .cancelled ? "draft" : outcome.rawValue
            current.error = error; current.updatedAt = max(now, current.updatedAt)
            if outcome == .cancelled { current.scheduledAt = nil }
            if outcome == .sent, try object(DraftDeliveryReceipt.self, kind: "mail-delivery", id: current.id) == nil {
                try save(DraftDeliveryReceipt(id: current.id, accountID: current.accountID, messageID: "<" + current.id + "@morrow.local>", confirmedAt: now, source: source), kind: "mail-delivery", id: current.id)
            }
            try save(current, kind: "draft", id: current.id)
            try execute("COMMIT"); return current
        } catch { try? execute("ROLLBACK"); throw error }
    }
    /// Indexed RFC Message-ID lookup. Imported/local messages cannot establish
    /// delivery. A server Sent copy or a verified self-addressed Inbox copy can.
    public func recoverConfirmedDraftDeliveries(accounts: [MailAccount], folders: [MailFolder]) throws -> [ComposeDraft] {
        var recovered: [ComposeDraft] = []
        for draft in try load(ComposeDraft.self, kind: "draft") where ["sending", "uncertain"].contains(draft.state) {
            guard let account = accounts.first(where: { $0.id == draft.accountID && !$0.isDemo }) else { continue }
            let messageID = "<" + draft.id + "@morrow.local>"
            let s = try statement("SELECT json FROM messages WHERE account=? AND canonical=? AND uid>0 AND validity>0 LIMIT 20", [.text(account.id), .text(account.id + ":message:" + messageID)])
            let evidence: [MailMessage] = try {
                defer { sqlite3_finalize(s) }
                var values: [MailMessage] = []
                while sqlite3_step(s) == SQLITE_ROW { values.append(try decoder.decode(MailMessage.self, from: bytes(s, 0))) }
                return values
            }()
            func addresses(_ values: [MailAddress]) -> Set<String> { Set(values.map { $0.email.lowercased() }) }
            let expectedTo = addresses(draft.addresses(draft.to)), expectedCC = addresses(draft.addresses(draft.cc))
            let own = account.email.lowercased(), selfAddressed = addresses(draft.addresses(draft.to) + draft.addresses(draft.cc) + draft.addresses(draft.bcc)).contains(own)
            guard let mail = evidence.first(where: { mail in
                let role = folders.first { $0.accountID == account.id && $0.path == mail.folder }?.role
                return (role == "sent" || (role == "inbox" && selfAddressed)) && mail.messageID == messageID && mail.from.email.lowercased() == own && mail.subject == draft.subject && addresses(mail.to) == expectedTo && addresses(mail.cc) == expectedCC
            }) else { continue }
            recovered.append(try finishDelivery(draft, outcome: .sent, error: nil, now: mail.date, source: "synced-mail"))
        }
        return recovered
    }
    public func claimDraft(_ id: String, now: Date = Date()) throws -> ComposeDraft? {
        try execute("BEGIN IMMEDIATE")
        do {
            let s = try statement("SELECT json FROM objects WHERE kind='draft' AND id=?", [.text(id)])
            let data = sqlite3_step(s) == SQLITE_ROW ? bytes(s, 0) : nil; sqlite3_finalize(s)
            guard let data else { try execute("COMMIT"); return nil }
            var draft = try decoder.decode(ComposeDraft.self, from: data)
            guard draft.state == "queued", (draft.scheduledAt ?? .distantFuture) <= now else { try execute("COMMIT"); return nil }
            if draft.automaticResponse == true || draft.responderID != nil { try validateResponderDelivery(draft) }
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
    public func claimResponder(_ receipt: ResponderReceipt, retry: Bool = false) throws -> Bool {
        try execute("BEGIN IMMEDIATE")
        do {
            var receipt = receipt
            if let prior = try object(ResponderReceipt.self, kind: "responder-receipt", id: receipt.id) {
                guard retry, ["failed", "cancelled"].contains(prior.state), (prior.attempts ?? 1) < 3,
                      prior.draftID.flatMap({ try? object(ComposeDraft.self, kind: "draft", id: $0) }).map({ !["queued", "sending", "sent", "uncertain"].contains($0.state) }) ?? true else { try execute("COMMIT"); return false }
                receipt.attempts = (prior.attempts ?? 1) + 1
            }
            try save(receipt, kind: "responder-receipt", id: receipt.id); try execute("COMMIT"); return true
        } catch { try? execute("ROLLBACK"); throw error }
    }
    public func commitResponder(_ rule: MailResponder, receipt: ResponderReceipt, draft: ComposeDraft, event: PartnerEvent) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            guard receipt.agentVerified == true, receipt.sandboxRuntime == "anthropic-srt/0.0.81",
                  let current = try object(MailResponder.self, kind: "responder", id: rule.id), current.enabled, !current.archived, current.configurationFingerprint == receipt.ruleFingerprint else { throw MailError.message("响应器未完成沙箱 Agent 核对，或处理期间规则已变更，未提交回复。") }
            try save(rule, kind: "responder", id: rule.id); try save(receipt, kind: "responder-receipt", id: receipt.id); try save(draft, kind: "draft", id: draft.id)
            if draft.state == "queued" || draft.state == "sent" { try validateResponderDelivery(draft) }
            try save(event, kind: "event", id: event.id); try execute("COMMIT")
        }
        catch { try? execute("ROLLBACK"); throw error }
    }
    public func validateResponderDelivery(_ draft: ComposeDraft) throws {
        guard draft.automaticResponse == true, let responderID = draft.responderID, let sourceID = draft.responderSourceMailID,
              let rule = try object(MailResponder.self, kind: "responder", id: responderID),
              let account = try object(MailAccount.self, kind: "account", id: draft.accountID), account.enabled,
              rule.boundAccountFingerprint == ResponderPolicy.accountFingerprint(account),
              let receipt = try object(ResponderReceipt.self, kind: "responder-receipt", id: draft.id),
              receipt.responderID == responderID, receipt.mailID == sourceID, receipt.draftID == draft.id,
              receipt.agentVerified == true, receipt.sandboxRuntime == "anthropic-srt/0.0.81",
              receipt.ruleFingerprint == rule.configurationFingerprint,
              receipt.draftFingerprint == ResponderPolicy.draftFingerprint(draft),
              let mail = try message(sourceID), receipt.canonicalID == mail.canonicalID,
              receipt.sourceBodyVersion == mail.bodyVersion,
              ResponderPolicy.canSend(draft, rule: rule, mail: mail, allowLocalSource: account.isDemo),
              ResponderPolicy.sourceFailure(rule, mail: mail, raw: try rawHeader(mail), allowLocalSource: account.isDemo) == nil else {
            throw MailError.message("自动回复的来源、规则或正文已变化，投递已阻止。请重新核对响应器。")
        }
    }
    public func updateOpenUIState(_ values: [String: OpenUIJSON], id: String, revision: Int) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            if var page = try object(OpenUIInteraction.self, kind: "openui-interaction", id: id), page.completedAt == nil, page.stateRevision <= revision { page.values = values; page.stateRevision = revision; try save(page, kind: "openui-interaction", id: id) }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    private nonisolated static func feed(_ digest: inout SHA256, _ text: String) {
        var length = UInt64(text.utf8.count).bigEndian
        withUnsafeBytes(of: &length) { digest.update(bufferPointer: $0) }
        let fed = text.utf8.withContiguousStorageIfAvailable { storage -> Bool in
            let raw = UnsafeRawBufferPointer(storage)
            for start in stride(from: 0, to: raw.count, by: 64 * 1024) {
                digest.update(bufferPointer: UnsafeRawBufferPointer(rebasing: raw[start..<min(start + 64 * 1024, raw.count)]))
            }
            return true
        }
        if fed != true {
            var buffer = Data(); buffer.reserveCapacity(64 * 1024)
            for byte in text.utf8 { buffer.append(byte); if buffer.count == 64 * 1024 { digest.update(data: buffer); buffer.removeAll(keepingCapacity: true) } }
            if !buffer.isEmpty { digest.update(data: buffer) }
        }
    }
    private nonisolated static func digestString(_ digest: SHA256) -> String { digest.finalize().map { String(format: "%02x", $0) }.joined() }
    private nonisolated static func fileDigest(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var digest = SHA256()
        while let chunk = try file.read(upToCount: 1024 * 1024), !chunk.isEmpty { digest.update(data: chunk) }
        return digestString(digest)
    }
    private nonisolated static func bodyDigest(_ m: MailMessage) -> String {
        var digest = SHA256(); feed(&digest, "mail-body-v1"); feed(&digest, m.text); feed(&digest, m.html)
        for attachment in m.attachments where attachment.contentID != nil {
            for field in [attachment.contentID ?? "", attachment.mimeType, attachment.name, attachment.contentRevision ?? "unavailable:\(attachment.byteCount)"] { feed(&digest, field) }
        }
        return digestString(digest)
    }
    private nonisolated static func profileSignature(_ m: MailMessage) -> String {
        var digest = SHA256()
        for field in [m.accountID, m.subject, String(m.date.timeIntervalSince1970)] { feed(&digest, field) }
        for addresses in [[m.from], m.to, m.cc, m.bcc ?? [], m.replyTo] {
            feed(&digest, String(addresses.count))
            for address in addresses { feed(&digest, address.name); feed(&digest, address.email.lowercased()) }
        }
        return digestString(digest)
    }
    private func writeProjection(_ value: MailMessage) throws {
        var message = value
        if message.contentRevision == nil {
            for i in message.attachments.indices where message.attachments[i].contentID != nil && message.attachments[i].contentRevision == nil {
                if let path = message.attachments[i].storedPath { message.attachments[i].contentRevision = try? Self.fileDigest(URL(fileURLWithPath: path)) }
            }
            message.contentRevision = Self.bodyDigest(message)
        }
        try execute("INSERT INTO message_projections(message,account,folder,date,json,content_revision,profile_signature) VALUES(?,?,?,?,?,?,?) ON CONFLICT(message) DO UPDATE SET account=excluded.account,folder=excluded.folder,date=excluded.date,json=excluded.json,content_revision=excluded.content_revision,profile_signature=excluded.profile_signature", [.text(message.id), .text(message.accountID), .text(message.folder), .real(message.date.timeIntervalSince1970), .blob(try encoder.encode(MailMessageSummary(message: message))), .text(message.contentRevision!), .text(Self.profileSignature(message))])
    }
    /// Legacy bodies are read one bounded batch at a time. This table is a
    /// rebuildable cache, containing a short preview and metadata only.
    private func backfillProjections(account: String? = nil, folder: String? = nil) async throws {
        while true {
            try Task.checkCancellation()
            var sql = "SELECT m.json FROM messages m LEFT JOIN message_projections p ON p.message=m.id WHERE p.message IS NULL"
            var params: [Value] = []
            if let account { sql += " AND m.account=?"; params.append(.text(account)) }
            if let folder { sql += " AND m.folder=?"; params.append(.text(folder)) }
            sql += " ORDER BY m.id LIMIT 64"
            let statement = try statement(sql, params)
            var batch: [MailMessage] = []
            do {
                while true {
                    let code = sqlite3_step(statement); if code == SQLITE_DONE { break }
                    guard code == SQLITE_ROW else { throw databaseError() }
                    batch.append(try decoder.decode(MailMessage.self, from: bytes(statement, 0)))
                }
                sqlite3_finalize(statement)
            } catch { sqlite3_finalize(statement); throw error }
            if batch.isEmpty { return }
            try execute("BEGIN IMMEDIATE")
            do { for message in batch { try writeProjection(message) }; try execute("COMMIT") }
            catch { try? execute("ROLLBACK"); throw error }
            // No SQLite cursor or transaction crosses the suspension point.
            batch.removeAll(); await Task.yield()
        }
    }
    private func scanProjections(_ sql: String, _ params: [Value]) throws -> (values: [MailMessageSummary], invalidIDs: [String]) {
        let statement = try statement(sql, params); defer { sqlite3_finalize(statement) }
        var values: [MailMessageSummary] = [], invalidIDs: [String] = [], scanned = 0
        while true {
            let code = sqlite3_step(statement); if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw databaseError() }
            if scanned.isMultiple(of: 128) { try Task.checkCancellation() }; scanned += 1
            let id = string(statement, 0)
            if let value = try? decoder.decode(MailMessageSummary.self, from: bytes(statement, 1)), value.id == id, value.displayMessage.contentAvailability == .preview, value.displayMessage.text.count <= 300, value.displayMessage.html.isEmpty, value.displayMessage.raw.isEmpty, value.displayMessage.analysis?.evidenceText == nil, value.displayMessage.attachments.allSatisfy({ $0.data.isEmpty }) { values.append(value) }
            else { invalidIDs.append(id) }
        }
        return (values, invalidIDs)
    }
    public func messageSummaries(account: String? = nil, folder: String? = nil, limit: Int? = nil, offset: Int = 0) async throws -> [MailMessageSummary] {
        if let limit, limit <= 0 { return [] }
        try await backfillProjections(account: account, folder: folder)
        var sql = "SELECT message,json FROM message_projections"; var clauses: [String] = []; var params: [Value] = []
        if let account { clauses.append("account=?"); params.append(.text(account)) }
        if let folder { clauses.append("folder=?"); params.append(.text(folder)) }
        if !clauses.isEmpty { sql += " WHERE " + clauses.joined(separator: " AND ") }
        sql += " ORDER BY date DESC,message LIMIT ? OFFSET ?"
        params += [.int(Int64(limit ?? -1)), .int(Int64(max(0, offset)))]
        var first = try scanProjections(sql, params)
        if first.invalidIDs.isEmpty { return first.values }
        // Discard every first-generation value before reading any full body
        // or suspending. Retain only small IDs; there is no recursive retry.
        first.values.removeAll(keepingCapacity: false)
        for start in stride(from: 0, to: first.invalidIDs.count, by: 64) {
            try Task.checkCancellation()
            try execute("BEGIN IMMEDIATE")
            do {
                for index in start..<min(start + 64, first.invalidIDs.count) {
                    if var value = try message(first.invalidIDs[index]) { value.contentRevision = nil; try writeProjection(value) }
                }
                try execute("COMMIT")
            } catch { try? execute("ROLLBACK"); throw error }
            // One complete message at a time, never an array of full bodies.
            await Task.yield()
        }
        first.invalidIDs.removeAll(keepingCapacity: false)
        let verified = try scanProjections(sql, params)
        guard verified.invalidIDs.isEmpty else { throw MailError.message("邮件摘要缓存修复失败，仍有\(verified.invalidIDs.count)封摘要无效；已停止重试。") }
        return verified.values
    }
    /// Contact claims need complete text, but never HTML, MIME, file data, or
    /// duplicated analysis evidence. SQLite removes those fields per row.
    public func contactMessages(account: String? = nil, folder: String? = nil) async throws -> [MailMessage] {
        try await backfillProjections(account: account, folder: folder)
        var sql = "SELECT json_set(json_remove(CAST(m.json AS TEXT),'$.analysis.evidenceText'),'$.html','','$.raw','','$.contentAvailability','textOnly'),p.content_revision FROM messages m JOIN message_projections p ON p.message=m.id"
        var clauses: [String] = [], params: [Value] = []
        if let account { clauses.append("m.account=?"); params.append(.text(account)) }
        if let folder { clauses.append("m.folder=?"); params.append(.text(folder)) }
        if !clauses.isEmpty { sql += " WHERE " + clauses.joined(separator: " AND ") }; sql += " ORDER BY m.date DESC,m.id"
        let statement = try statement(sql, params); defer { sqlite3_finalize(statement) }
        var out: [MailMessage] = []
        while true {
            let code = sqlite3_step(statement); if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw databaseError() }
            var message = try decoder.decode(MailMessage.self, from: bytes(statement, 0)); message.contentRevision = string(statement, 1)
            for i in message.attachments.indices { message.attachments[i].data = Data() }; out.append(message)
        }
        return out
    }
    public func profileInventoryFingerprint() async throws -> String {
        try await backfillProjections()
        let statement = try statement("SELECT message,content_revision,profile_signature FROM message_projections ORDER BY message"); defer { sqlite3_finalize(statement) }
        var digest = SHA256(); Self.feed(&digest, "profile-inventory-v1")
        while true {
            let code = sqlite3_step(statement); if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw databaseError() }
            for column: Int32 in 0..<3 { Self.feed(&digest, string(statement, column)) }
        }
        return Self.digestString(digest)
    }

    @discardableResult public func upsert(_ value: MailMessage) throws -> MailMessage {
        guard value.contentAvailability == nil || value.contentAvailability == .complete else { throw MailError.message("邮件摘要不能覆盖完整邮件，请先读取正文。") }
        var m = value
        if !m.raw.isEmpty { try privateWrite(m.raw, to: rawURL(m.id)); m.raw = Data() }
        for i in m.attachments.indices where !m.attachments[i].data.isEmpty {
            let a = m.attachments[i]; let url = root.appendingPathComponent("attachments/" + a.id)
            try privateWrite(a.data, to: url); m.attachments[i].storedPath = url.path; m.attachments[i].byteCount = a.data.count; m.attachments[i].contentRevision = Self.hash(a.data); m.attachments[i].data = Data()
        }
        for i in m.attachments.indices where m.attachments[i].contentID != nil && m.attachments[i].contentRevision == nil {
            if let path = m.attachments[i].storedPath { m.attachments[i].contentRevision = try? Self.fileDigest(URL(fileURLWithPath: path)) }
        }
        m.contentRevision = Self.bodyDigest(m)
        let search = [m.subject, m.from.name, m.from.email, m.to.map(\.email).joined(separator: " "), m.text, m.note, m.analysis?.summary ?? "", m.labels.joined(separator: " ")].joined(separator: "\n")
        let ownsTransaction = sqlite3_get_autocommit(db) != 0
        if ownsTransaction { try execute("BEGIN IMMEDIATE") }
        do {
            try execute("INSERT INTO messages(id,account,folder,uid,validity,date,search,json,canonical) VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET account=excluded.account,folder=excluded.folder,uid=excluded.uid,validity=excluded.validity,date=excluded.date,search=excluded.search,json=excluded.json,canonical=excluded.canonical", [.text(m.id), .text(m.accountID), .text(m.folder), .int(Int64(m.uid)), .int(Int64(m.uidValidity)), .real(m.date.timeIntervalSince1970), .text(search), .blob(try encoder.encode(m)), .text(m.canonicalID)])
            try writeProjection(m)
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
    public func gmailBodyCandidates(account: String, messageID: String, destinationID: String, rawSize: UInt64) throws -> [MailMessage] {
        guard !messageID.isEmpty else { return [] }
        let canonical = account + ":message:" + messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = try statement("SELECT id FROM messages WHERE account=? AND canonical=? AND id<>? ORDER BY CASE WHEN upper(folder)='INBOX' THEN 0 ELSE 1 END,date DESC LIMIT 2", [.text(account), .text(canonical), .text(destinationID)])
        defer { sqlite3_finalize(query) }
        var ids: [String] = []
        while sqlite3_step(query) == SQLITE_ROW { ids.append(string(query, 0)) }
        let eligible = ids.filter { id in
            guard let info = try? FileManager.default.attributesOfItem(atPath: rawURL(id).path), info[.type] as? FileAttributeType == .typeRegular else { return false }
            return (info[.size] as? NSNumber)?.uint64Value == rawSize
        }
        return try eligible.compactMap { try message($0) }.filter { ($0.contentAvailability == nil || $0.contentAvailability == .complete) && $0.uid > 0 }
    }
    public func cachedGmailIdentity(account: MailAccount, message: MailMessage) throws -> GmailMessageIdentity? {
        let key = GmailMessageIdentity.lookupID(accountID: account.id, folder: message.folder, uid: message.uid, validity: message.uidValidity)
        guard let identity = try object(GmailMessageIdentity.self, kind: "mail-gmail-identity", id: key), identity.valid,
              identity.accountID == account.id, identity.folder == message.folder, identity.uid == message.uid, identity.validity == message.uidValidity,
              identity.accountFingerprint == MailFolderSyncCursor.fingerprint(account) else { return nil }
        return identity
    }
    public func cacheGmailIdentity(_ identity: GmailMessageIdentity, account: MailAccount) throws {
        guard identity.valid, identity.accountID == account.id else { throw MailError.message("Gmail身份不属于当前邮箱。") }
        var bound = identity; bound.accountFingerprint = MailFolderSyncCursor.fingerprint(account)
        try save(bound, kind: "mail-gmail-identity", id: bound.id)
    }
    /// Reuse is authorized by Gmail global identity and complete raw size, not
    /// by folder UID or RFC Message-ID alone. Separate hard-link paths preserve
    /// other aliases when one message or attachment is removed.
    public func reuseGmailBody(source: MailMessage, sourceIdentity: GmailMessageIdentity, destination: GmailMessageIdentity,
                               flags: MailSyncFlags, inventoryStarted: Date) throws -> MailMessage? {
        guard let latest = try message(source.id), latest.accountID == source.accountID, latest.bodyVersion == source.bodyVersion,
              latest.messageID.trimmingCharacters(in: .whitespacesAndNewlines) == source.messageID.trimmingCharacters(in: .whitespacesAndNewlines),
              latest.uid == source.uid, latest.uidValidity == source.uidValidity, latest.folder == source.folder else { return nil }
        guard sourceIdentity.valid, destination.valid, source.accountID == destination.accountID,
              sourceIdentity.accountID == source.accountID, sourceIdentity.folder == source.folder,
              sourceIdentity.uid == source.uid, sourceIdentity.validity == source.uidValidity,
              sourceIdentity.globalID == destination.globalID, sourceIdentity.messageID == destination.messageID,
              source.messageID.trimmingCharacters(in: .whitespacesAndNewlines) == destination.messageID,
              sourceIdentity.rawSize == destination.rawSize, source.id != destination.mailID,
              (source.contentAvailability == nil || source.contentAvailability == .complete),
              try message(destination.mailID) == nil, try object(MailDownloadJob.self, kind: "mail-download", id: destination.mailID) == nil else { return nil }
        let manager = FileManager.default, sourceRaw = rawURL(source.id), targetRaw = rawURL(destination.mailID)
        let ownedRoot = root.resolvingSymlinksInPath().path
        guard sourceRaw.resolvingSymlinksInPath().path.hasPrefix(ownedRoot + "/raw/"), targetRaw.resolvingSymlinksInPath().path.hasPrefix(ownedRoot + "/raw/"),
              let attributes = try? manager.attributesOfItem(atPath: sourceRaw.path), attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.uint64Value == destination.rawSize, !manager.fileExists(atPath: targetRaw.path) else { return nil }
        var alias = latest; alias.id = destination.mailID; alias.folder = destination.folder; alias.uid = destination.uid; alias.uidValidity = destination.validity; alias.raw = Data()
        if latest.localFlagModifiedAt.map({ $0 > inventoryStarted }) != true {
            alias.isRead = flags.read; alias.isStarred = flags.starred; alias.localFlagModifiedAt = nil
        }
        var created: [URL] = [], committed = false
        defer { if !committed { for file in created { try? manager.removeItem(at: file) } } }
        try Task.checkCancellation()
        try manager.linkItem(at: sourceRaw, to: targetRaw); created.append(targetRaw)
        for index in alias.attachments.indices {
            try Task.checkCancellation()
            let original = alias.attachments[index]
            guard original.remoteReference == nil else { return nil }
            alias.attachments[index].id = Self.hash(destination.mailID + ":attachment:" + String(index))
            if let stored = original.storedPath {
                let origin = URL(fileURLWithPath: stored).standardizedFileURL
                guard origin.path.hasPrefix(root.appendingPathComponent("attachments").standardizedFileURL.path + "/"),
                      origin.resolvingSymlinksInPath().path.hasPrefix(ownedRoot + "/attachments/"),
                      let info = try? manager.attributesOfItem(atPath: origin.path), info[.type] as? FileAttributeType == .typeRegular,
                      (info[.size] as? NSNumber)?.intValue == original.byteCount else { return nil }
                let target = root.appendingPathComponent("attachments/" + alias.attachments[index].id)
                guard target.resolvingSymlinksInPath().path.hasPrefix(ownedRoot + "/attachments/"), !manager.fileExists(atPath: target.path) else { return nil }
                try manager.linkItem(at: origin, to: target); created.append(target)
                alias.attachments[index].storedPath = target.path; alias.attachments[index].data = Data()
            } else if original.data.isEmpty && original.byteCount > 0 { return nil }
        }
        let saved = try upsert(alias); committed = true; return saved
    }
    private enum StoredMailFlag: String { case read = "isRead", star = "isStarred" }
    /// Only changed server flags reach this path. A local edit made after the
    /// inventory began wins, checked in the same transaction as the update.
    /// Raw MIME, body revisions, FTS and vectors are never rewritten.
    public func applyRemoteFlagStates(_ updates: [MailRemoteFlagUpdate], inventoryStarted: Date) throws -> Int {
        guard !updates.isEmpty else { return 0 }
        guard inventoryStarted.timeIntervalSinceReferenceDate.isFinite,
              updates.allSatisfy({ $0.overrideModifiedAt?.timeIntervalSinceReferenceDate.isFinite ?? true }) else { throw MailError.message("同步标记时间无效。") }
        try execute("BEGIN IMMEDIATE")
        do {
            let changed = try writeRemoteFlagStates(updates, inventoryStarted: inventoryStarted)
            try execute("COMMIT"); return changed
        } catch { try? execute("ROLLBACK"); throw error }
    }
    private func writeRemoteFlagStates(_ updates: [MailRemoteFlagUpdate], inventoryStarted: Date) throws -> Int {
        var changed = 0
        for update in updates {
            try Task.checkCancellation()
            let flags = "'$.isRead',json(?),'$.isStarred',json(?)"
            var values: [Value] = [.text(update.read ? "true" : "false"), .text(update.starred ? "true" : "false")]
            var extra = ""
            if let modified = update.overrideModifiedAt { extra = ",'$.localFlagModifiedAt',?"; values.append(.real(modified.timeIntervalSinceReferenceDate)) }
            try execute("UPDATE messages SET json=json_set(CAST(json AS TEXT)," + flags + extra + ") WHERE id=? AND coalesce(json_extract(CAST(json AS TEXT),'$.localFlagModifiedAt'),-1e99)<=? AND (json_extract(CAST(json AS TEXT),'$.isRead')<>? OR json_extract(CAST(json AS TEXT),'$.isStarred')<>?)", values + [.text(update.id), .real(inventoryStarted.timeIntervalSinceReferenceDate), .int(update.read ? 1 : 0), .int(update.starred ? 1 : 0)])
            guard sqlite3_changes(db) > 0 else { continue }
            changed += 1
            try execute("DELETE FROM message_projections WHERE message=? AND NOT json_valid(json)", [.text(update.id)])
            let projectionFlags = "'$.projectedMessage.isRead',json(?),'$.projectedMessage.isStarred',json(?)"
            let projectionExtra = update.overrideModifiedAt == nil ? "" : ",'$.projectedMessage.localFlagModifiedAt',?"
            try execute("UPDATE message_projections SET json=json_set(CAST(json AS TEXT)," + projectionFlags + projectionExtra + ") WHERE message=?", values + [.text(update.id)])
        }
        return changed
    }
    /// Apply metadata and the server cursor atomically, before history bodies
    /// are downloaded. A stopped download resumes from known missing UIDs.
    public func commitMailSyncInventory(_ inventory: MailSyncInventory, account: MailAccount, folder: String,
                                        updates: [MailRemoteFlagUpdate], inventoryStarted: Date) throws -> [String] {
        guard inventoryStarted.timeIntervalSinceReferenceDate.isFinite,
              updates.allSatisfy({ $0.overrideModifiedAt?.timeIntervalSinceReferenceDate.isFinite ?? true }) else { throw MailError.message("同步标记时间无效。") }
        try execute("BEGIN IMMEDIATE")
        do {
            var removedFiles: [URL] = []
            // Queued MIME processing reads these refreshed flags at commit.
            for var job in try queuedMailDownloads() where job.accountID == account.id && job.folder == folder {
                if job.validity != inventory.validity || !inventory.presentUIDs.contains(job.uid) {
                    try remove(kind: "mail-download", id: job.id)
                    if try messageSummaries(ids: [job.id]).isEmpty { removedFiles.append(rawURL(job.id)) }
                    continue
                }
                if let flags = inventory.flags[job.uid] {
                    job.read = flags.read; job.starred = flags.starred; job.inventoryStarted = inventoryStarted
                    try save(job, kind: "mail-download", id: job.id)
                }
            }
            _ = try writeRemoteFlagStates(updates, inventoryStarted: inventoryStarted)
            var deleted: [String] = []
            for old in try syncRecords(account: account.id, folder: folder) where old.uid > 0 && (old.uidValidity != inventory.validity || !inventory.presentUIDs.contains(old.uid)) {
                try Task.checkCancellation()
                if let mail = try message(old.id) {
                    for attachment in mail.attachments {
                        if let path = attachment.storedPath { removedFiles.append(URL(fileURLWithPath: path)) }
                        try remove(kind: "attachment-text", id: attachment.id)
                    }
                }
                removedFiles.append(rawURL(old.id))
                try execute("DELETE FROM messages WHERE id=?", [.text(old.id)]); deleted.append(old.id)
            }
            let cursor = inventory.cursor(account: account, folder: folder)
            try save(cursor, kind: "mail-sync-cursor", id: cursor.id)
            try execute("COMMIT")
            for url in removedFiles { try? FileManager.default.removeItem(at: url) }
            return deleted
        } catch { try? execute("ROLLBACK"); throw error }
    }
    private func flagStates(ids: Set<String>, flag: StoredMailFlag, includeCanonicalCopies: Bool) throws -> [String: Bool] {
        let ordered = ids.sorted(); var states: [String: Bool] = [:]
        let path = "$." + flag.rawValue
        for start in stride(from: 0, to: ordered.count, by: 400) {
            let chunk = Array(ordered[start..<min(start + 400, ordered.count)])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let parameters = chunk.map(Value.text)
            var queries = ["SELECT id,json_extract(CAST(json AS TEXT),'" + path + "'),json_type(CAST(json AS TEXT)),json_type(CAST(json AS TEXT),'" + path + "') FROM messages WHERE id IN (" + placeholders + ")"]
            if includeCanonicalCopies {
                queries.append("SELECT DISTINCT m.id,json_extract(CAST(m.json AS TEXT),'" + path + "'),json_type(CAST(m.json AS TEXT)),json_type(CAST(m.json AS TEXT),'" + path + "') FROM messages anchor JOIN messages m ON m.account=anchor.account AND m.canonical=anchor.canonical WHERE anchor.id IN (" + placeholders + ") AND anchor.canonical<>''")
            }
            for query in queries {
                let s = try statement(query, parameters); defer { sqlite3_finalize(s) }
                while true {
                    let code = sqlite3_step(s); if code == SQLITE_DONE { break }
                    guard code == SQLITE_ROW else { throw databaseError() }
                    guard string(s, 2) == "object", ["true", "false"].contains(string(s, 3)) else { throw MailError.message("邮件标记状态数据损坏。") }
                    states[string(s, 0)] = sqlite3_column_int(s, 1) != 0
                }
            }
        }
        return states
    }
    private func writeFlagState(ids: Set<String>, flag: StoredMailFlag, enabled: Bool, modifiedAt: Date) throws {
        let ordered = ids.sorted(), boolean = enabled ? "true" : "false", path = "$." + flag.rawValue
        for start in stride(from: 0, to: ordered.count, by: 399) {
            let chunk = Array(ordered[start..<min(start + 399, ordered.count)])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            try execute("UPDATE messages SET json=json_set(CAST(json AS TEXT),'" + path + "',json('" + boolean + "'),'$.localFlagModifiedAt',?) WHERE id IN (" + placeholders + ")", [.real(modifiedAt.timeIntervalSinceReferenceDate)] + chunk.map(Value.text))
            try execute("DELETE FROM message_projections WHERE NOT json_valid(json) AND message IN (" + placeholders + ")", chunk.map(Value.text))
            try execute("UPDATE message_projections SET json=json_set(CAST(json AS TEXT),'$.projectedMessage." + flag.rawValue + "',json('" + boolean + "'),'$.projectedMessage.localFlagModifiedAt',?) WHERE message IN (" + placeholders + ")", [.real(modifiedAt.timeIntervalSinceReferenceDate)] + chunk.map(Value.text))
        }
    }
    private func setFlagState(ids: Set<String>, flag: StoredMailFlag, enabled: Bool, modifiedAt: Date, includeCanonicalCopies: Bool) throws -> [MailFlagStateChange] {
        guard !ids.isEmpty else { return [] }
        guard modifiedAt.timeIntervalSinceReferenceDate.isFinite else { throw MailError.message("本地修改时间无效。") }
        try execute("BEGIN IMMEDIATE")
        do {
            let states = try flagStates(ids: ids, flag: flag, includeCanonicalCopies: includeCanonicalCopies)
            let changes = states.filter { $0.value != enabled }.map { MailFlagStateChange(id: $0.key, wasEnabled: $0.value) }.sorted { $0.id < $1.id }
            try writeFlagState(ids: Set(changes.map(\.id)), flag: flag, enabled: enabled, modifiedAt: modifiedAt)
            try execute("COMMIT"); return changes
        } catch { try? execute("ROLLBACK"); throw error }
    }
    private func restoreFlagState(changes: [MailFlagStateChange], flag: StoredMailFlag, modifiedAt: Date) throws -> Set<String> {
        guard !changes.isEmpty else { return [] }
        guard modifiedAt.timeIntervalSinceReferenceDate.isFinite else { throw MailError.message("本地修改时间无效。") }
        var desired: [String: Bool] = [:]
        for change in changes {
            if let previous = desired[change.id], previous != change.wasEnabled { throw MailError.message("邮件恢复状态冲突。") }
            desired[change.id] = change.wasEnabled
        }
        try execute("BEGIN IMMEDIATE")
        do {
            let current = try flagStates(ids: Set(desired.keys), flag: flag, includeCanonicalCopies: false)
            var restored = Set<String>()
            for enabled in [false, true] {
                let ids = Set(desired.compactMap { id, value in value == enabled && current[id] != nil && current[id] != enabled ? id : nil })
                try writeFlagState(ids: ids, flag: flag, enabled: enabled, modifiedAt: modifiedAt); restored.formUnion(ids)
            }
            try execute("COMMIT"); return restored
        } catch { try? execute("ROLLBACK"); throw error }
    }
    public func setReadState(ids: Set<String>, read: Bool, modifiedAt: Date = Date(), includeCanonicalCopies: Bool = false) throws -> [MailReadStateChange] {
        try setFlagState(ids: ids, flag: .read, enabled: read, modifiedAt: modifiedAt, includeCanonicalCopies: includeCanonicalCopies).map { MailReadStateChange(id: $0.id, wasRead: $0.wasEnabled) }
    }
    public func restoreReadState(changes: [MailReadStateChange], modifiedAt: Date = Date()) throws -> Set<String> {
        try restoreFlagState(changes: changes.map { MailFlagStateChange(id: $0.id, wasEnabled: $0.wasRead) }, flag: .read, modifiedAt: modifiedAt)
    }
    public func setStarState(ids: Set<String>, starred: Bool, modifiedAt: Date = Date(), includeCanonicalCopies: Bool = false) throws -> [MailFlagStateChange] {
        try setFlagState(ids: ids, flag: .star, enabled: starred, modifiedAt: modifiedAt, includeCanonicalCopies: includeCanonicalCopies)
    }
    public func restoreStarState(changes: [MailFlagStateChange], modifiedAt: Date = Date()) throws -> Set<String> {
        try restoreFlagState(changes: changes, flag: .star, modifiedAt: modifiedAt)
    }
    private func labelStates(ids: Set<String>, includeCanonicalCopies: Bool) throws -> [String: [String]] {
        let ordered = ids.sorted(); var states: [String: [String]] = [:]
        for start in stride(from: 0, to: ordered.count, by: 400) {
            let chunk = Array(ordered[start..<min(start + 400, ordered.count)])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            var queries = ["SELECT id,json_extract(CAST(json AS TEXT),'$.labels'),json_type(CAST(json AS TEXT)),json_type(CAST(json AS TEXT),'$.labels') FROM messages WHERE id IN (" + placeholders + ")"]
            if includeCanonicalCopies { queries.append("SELECT DISTINCT m.id,json_extract(CAST(m.json AS TEXT),'$.labels'),json_type(CAST(m.json AS TEXT)),json_type(CAST(m.json AS TEXT),'$.labels') FROM messages anchor JOIN messages m ON m.account=anchor.account AND m.canonical=anchor.canonical WHERE anchor.id IN (" + placeholders + ") AND anchor.canonical<>''") }
            for query in queries {
                let statement = try statement(query, chunk.map(Value.text)); defer { sqlite3_finalize(statement) }
                while true {
                    let code = sqlite3_step(statement); if code == SQLITE_DONE { break }
                    guard code == SQLITE_ROW else { throw databaseError() }
                    guard string(statement, 2) == "object", string(statement, 3) == "array" else { throw MailError.message("邮件标签数据损坏。") }
                    states[string(statement, 0)] = try decoder.decode([String].self, from: Data(string(statement, 1).utf8))
                }
            }
        }
        return states
    }
    /// Appending labels updates only metadata. SQLite owns the original body
    /// throughout; Swift retains previous tag arrays for the bounded undo UI.
    public func addLabel(ids: Set<String>, label: String, includeCanonicalCopies: Bool = true) throws -> [MailLabelStateChange] {
        guard !ids.isEmpty else { return [] }
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { throw MailError.message("标签不能为空。") }
        try execute("BEGIN IMMEDIATE")
        do {
            let states = try labelStates(ids: ids, includeCanonicalCopies: includeCanonicalCopies)
            let changes = states.filter { !$0.value.contains(label) }.map { MailLabelStateChange(id: $0.key, labels: $0.value) }.sorted { $0.id < $1.id }
            let ordered = changes.map(\.id)
            for start in stride(from: 0, to: ordered.count, by: 398) {
                let chunk = Array(ordered[start..<min(start + 398, ordered.count)])
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                try execute("UPDATE messages SET json=json_insert(CAST(json AS TEXT),'$.labels[#]',?),search=search || char(10) || ? WHERE id IN (" + placeholders + ")", [.text(label), .text(label)] + chunk.map(Value.text))
                try execute("DELETE FROM message_projections WHERE NOT json_valid(json) AND message IN (" + placeholders + ")", chunk.map(Value.text))
                try execute("UPDATE message_projections SET json=json_insert(CAST(json AS TEXT),'$.projectedMessage.labels[#]',?) WHERE message IN (" + placeholders + ")", [.text(label)] + chunk.map(Value.text))
            }
            try execute("COMMIT"); return changes
        } catch { try? execute("ROLLBACK"); throw error }
    }
    public func messages(account: String? = nil, folder: String? = nil) throws -> [MailMessage] {
        var sql = "SELECT m.json,p.content_revision FROM messages m LEFT JOIN message_projections p ON p.message=m.id"; var clauses: [String] = []; var params: [Value] = []
        if let account { clauses.append("m.account=?"); params.append(.text(account)) }
        if let folder { clauses.append("m.folder=?"); params.append(.text(folder)) }
        if !clauses.isEmpty { sql += " WHERE " + clauses.joined(separator: " AND ") }; sql += " ORDER BY m.date DESC"
        let s = try statement(sql, params); defer { sqlite3_finalize(s) }; var out: [MailMessage] = []
        while sqlite3_step(s) == SQLITE_ROW { var m = try decoder.decode(MailMessage.self, from: bytes(s, 0)); if sqlite3_column_type(s, 1) != SQLITE_NULL { m.contentRevision = string(s, 1) }; out.append(m) }; return out
    }
    public func message(_ id: String) throws -> MailMessage? {
        let s = try statement("SELECT m.json,p.content_revision FROM messages m LEFT JOIN message_projections p ON p.message=m.id WHERE m.id=?", [.text(id)]); defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_ROW else { return nil }
        var m = try decoder.decode(MailMessage.self, from: bytes(s, 0))
        if sqlite3_column_type(s, 1) != SQLITE_NULL { m.contentRevision = string(s, 1) }; return m
    }
    /// One bounded, read-only lookup for an agent's selected evidence batch.
    public func messages(ids: [String]) throws -> [MailMessage] {
        guard ids.count <= AgentAnswerBudget.maximumBatchMails else { throw MailError.message("一次最多读取12封邮件。") }
        var seen = Set<String>(); let selected = ids.filter { seen.insert($0).inserted }
        guard !selected.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: selected.count).joined(separator: ",")
        let query = try statement("SELECT m.json,p.content_revision FROM messages m LEFT JOIN message_projections p ON p.message=m.id WHERE m.id IN (" + placeholders + ")", selected.map(Value.text))
        defer { sqlite3_finalize(query) }
        var result: [String: MailMessage] = [:]
        while sqlite3_step(query) == SQLITE_ROW {
            try Task.checkCancellation()
            var mail = try decoder.decode(MailMessage.self, from: bytes(query, 0))
            if sqlite3_column_type(query, 1) != SQLITE_NULL { mail.contentRevision = string(query, 1) }
            result[mail.id] = mail
        }
        return selected.compactMap { result[$0] }
    }
    /// Commit a server-confirmed MOVE using the complete cached original.
    /// COPYUID is authoritative; no destination-wide inventory/body fetch is needed.
    public func commitMovedMessage(source: MailMessage, destination: MailFolder, receipt: MailMoveReceipt?, localOnly: Bool = false) throws -> MailMessage {
        guard let current = try message(source.id), current.accountID == source.accountID,
              current.folder == source.folder, current.uid == source.uid, current.uidValidity == source.uidValidity,
              current.contentAvailability == nil || current.contentAvailability == .complete else { throw MailError.message("邮件位置已变化或正文不完整，未覆盖本机记录。") }
        let targetID = localOnly ? current.id : receipt.flatMap { receipt in
            receipt.destinationValidity.flatMap { validity in receipt.destinationUID.map { current.accountID + ":" + destination.path + ":" + String(validity) + ":" + String($0) } }
        }
        let target = try targetID.flatMap { try message($0) }
        let prepared = try MailMovePersistence.prepare(source: current, target: target, destination: destination, receipt: receipt, localOnly: localOnly, root: root)
        try execute("BEGIN IMMEDIATE")
        do {
            let saved = try upsert(prepared.message)
            if saved.id != current.id {
                let indexed = try statement("SELECT 1 FROM vectors WHERE message=? LIMIT 1", [.text(current.id)])
                let preserveVectors = sqlite3_step(indexed) == SQLITE_ROW; sqlite3_finalize(indexed)
                if preserveVectors {
                    try execute("DELETE FROM vectors WHERE message=?", [.text(saved.id)])
                    try execute("UPDATE vectors SET message=? WHERE message=?", [.text(saved.id), .text(current.id)])
                    try execute("INSERT OR REPLACE INTO index_state(message,hash,model) SELECT ?,hash,model FROM index_state WHERE message=?", [.text(saved.id), .text(current.id)])
                    try execute("INSERT OR REPLACE INTO index_inputs(message,model,input_key,hash) SELECT ?,model,input_key,hash FROM index_inputs WHERE message=?", [.text(saved.id), .text(current.id)])
                }
                try remove(kind: "mail-download", id: current.id)
                try execute("DELETE FROM messages WHERE id=?", [.text(current.id)])
            }
            try execute("COMMIT")
            if saved.id != current.id { cleanupRemovedMessageFiles(current) }
            return saved
        } catch { try? execute("ROLLBACK"); prepared.rollbackFiles(); throw error }
    }
    public func deleteMessage(_ id: String) throws {
        let cleanupNow = sqlite3_get_autocommit(db) != 0
        let removed = try message(id)
        try execute("DELETE FROM messages WHERE id=?", [.text(id)])
        if cleanupNow, let removed { cleanupRemovedMessageFiles(removed) }
    }
    private func cleanupRemovedMessageFiles(_ removed: MailMessage) {
        try? FileManager.default.removeItem(at: rawURL(removed.id))
        // Header projections contain attachment paths without full body blobs.
        // Missing legacy projections make cleanup conservative, never destructive.
        guard let absent = try? statement("SELECT 1 FROM messages m LEFT JOIN message_projections p ON p.message=m.id WHERE p.message IS NULL LIMIT 1") else { return }
        let legacy = sqlite3_step(absent) == SQLITE_ROW; sqlite3_finalize(absent)
        guard !legacy else { return }
        for attachment in removed.attachments {
            guard let query = try? statement("SELECT 1 FROM message_projections p,json_each(p.json,'$.projectedMessage.attachments') a WHERE json_extract(a.value,'$.id')=? OR json_extract(a.value,'$.storedPath')=? LIMIT 1", [.text(attachment.id), .text(attachment.storedPath ?? "")]) else { continue }
            let status = sqlite3_step(query); sqlite3_finalize(query)
            guard status == SQLITE_DONE else { continue }
            if let path = attachment.storedPath { try? FileManager.default.removeItem(atPath: path) }
            try? remove(kind: "attachment-text", id: attachment.id)
        }
    }
    public func deleteAccount(_ id: String) throws {
        for cursor in try load(MailFolderSyncCursor.self, kind: "mail-sync-cursor") where cursor.accountID == id { try remove(kind: "mail-sync-cursor", id: cursor.id) }
        for job in try queuedMailDownloads() where job.accountID == id { try discardQueuedMailDownload(job) }
        for record in try syncRecords(account: id, folder: nil) { try deleteMessage(record.id) }
        try remove(kind: "account", id: id)
        for f in try load(MailFolder.self, kind: "folder") where f.accountID == id { try remove(kind: "folder", id: f.id) }
    }
    public func rawData(_ message: MailMessage) throws -> Data { message.raw.isEmpty ? try Data(contentsOf: rawURL(message.id)) : message.raw }
    public func queuedMailDownloads() throws -> [MailDownloadJob] {
        let jobs = try load(MailDownloadJob.self, kind: "mail-download").sorted { $0.downloadedAt < $1.downloadedAt }
        var valid: [MailDownloadJob] = []
        for job in jobs {
            let attributes = try? FileManager.default.attributesOfItem(atPath: rawURL(job.id).path)
            if attributes?[.type] as? FileAttributeType == .typeRegular,
               (attributes?[.size] as? NSNumber)?.intValue == job.byteCount, job.byteCount > 0 {
                valid.append(job)
            } else {
                // An interrupted/lost cache cannot reserve this UID forever.
                // Completed message rows remain intact; missing bodies become
                // eligible for the next incremental download.
                try discardQueuedMailDownload(job)
            }
        }
        return valid
    }
    public func mailDownloadQueueState() throws -> MailDownloadQueueState {
        let jobs = try queuedMailDownloads(); return .init(count: jobs.count, bytes: jobs.reduce(0) { $0 + $1.byteCount })
    }
    @discardableResult public func queueMailDownload(_ raw: Data, job: MailDownloadJob) throws -> Bool {
        guard raw.count == job.byteCount, raw.count > 0, raw.count <= 64 * 1024 * 1024, job.uid > 0 else { throw MailError.message("下载邮件数据与任务不一致。") }
        if try object(MailDownloadJob.self, kind: "mail-download", id: job.id) != nil || !messageSummaries(ids: [job.id]).isEmpty { return false }
        let state = try mailDownloadQueueState()
        guard state.count < MailDownloadJob.maximumPending, raw.count <= MailDownloadJob.maximumPendingBytes - state.bytes else { throw MailError.message("邮件加工队列已达到缓存预算。") }
        try privateWrite(raw, to: rawURL(job.id)); try save(job, kind: "mail-download", id: job.id); return true
    }
    public func commitDownloadedMail(_ value: MailMessage, job: MailDownloadJob) throws -> MailMessage? {
        guard value.id == job.id, value.accountID == job.accountID, value.folder == job.folder, value.uid == job.uid, value.uidValidity == job.validity else { throw MailError.message("加工结果不属于下载来源。") }
        guard let latest = try object(MailDownloadJob.self, kind: "mail-download", id: job.id) else { return nil }
        var mail = value; mail.raw = Data()
        if latest.inventoryStarted > job.inventoryStarted && (mail.localFlagModifiedAt.map { $0 <= latest.inventoryStarted } ?? true) {
            mail.isRead = latest.read; mail.isStarred = latest.starred
        }
        try execute("BEGIN IMMEDIATE")
        do { let saved = try upsert(mail); try remove(kind: "mail-download", id: job.id); try execute("COMMIT"); return saved }
        catch { try? execute("ROLLBACK"); throw error }
    }
    public func discardQueuedMailDownload(_ job: MailDownloadJob) throws {
        try remove(kind: "mail-download", id: job.id)
        if try messageSummaries(ids: [job.id]).isEmpty { try? FileManager.default.removeItem(at: rawURL(job.id)) }
    }
    public func rawHeader(_ message: MailMessage) throws -> Data {
        if !message.raw.isEmpty { return Data(message.raw.prefix(65536)) }
        let handle = try FileHandle(forReadingFrom: rawURL(message.id)); defer { try? handle.close() }
        return try handle.read(upToCount: 65536) ?? Data()
    }
    public func attachmentData(_ attachment: MailAttachment, maximumBytes: Int? = nil) throws -> Data {
        if let maximumBytes, max(attachment.byteCount, attachment.data.count) > maximumBytes { throw MailError.message("附件超过读取大小限制。") }
        if !attachment.data.isEmpty { return attachment.data }
        guard let path = attachment.storedPath else { return Data() }
        let url = URL(fileURLWithPath: path)
        if let maximumBytes { return try BoundedFileReader.read(url, maximumBytes: maximumBytes) }
        return try Data(contentsOf: url)
    }
    public func hydrate(_ message: MailMessage) throws -> MailMessage {
        var m = message; m.raw = (try? rawData(m)) ?? Data(); for i in m.attachments.indices { m.attachments[i].data = try attachmentData(m.attachments[i]) }; return m
    }
    public func rawURL(_ id: String) -> URL { root.appendingPathComponent("raw/" + Self.hash(id) + ".eml") }
    private func privateWrite(_ data: Data, to url: URL) throws { try data.write(to: url, options: .atomic); try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
    public nonisolated static func hash(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    public nonisolated static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    public func keywordSearch(_ query: String, limit: Int = 60, allowedIDs: Set<String>? = nil) async throws -> [SearchHit] {
        if allowedIDs?.isEmpty == true { return [] }
        guard limit > 0 else { return [] }
        let parsed = MailQuery(query)
        var scope = allowedIDs
        if parsed.hasFilters {
            scope = Set(try await messageSummaries().filter { (allowedIDs?.contains($0.id) ?? true) && parsed.matches($0.displayMessage) }.map(\.id))
            if scope?.isEmpty == true { return [] }
        }
        let tokens = parsed.text.split(whereSeparator: \.isWhitespace).map(String.init)
        if tokens.isEmpty && !parsed.hasFilters { return [] }
        struct Candidate { var id: String; var canonical: String; var folder: String; var score: Float }
        let clauses = tokens.isEmpty ? "1" : tokens.map { _ in "instr(lower(search),lower(?))>0" }.joined(separator: " OR ")
        let sqlLimit = scope == nil ? " LIMIT ?" : ""
        let bindings = tokens.map(Value.text) + (scope == nil ? [.int(Int64(limit * 4))] : [])
        let s = try statement("SELECT id,search,canonical,folder FROM messages WHERE \(clauses) ORDER BY date DESC" + sqlLimit, bindings)
        var candidates: [Candidate] = []
        do {
            while true {
                let code = sqlite3_step(s); if code == SQLITE_DONE { break }
                guard code == SQLITE_ROW else { throw databaseError() }
                let id = string(s, 0); guard scope?.contains(id) ?? true else { continue }
                let body = string(s, 1).lowercased()
                let score = tokens.isEmpty ? 1 : Float(tokens.filter { body.contains($0.lowercased()) }.count) / Float(tokens.count)
                let canonical = string(s, 2)
                candidates.append(Candidate(id: id, canonical: canonical.isEmpty ? id : canonical, folder: string(s, 3), score: score))
            }
            sqlite3_finalize(s)
        } catch { sqlite3_finalize(s); throw error }
        // Rank and deduplicate small metadata before reading any body. Preserve
        // the inbox representative used by the previous search implementation.
        var order: [String] = [], best: [String: Candidate] = [:]
        for candidate in candidates.sorted(by: { $0.score > $1.score }) {
            if best[candidate.canonical] == nil { order.append(candidate.canonical); best[candidate.canonical] = candidate }
            else if candidate.folder == "INBOX" { best[candidate.canonical] = candidate }
        }
        return try order.prefix(limit).compactMap { key in
            guard let candidate = best[key], let mail = try message(candidate.id) else { return nil }
            return SearchHit(message: mail, score: candidate.score, method: parsed.hasFilters ? "条件检索" : "关键词")
        }
    }
    private func deduplicate(_ values: [SearchHit], limit: Int) -> [SearchHit] {
        var ordered: [String] = []; var best: [String: SearchHit] = [:]
        for hit in values { let key = hit.message.canonicalID; if best[key] == nil { ordered.append(key); best[key] = hit } else if hit.message.folder == "INBOX" { best[key] = hit } }
        return ordered.prefix(limit).compactMap { best[$0] }
    }
    public func isIndexed(_ id: String, hash: String, model: String) throws -> Bool {
        let s = try statement("SELECT 1 FROM index_state WHERE message=? AND hash=? AND model=?", [.text(id), .text(hash), .text(model)]); defer { sqlite3_finalize(s) }; return sqlite3_step(s) == SQLITE_ROW
    }
    public func verifiedIndexInputs(model: String, ids: Set<String>? = nil) throws -> [String: String] {
        if ids?.isEmpty == true { return [:] }
        var inputs: [String: String] = [:]
        let ordered = ids?.sorted()
        let chunks: [[String]?] = ordered.map { values in stride(from: 0, to: values.count, by: 400).map { Array(values[$0..<min($0 + 400, values.count)]) } } ?? [nil]
        for chunk in chunks {
            let clause = chunk.map { " AND v.message IN (" + Array(repeating: "?", count: $0.count).joined(separator: ",") + ")" } ?? ""
            let s = try statement("SELECT v.message,v.input_key FROM index_inputs v JOIN index_state i ON i.message=v.message AND i.model=v.model AND i.hash=v.hash WHERE v.model=?" + clause, [.text(model)] + (chunk ?? []).map(Value.text))
            defer { sqlite3_finalize(s) }
            while true {
                let code = sqlite3_step(s); if code == SQLITE_DONE { break }
                guard code == SQLITE_ROW else { throw databaseError() }
                inputs[string(s, 0)] = string(s, 1)
            }
        }
        return inputs
    }
    public func messageSummaries(ids: Set<String>) throws -> [MailMessageSummary] {
        let ordered = ids.sorted(); var values: [MailMessageSummary] = []
        for start in stride(from: 0, to: ordered.count, by: 128) {
            let chunk = Array(ordered[start..<min(start + 128, ordered.count)])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let scan = try scanProjections("SELECT message,json FROM message_projections WHERE message IN (" + placeholders + ")", chunk.map(Value.text))
            values += scan.values
            let found = Set(scan.values.map(\.id))
            for id in chunk where !found.contains(id) {
                if let full = try message(id) { try writeProjection(full); values.append(MailMessageSummary(message: full)) }
            }
        }
        return values
    }
    public func rememberIndexInput(_ mail: MailMessage, attachments: Bool, model: String, hash: String) throws {
        guard let key = MailIndexInput.key(for: mail, attachments: attachments) else { return }
        let s = try statement("SELECT p.json FROM message_projections p JOIN index_state i ON i.message=p.message WHERE p.message=? AND i.model=? AND i.hash=?", [.text(mail.id), .text(model), .text(hash)])
        defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_ROW,
              let summary = try? decoder.decode(MailMessageSummary.self, from: bytes(s, 0)),
              MailIndexInput.key(for: summary.displayMessage, attachments: attachments) == key else { return }
        try execute("INSERT INTO index_inputs(message,model,input_key,hash) VALUES(?,?,?,?) ON CONFLICT(message) DO UPDATE SET model=excluded.model,input_key=excluded.input_key,hash=excluded.hash", [.text(mail.id), .text(model), .text(key), .text(hash)])
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
    public func vectorSearch(_ query: [Float], model: String, limit: Int = 30, allowedIDs: Set<String>? = nil, minimumScore: Float? = nil) async throws -> [SearchHit] {
        if allowedIDs?.isEmpty == true { return [] }
        guard !query.isEmpty, query.allSatisfy(\.isFinite) else { throw MailError.message("检索向量无效。") }
        guard limit > 0 else { return [] }
        let database = root.appendingPathComponent("mail.sqlite")
        let scanner = Task.detached(priority: .userInitiated) {
            try MailVectorRanking.rank(database: database, query: query, model: model, limit: limit, allowedIDs: allowedIDs, minimumScore: minimumScore)
        }
        let ranked = try await withTaskCancellationHandler(operation: { try await scanner.value }, onCancel: { scanner.cancel() })
        var results: [SearchHit] = []
        for candidate in ranked {
            try Task.checkCancellation()
            if let mail = try message(candidate.id) { results.append(SearchHit(message: mail, score: candidate.score, method: "语义（EmbeddingGemma 2）", snippet: candidate.snippet)) }
        }
        return results
    }
    public func indexCount() throws -> Int {
        let s = try statement("SELECT count(DISTINCT m.canonical) FROM index_state i JOIN messages m ON m.id=i.message"); defer { sqlite3_finalize(s) }; return sqlite3_step(s) == SQLITE_ROW ? Int(sqlite3_column_int(s, 0)) : 0
    }
}

extension MailStore {
    public func setSessionPinned(_ id: String, pinned: Bool, at date: Date = Date()) throws -> ChatSession {
        try execute("BEGIN IMMEDIATE")
        do {
            guard var current = try object(ChatSession.self, kind: "chat-session", id: id) else { throw MailError.message("会话不存在。") }
            current.pinnedAt = pinned ? current.pinnedAt ?? date : nil
            current.updatedAt = max(current.updatedAt, date)
            try save(current, kind: "chat-session", id: id); try execute("COMMIT"); return current
        } catch { try? execute("ROLLBACK"); throw error }
    }
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
    public func commitChat(_ message: PartnerChat, session: ChatSession, presentation: OpenUIInteraction? = nil) throws -> ChatSession {
        try execute("BEGIN IMMEDIATE")
        do {
            var current = try object(ChatSession.self, kind: "chat-session", id: session.id) ?? session
            if current.title == "新对话" && message.role == "user" { current.title = String(message.text.replacingOccurrences(of: "\n", with: " ").prefix(24)) }
            current.updatedAt = max(current.updatedAt, message.date)
            if let presentation { guard presentation.chatID == message.id && presentation.sessionID == message.sessionID && message.openUIID == presentation.id else { throw MailError.message("结构化结果不属于这条回复。") }; try save(presentation, kind: "openui-interaction", id: presentation.id) }
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
    public func commitWorkingDraft(_ draft: ComposeDraft, artifact: AgentArtifact?, expectedUpdatedAt: Date? = nil) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            let existing = try object(ComposeDraft.self, kind: "draft", id: draft.id)
            if let expectedUpdatedAt, existing?.updatedAt != expectedUpdatedAt { throw MailError.message("草稿已变化，未覆盖已有修改。") }
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
