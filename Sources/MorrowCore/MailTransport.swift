import Foundation
import CMail

public struct TransportReply: Sendable {
    public var data: Data
    public var headers: String
    public var text: String { String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? "" }
    public var protocolText: String { headers + "\n" + text }
}

/// Only UIDs covered by successfully acknowledged STORE commands are listed.
public struct MailBulkFlagReceipt: Sendable {
    public var uids: [UInt64]
    public var uidValidity: UInt64
    public var failure: String?
    public init(uids: [UInt64], uidValidity: UInt64, failure: String? = nil) { self.uids = uids; self.uidValidity = uidValidity; self.failure = failure }
}

public actor MailTransport {
    private struct IMAPSession { var fingerprint: String; let connection: IMAPConnection; let gate: NetworkOperationGate }
    private struct POPSession { var fingerprint: String; let connection: POP3Client; let gate: NetworkOperationGate }
    private var sessions: [String: IMAPSession] = [:]
    private var popSessions: [String: POPSession] = [:]
    public private(set) var downloadTiming = IMAPConnection.DownloadTiming()
    public init() {}
    // Test fixtures may use loopback plaintext. Production account URLs are always TLS.
    public func request(url: String, username: String, password: String, command: String = "", upload: Data? = nil, from: String? = nil, recipients: [String] = [], startTLS: Bool = false, testOnly: Bool = false, oauth: Bool = false) async throws -> TransportReply {
        try Task.checkCancellation()
        #if os(iOS)
        return try await NativeSMTP.request(url: url, username: username, password: password, upload: upload, from: from, recipients: recipients, startTLS: startTLS, testOnly: testOnly, oauth: oauth)
        #else
        let operation = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let strings = recipients.map { strdup($0) }; defer { strings.forEach { free($0) } }
            let pointers = strings.map { UnsafePointer<CChar>($0) }
            var response = pointers.withUnsafeBufferPointer { p in
                if let upload { return upload.withUnsafeBytes { bytes in sm_request(url, username, password, command, bytes.bindMemory(to: UInt8.self).baseAddress, upload.count, from, p.baseAddress, Int32(recipients.count), startTLS ? 1 : 0, testOnly ? 1 : 0, oauth ? 1 : 0) } }
                return sm_request(url, username, password, command, nil, 0, from, p.baseAddress, Int32(recipients.count), startTLS ? 1 : 0, testOnly ? 1 : 0, oauth ? 1 : 0)
            }
            defer { sm_response_free(&response) }
            guard response.code == 0 else { throw MailError.message(response.error.map { String(cString: $0) } ?? "邮件服务器连接失败。") }
            let body = response.data.map { Data(bytes: $0, count: response.length) } ?? Data()
            let head = response.headers.map { String(cString: $0) } ?? ""
            return TransportReply(data: body, headers: head)
        }
        return try await withTaskCancellationHandler { try await operation.value } onCancel: { operation.cancel() }
        #endif
    }

    public func test(_ account: MailAccount, password: String) async throws -> [MailFolder] {
        try account.validate(); guard !password.isEmpty else { throw MailError.message("请填写邮箱客户端授权码。") }
        return try await folders(account, password: password)
    }
    public func folders(_ account: MailAccount, password: String) async throws -> [MailFolder] {
        if account.usesPOP {
            _ = try await popInventory(account, password: password)
            return [("INBOX", "inbox"), ("Sent", "sent"), ("Archive", "archive"), ("Trash", "trash"), ("Junk", "junk")].map { MailFolder(accountID: account.id, path: $0.0, role: $0.1) }
        }
        let result = try await withSession(account, password: password) { try await $0.list(accountID: account.id) }
        guard !result.isEmpty else { throw MailError.message("服务器没有返回可读的邮件文件夹。请检查 IMAP 是否开启。") }; return result
    }
    public static func parseFolders(_ text: String, accountID: String) -> [MailFolder] {
        let re = try! NSRegularExpression(pattern: #"(?im)^\* LIST \(([^)]*)\) (?:"[^"]*"|NIL) ("(?:[^"\\]|\\.)*"|[^\r\n]+)"#)
        var out: [MailFolder] = []
        for match in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let ns = text as NSString; let flags = ns.substring(with: match.range(at: 1)).lowercased()
            if flags.contains("\\noselect") { continue }
            var path = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            if path.hasPrefix("\"") { path = String(path.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\") }
            var role = "custom"; let lower = MailboxCodec.decode(path).lowercased()
            if lower == "inbox" { role = "inbox" }
            for (flag, r) in [("\\sent", "sent"), ("\\drafts", "drafts"), ("\\trash", "trash"), ("\\junk", "junk"), ("\\archive", "archive")] where flags.contains(flag) { role = r }
            if role == "custom" {
                if ["sent", "sent messages", "已发送", "已发送邮件"].contains(lower) { role = "sent" }
                if ["drafts", "草稿", "草稿箱"].contains(lower) { role = "drafts" }
                if ["trash", "deleted messages", "deleted items", "已删除", "废纸篓"].contains(lower) { role = "trash" }
                if ["junk", "spam", "垃圾邮件", "垃圾箱"].contains(lower) { role = "junk" }
                if ["archive", "all mail", "归档"].contains(lower) { role = "archive" }
            }
            if !out.contains(where: { $0.path == path }) { out.append(.init(accountID: accountID, path: path, role: role)) }
        }
        return out.sorted { ($0.role == "inbox" ? 0 : 1, $0.path) < ($1.role == "inbox" ? 0 : 1, $1.path) }
    }
    public func inventory(_ account: MailAccount, folder: String, password: String) async throws -> (UInt64, [UInt64: (read: Bool, starred: Bool)]) {
        try await withSession(account, password: password) { try await $0.inventory(folder) }
    }
    public static func parseFlags(_ text: String) -> [UInt64: (read: Bool, starred: Bool)] {
        var out: [UInt64: (read: Bool, starred: Bool)] = [:]
        text.enumerateLines { line, _ in if let row = IMAPFlagRow.parse(line) { out[row.uid] = (row.read, row.starred) } }
        return out
    }
    public func fetch(_ account: MailAccount, folder: String, uid: UInt64, validity: UInt64, password: String) async throws -> MailMessage {
        // BODY.PEEK keeps fetching/indexing from marking the message as read.
        let data = try await withSession(account, password: password) { try await $0.fetch(folder: folder, uid: uid, expectedValidity: validity) }
        return MIMEParser.parse(data, accountID: account.id, folder: folder, uid: uid, validity: validity)
    }
    public func fetchMany(_ account: MailAccount, folder: String, uids: [UInt64], validity: UInt64, password: String) async throws -> [UInt64: MailMessage] {
        let bodies = try await withSession(account, password: password) { try await $0.fetchMany(folder: folder, uids: uids, expectedValidity: validity) }
        var messages: [UInt64: MailMessage] = [:]
        for (uid, data) in bodies {
            try Task.checkCancellation()
            messages[uid] = MIMEParser.parse(data, accountID: account.id, folder: folder, uid: uid, validity: validity)
        }
        return messages
    }
    public func fetchRawMany(_ account: MailAccount, folder: String, uids: [UInt64], validity: UInt64, password: String) async throws -> [UInt64: Data] {
        let (bodies, timing) = try await withSession(account, password: password) { connection in
            let bodies = try await connection.fetchMany(folder: folder, uids: uids, expectedValidity: validity, maximumBatchBytes: 16 * 1024 * 1024)
            return (bodies, await connection.downloadTiming)
        }
        downloadTiming = timing; return bodies
    }
    public func fetchRaw(_ account: MailAccount, folder: String, uid: UInt64, validity: UInt64, password: String) async throws -> Data {
        try await withSession(account, password: password) { try await $0.fetch(folder: folder, uid: uid, expectedValidity: validity) }
    }
    public func setFlag(_ account: MailAccount, message: MailMessage, flag: String, enabled: Bool, password: String) async throws {
        guard ["\\Seen", "\\Flagged", "\\Deleted"].contains(flag), message.uid > 0 else { throw MailError.message("邮件标记无效。") }
        try await withSession(account, password: password) { try await $0.store(folder: message.folder, uid: message.uid, flag: flag, enabled: enabled, expectedValidity: message.uidValidity) }
    }
    public func setFlags(_ account: MailAccount, folder: String, uids: [UInt64], expectedValidity: UInt64, flag: String, enabled: Bool, password: String) async throws -> MailBulkFlagReceipt {
        let batches = try IMAPConnection.flagBatches(uids, flag: flag, enabled: enabled)
        try IMAPConnection.validateBulkFolder(folder)
        guard !batches.isEmpty else { return MailBulkFlagReceipt(uids: [], uidValidity: expectedValidity) }
        guard expectedValidity > 0 && expectedValidity <= UInt64(UInt32.max) else { throw MailError.message("UIDVALIDITY 无效，未执行批量标记。") }
        guard !account.usesPOP else { throw MailError.message("POP 邮箱不支持服务器批量标记。") }
        return try await withSession(account, password: password) { try await $0.storeMany(folder: folder, uids: uids, flag: flag, enabled: enabled, expectedValidity: expectedValidity) }
    }
    public func markFolderRead(_ account: MailAccount, folder: String, expectedValidity: UInt64? = nil, password: String) async throws -> MailBulkFlagReceipt {
        try IMAPConnection.validateBulkFolder(folder)
        if let expectedValidity { guard expectedValidity > 0 && expectedValidity <= UInt64(UInt32.max) else { throw MailError.message("UIDVALIDITY 无效，未执行批量标记。") } }
        guard !account.usesPOP else { throw MailError.message("POP 邮箱不支持服务器批量标记。") }
        return try await withSession(account, password: password) { try await $0.markFolderRead(folder: folder, expectedValidity: expectedValidity) }
    }
    public func move(_ account: MailAccount, message: MailMessage, destination: String, password: String) async throws -> MailMoveReceipt {
        guard message.uid > 0, destination != message.folder else { return MailMoveReceipt(destinationValidity: nil, destinationUID: nil) }
        return try await withSession(account, password: password) { try await $0.move(folder: message.folder, uid: message.uid, destination: destination, expectedValidity: message.uidValidity) }
    }
    public func createFolder(_ account: MailAccount, path: String, password: String) async throws {
        try await withSession(account, password: password) { try await $0.create(MailboxCodec.encode(path)) }
    }
    public func append(_ account: MailAccount, folder: String, raw: Data, password: String) async throws {
        if account.usesPOP { return }
        try await withSession(account, password: password) { try await $0.append(folder: folder, raw: raw) }
    }
    public func send(_ account: MailAccount, draft: ComposeDraft, password: String) async throws -> Data {
        let raw = try MIMEWriter.encode(draft, account: account)
        let recipients = (draft.addresses(draft.to) + draft.addresses(draft.cc) + draft.addresses(draft.bcc)).map(\.email)
        let scheme = account.smtpStartTLS ? "smtp" : "smtps"
        _ = try await request(url: "\(scheme)://\(account.smtpHost):\(account.smtpPort)", username: account.email, password: password, upload: raw, from: account.email, recipients: recipients, startTLS: account.smtpStartTLS, oauth: account.authMethod == "oauth")
        return raw
    }
    private func imapURL(_ account: MailAccount, folder: String? = nil) -> String {
        var value = "imaps://\(account.imapHost):\(account.imapPort)"
        if let folder { value += "/" + (folder.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? "INBOX") }; return value
    }
    private func sessionFingerprint(_ account: MailAccount, password: String) -> String {
        MailStore.hash(account.imapHost + ":" + String(account.imapPort) + ":" + account.email + ":" + account.authMethod + ":" + MailStore.hash(password))
    }
    private func withSession<T>(_ account: MailAccount, password: String, operation: (IMAPConnection) async throws -> T) async throws -> T {
        try Task.checkCancellation()
        let fingerprint = sessionFingerprint(account, password: password)
        if sessions[account.id] == nil { sessions[account.id] = IMAPSession(fingerprint: fingerprint, connection: IMAPConnection(), gate: NetworkOperationGate()) }
        var entry = sessions[account.id]!
        let permit = try await entry.gate.acquire()
        do {
            try Task.checkCancellation()
            // One credential generation per account. Expired OAuth sockets do
            // not remain in a dictionary keyed by every historic token hash.
            guard let registered = sessions[account.id], registered.gate === entry.gate else { throw CancellationError() }
            entry = registered
            if entry.fingerprint != fingerprint { await entry.connection.close(); entry.fingerprint = fingerprint; sessions[account.id] = entry }
            if !(await entry.connection.connected) { try await entry.connection.connect(host: account.imapHost, port: account.imapPort, email: account.email, password: password, oauth: account.authMethod == "oauth") }
            try Task.checkCancellation()
            let result = try await operation(entry.connection); await entry.gate.release(permit); return result
        } catch { await entry.connection.close(); await entry.gate.release(permit); throw error }
    }
    public func closeAccount(_ accountID: String) async {
        let imap = sessions.removeValue(forKey: accountID), pop = popSessions.removeValue(forKey: accountID)
        if let imap { await imap.gate.invalidate(); await imap.connection.close() }
        if let pop { await pop.gate.invalidate(); await pop.connection.close() }
    }
    public func popInventory(_ account: MailAccount, password: String) async throws -> [String: Int] {
        try await withPOP(account, password: password) { try await $0.inventory() }
    }
    public func closePOP(_ account: MailAccount) async {
        guard let entry = popSessions[account.id], let permit = try? await entry.gate.acquire() else { return }
        if let registered = popSessions[account.id], registered.gate === entry.gate {
            popSessions[account.id] = nil; await entry.gate.invalidate(); await entry.connection.quit()
        }
        await entry.gate.release(permit)
    }
    public func popFetch(_ account: MailAccount, uid: String, number: Int, password: String) async throws -> MailMessage {
        let raw = try await withPOP(account, password: password) { try await $0.fetch(number: number, expectedUID: uid) }
        var mail = MIMEParser.parse(raw, accountID: account.id); mail.id = account.id + ":pop:" + MailStore.hash(uid); mail.popUID = uid; return mail
    }
    private func withPOP<T>(_ account: MailAccount, password: String, operation: (POP3Client) async throws -> T) async throws -> T {
        try Task.checkCancellation()
        let fingerprint = sessionFingerprint(account, password: password)
        if popSessions[account.id] == nil { popSessions[account.id] = POPSession(fingerprint: fingerprint, connection: POP3Client(), gate: NetworkOperationGate()) }
        var entry = popSessions[account.id]!
        let permit = try await entry.gate.acquire()
        do {
            try Task.checkCancellation()
            guard let registered = popSessions[account.id], registered.gate === entry.gate else { throw CancellationError() }
            entry = registered
            if entry.fingerprint != fingerprint { await entry.connection.close(); entry.fingerprint = fingerprint; popSessions[account.id] = entry }
            if !(await entry.connection.connected) { try await entry.connection.connect(host: account.imapHost, port: account.imapPort, email: account.email, password: password, oauth: account.authMethod == "oauth") }
            try Task.checkCancellation()
            let result = try await operation(entry.connection); await entry.gate.release(permit); return result
        } catch { await entry.connection.close(); await entry.gate.release(permit); throw error }
    }
    private func quoted(_ value: String) throws -> String {
        guard !value.contains("\r"), !value.contains("\n"), !value.contains("\0") else { throw MailError.message("文件夹名称不能包含控制字符。") }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
