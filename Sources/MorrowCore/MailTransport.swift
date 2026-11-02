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
    private struct IMAPSession { var fingerprint: String; let connection: IMAPConnection; let gate: NetworkOperationGate; var lastUsed = Date() }
    private struct POPSession { var fingerprint: String; let connection: POP3Client; let gate: NetworkOperationGate }
    private var sessions: [String: IMAPSession] = [:]
    private var popSessions: [String: POPSession] = [:]
    public private(set) var downloadTiming = IMAPConnection.DownloadTiming()
    private let testOnlyPlaintextLoopback: Bool
    public init() { testOnlyPlaintextLoopback = false }
    init(testOnlyPlaintextLoopback: Bool) { self.testOnlyPlaintextLoopback = testOnlyPlaintextLoopback }
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
        let result = try await withReadSession(account, password: password) { try await $0.list(accountID: account.id) }
        guard !result.isEmpty else { throw MailError.message("服务器没有返回可读的邮件文件夹。请检查 IMAP 是否开启。") }; return result
    }
    public static func parseFolders(_ text: String, accountID: String) -> [MailFolder] {
        let re = try! NSRegularExpression(pattern: #"(?im)^\* LIST \(([^)]*)\) (?:"[^"]*"|NIL) ("(?:[^"\\]|\\.)*"|[^\r\n]+)"#)
        var out: [MailFolder] = []
        for match in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let ns = text as NSString; let flags = ns.substring(with: match.range(at: 1)).lowercased()
            let flagWords = Set(flags.split(whereSeparator: \.isWhitespace).map(String.init))
            if flagWords.contains("\\noselect") { continue }
            var path = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            if path.hasPrefix("\"") { path = String(path.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\") }
            var role = MailFolder.inferredRole(path: path)
            for (flag, r) in [("\\sent", "sent"), ("\\drafts", "drafts"), ("\\trash", "trash"), ("\\junk", "junk"), ("\\archive", "archive"), ("\\all", "archive")] where flagWords.contains(flag) { role = r }
            if !out.contains(where: { $0.path == path }) { out.append(.init(accountID: accountID, path: path, role: role)) }
        }
        return out.sorted { ($0.role == "inbox" ? 0 : 1, $0.path) < ($1.role == "inbox" ? 0 : 1, $1.path) }
    }
    public func inventory(_ account: MailAccount, folder: String, password: String) async throws -> (UInt64, [UInt64: (read: Bool, starred: Bool)]) {
        try await withReadSession(account, password: password) { try await $0.inventory(folder) }
    }
    public func syncInventory(_ account: MailAccount, folder: String, cursor: MailFolderSyncCursor?, password: String) async throws -> MailSyncInventory {
        try await withReadSession(account, password: password) { try await $0.syncInventory(folder, cursor: cursor) }
    }
    public func syncFlags(_ account: MailAccount, folder: String, uids: [UInt64], validity: UInt64, password: String) async throws -> [UInt64: MailSyncFlags] {
        try await withReadSession(account, password: password) { try await $0.syncFlags(folder: folder, uids: uids, expectedValidity: validity) }
    }
    /// Validate a small Gmail identity batch before any full-body request.
    /// Other servers retain the normal body-download path.
    public func reuseGmailBodies(_ account: MailAccount, folder: String, uids: [UInt64], validity: UInt64, password: String,
                                 store: MailStore, flags: [UInt64: MailSyncFlags], inventoryStarted: Date) async throws -> [UInt64: MailMessage] {
        guard !uids.isEmpty else { return [:] }
        let destinations = try await withReadSession(account, password: password) { try await $0.gmailIdentities(accountID: account.id, folder: folder, uids: uids, expectedValidity: validity) }
        guard !destinations.isEmpty else { return [:] }
        var candidates: [UInt64: [MailMessage]] = [:], sourceIdentities: [String: GmailMessageIdentity] = [:], candidateBytes: UInt64 = 0
        var missing: [String: [MailMessage]] = [:]
        for (uid, destination) in destinations.sorted(by: { $0.key > $1.key }) where flags[uid] != nil {
            guard destination.rawSize <= 16 * 1024 * 1024 - candidateBytes else { continue }
            let sources = try await store.gmailBodyCandidates(account: account.id, messageID: destination.messageID, destinationID: destination.mailID, rawSize: destination.rawSize)
            candidateBytes += destination.rawSize
            candidates[uid] = sources
            for source in sources {
                if let identity = try await store.cachedGmailIdentity(account: account, message: source) { sourceIdentities[source.id] = identity }
                else { missing[source.folder + "\n" + String(source.uidValidity), default: []].append(source) }
            }
        }
        for sources in missing.values {
            var seen = Set<String>(); let distinct = sources.filter { seen.insert($0.id).inserted }
            guard let first = distinct.first else { continue }
            for start in stride(from: 0, to: distinct.count, by: 64) {
                let batch = Array(distinct[start..<min(start + 64, distinct.count)])
                let identities = try await withReadSession(account, password: password) { try await $0.gmailIdentities(accountID: account.id, folder: first.folder, uids: batch.map(\.uid), expectedValidity: first.uidValidity) }
                for source in batch { if let identity = identities[source.uid] { sourceIdentities[source.id] = identity; try? await store.cacheGmailIdentity(identity, account: account) } }
            }
        }
        var reused: [UInt64: MailMessage] = [:]
        for (uid, destination) in destinations {
            guard let flag = flags[uid] else { continue }
            for source in candidates[uid] ?? [] {
                guard let identity = sourceIdentities[source.id] else { continue }
                if let saved = try await store.reuseGmailBody(source: source, sourceIdentity: identity, destination: destination, flags: flag, inventoryStarted: inventoryStarted) {
                    reused[uid] = saved; try? await store.cacheGmailIdentity(destination, account: account); break
                }
            }
        }
        return reused
    }
    public static func parseFlags(_ text: String) -> [UInt64: (read: Bool, starred: Bool)] {
        var out: [UInt64: (read: Bool, starred: Bool)] = [:]
        text.enumerateLines { line, _ in if let row = IMAPFlagRow.parse(line) { out[row.uid] = (row.read, row.starred) } }
        return out
    }
    public func fetch(_ account: MailAccount, folder: String, uid: UInt64, validity: UInt64, password: String) async throws -> MailMessage {
        // BODY.PEEK keeps fetching/indexing from marking the message as read.
        let data = try await withReadSession(account, password: password) { try await $0.fetch(folder: folder, uid: uid, expectedValidity: validity) }
        return MIMEParser.parse(data, accountID: account.id, folder: folder, uid: uid, validity: validity)
    }
    public func fetchMany(_ account: MailAccount, folder: String, uids: [UInt64], validity: UInt64, password: String) async throws -> [UInt64: MailMessage] {
        let bodies = try await withReadSession(account, password: password) { try await $0.fetchMany(folder: folder, uids: uids, expectedValidity: validity) }
        var messages: [UInt64: MailMessage] = [:]
        for (uid, data) in bodies {
            try Task.checkCancellation()
            messages[uid] = MIMEParser.parse(data, accountID: account.id, folder: folder, uid: uid, validity: validity)
        }
        return messages
    }
    public func fetchRawMany(_ account: MailAccount, folder: String, uids: [UInt64], validity: UInt64, password: String, attachmentLimit: Int = 10 * 1024 * 1024) async throws -> [UInt64: Data] {
        let (bodies, timing) = try await withReadSession(account, password: password) { connection in
            let bodies = try await connection.fetchMany(folder: folder, uids: uids, expectedValidity: validity, maximumBatchBytes: 16 * 1024 * 1024, maximumMessageBytes: UInt64(attachmentLimit))
            return (bodies, await connection.downloadTiming)
        }
        downloadTiming = timing; return bodies
    }
    public func fetchForSync(_ account: MailAccount, folder: String, uid: UInt64, validity: UInt64, password: String, attachmentLimit: Int = 10 * 1024 * 1024) async throws -> MailSyncFetch {
        try await withReadSession(account, password: password) { try await $0.fetchForSync(accountID: account.id, folder: folder, uid: uid, expectedValidity: validity, attachmentLimit: attachmentLimit) }
    }
    public func fetchRemoteAttachment(_ account: MailAccount, reference: MailRemoteAttachment, password: String) async throws -> Data {
        guard account.id == reference.accountID else { throw MailError.message("附件不属于当前邮箱。") }
        let data = try await withSession(account, password: password) { try await $0.fetchSection(reference.section, folder: reference.folder, uid: reference.uid, expectedValidity: reference.validity, count: reference.encodedBytes) }
        if reference.encoding.uppercased() == "BASE64" { guard let decoded = Data(base64Encoded: data, options: .ignoreUnknownCharacters) else { throw MailError.message("附件编码无效。") }; return decoded }
        return reference.encoding.uppercased() == "QUOTED-PRINTABLE" ? MIMEParser.quotedPrintable(data) : data
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
    public func move(_ account: MailAccount, message: MailMessage, destination: String, password: String, store: MailStore? = nil) async throws -> MailMoveReceipt {
        guard message.uid > 0, destination != message.folder else { return MailMoveReceipt(destinationValidity: nil, destinationUID: nil) }
        guard message.accountID == account.id else { throw MailError.message("移动来源不属于当前邮箱。") }
        var sourceIdentity: GmailMessageIdentity?
        if let store {
            sourceIdentity = try await store.cachedGmailIdentity(account: account, message: message)
            if sourceIdentity?.messageID != message.messageID.trimmingCharacters(in: .whitespacesAndNewlines) { sourceIdentity = nil }
            if sourceIdentity == nil {
                do {
                    let identities = try await withSession(account, password: password) { try await $0.gmailIdentities(accountID: account.id, folder: message.folder, uids: [message.uid], expectedValidity: message.uidValidity) }
                    if let identity = identities[message.uid], identity.messageID == message.messageID.trimmingCharacters(in: .whitespacesAndNewlines) {
                        sourceIdentity = identity; try? await store.cacheGmailIdentity(identity, account: account)
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { sourceIdentity = nil }
            }
        }
        let retainedIdentity = sourceIdentity
        return try await withSession(account, password: password) { connection in
            let receipt = try await connection.move(folder: message.folder, uid: message.uid, destination: destination, expectedValidity: message.uidValidity)
            guard (receipt.destinationUID == nil || receipt.destinationValidity == nil || receipt.sourceUID == nil), let sourceIdentity = retainedIdentity else { return receipt }
            // Source identity was obtained before MOVE. Looking up a vanished
            // source UID afterwards can never establish its previous identity.
            return await connection.resolveGmailMove(accountID: account.id, sourceIdentity: sourceIdentity, destination: destination) ?? receipt
        }
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
    /// Read-only IMAP commands can reconnect once. Mutations deliberately use
    /// withSession directly, because their server result may be uncertain.
    private func withReadSession<T>(_ account: MailAccount, password: String, operation: (IMAPConnection) async throws -> T) async throws -> T {
        do { return try await withSession(account, password: password, operation: operation) }
        catch {
            guard !Task.isCancelled, MailConnectionError.isTransient(error) else { throw error }
            try await Task.sleep(for: .milliseconds(500))
            return try await withSession(account, password: password, operation: operation)
        }
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
            if entry.fingerprint != fingerprint || Date().timeIntervalSince(entry.lastUsed) > 300 { await entry.connection.close(); entry.fingerprint = fingerprint; sessions[account.id] = entry }
            if !(await entry.connection.connected) {
                let loopback = ["127.0.0.1", "localhost"].contains(account.imapHost)
                try await entry.connection.connect(host: account.imapHost, port: account.imapPort, email: account.email, password: password, tls: !(testOnlyPlaintextLoopback && loopback), oauth: account.authMethod == "oauth")
            }
            try Task.checkCancellation()
            let result = try await operation(entry.connection)
            if var registered = sessions[account.id], registered.gate === entry.gate { registered.lastUsed = Date(); sessions[account.id] = registered }
            await entry.gate.release(permit); return result
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
