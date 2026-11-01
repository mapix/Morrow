import Foundation
import Network

/// One serialized IMAP session. Reads literals by byte count; never marks fetched mail as read.
public actor IMAPConnection {
    private var connection: NWConnection?
    private var buffer = Data()
    private var bufferOffset = 0
    private var sequence = 0
    private var selected: String?
    private var validity: UInt64 = 0
    private var capabilities: Set<String> = []
    private var qresyncEnabled = false
    private var idleTag: String?
    private let maximumResponseBytes: Int
    public init() { maximumResponseBytes = 96 * 1024 * 1024 }
    init(maximumResponseBytes: Int) { self.maximumResponseBytes = max(1, maximumResponseBytes) }
    public var connected: Bool { connection != nil }
    public var supportsIdle: Bool { capabilities.contains("IDLE") }

    public func connect(host: String, port: Int, email: String, password: String, tls: Bool = true, oauth: Bool = false) async throws {
        close(); try Task.checkCancellation()
        guard (1...65535).contains(port), let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else { throw MailError.message("IMAP 端口无效。") }
        let parameters: NWParameters
        if tls {
            let options = NWProtocolTLS.Options()
            sec_protocol_options_set_tls_server_name(options.securityProtocolOptions, host)
            parameters = NWParameters(tls: options, tcp: NWProtocolTCP.Options())
        } else {
            guard host == "127.0.0.1" || host == "localhost" else { throw MailError.message("IMAP 连接必须使用 TLS。") }
            parameters = .tcp
        }
        let c = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: parameters); connection = c
        do { try await MailNetworkIO.connect(c) } catch { close(); throw error }
        let greeting = try await line()
        guard greeting.uppercased().hasPrefix("* OK") else { throw MailError.message("IMAP 服务器未接受连接。") }
        let capability = try await command("CAPABILITY").lines.joined(separator: " ")
        // NetEase requires the client to identify itself before accessing messages.
        if capability.uppercased().contains(" ID ") || capability.uppercased().hasSuffix(" ID") { _ = try? await command("ID (\"name\" \"Morrow\" \"version\" \"0.1\" \"vendor\" \"Morrow\")") }
        if oauth {
            let encoded = Data("user=\(email)\u{01}auth=Bearer \(password)\u{01}\u{01}".utf8).base64EncodedString()
            let tag = nextTag(); var sent = capability.uppercased().contains("SASL-IR")
            try await write(Data("\(tag) AUTHENTICATE XOAUTH2".appending(sent ? " " + encoded : "").appending("\r\n").utf8))
            var oauthStatus: String?
            while true {
                let l = try await line()
                if l.hasPrefix("+") {
                    if sent, let data = Data(base64Encoded: l.dropFirst().trimmingCharacters(in: .whitespaces)), let error = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { oauthStatus = error["status"] as? String }
                    try await write(Data(((sent ? "" : encoded) + "\r\n").utf8)); sent = true
                }
                else if l.hasPrefix(tag + " ") { guard l.uppercased().hasPrefix(tag.uppercased() + " OK") else { throw MailError.message("IMAP OAuth 认证失败" + (oauthStatus.map { "（服务器状态" + $0 + "）" } ?? "") + "：" + String(l.dropFirst(tag.count + 1).prefix(200))) }; break }
            }
        } else { _ = try await command("LOGIN \(try Self.quote(email)) \(try Self.quote(password))", sensitive: true) }
        // Extensions may only be advertised after authentication.
        capabilities = Self.capabilityWords(try await command("CAPABILITY").lines)
    }
    public func close() { connection?.cancel(); connection = nil; buffer = Data(); bufferOffset = 0; selected = nil; validity = 0; capabilities = []; qresyncEnabled = false; idleTag = nil }
    public func select(_ folder: String) async throws -> UInt64 {
        if selected == folder { return validity }
        let result = try await command("SELECT \(try Self.quote(folder))")
        validity = UInt64(MIMEParser.capture(#"UIDVALIDITY\s+(\d+)"#, result.lines.joined(separator: "\n")) ?? "0") ?? 0
        guard validity > 0 else { throw MailError.message("服务器没有提供 UIDVALIDITY，无法安全同步此文件夹。") }
        selected = folder; return validity
    }
    public func inventory(_ folder: String) async throws -> (UInt64, [UInt64: (read: Bool, starred: Bool)]) {
        selected = nil
        let v = try await select(folder)
        let tag = nextTag(); try await write(Data("\(tag) UID FETCH 1:* (UID FLAGS)\r\n".utf8))
        var flags: [UInt64: (read: Bool, starred: Bool)] = [:]
        do {
            _ = try await readResponse(tag, retainLines: false, allowLiterals: false) { line in
                if let row = IMAPFlagRow.parse(line) { flags[row.uid] = (row.read, row.starred) }
            }
            return (v, flags)
        } catch { close(); throw error }
    }
    private static func capabilityWords(_ lines: [String]) -> Set<String> {
        Set(lines.filter { $0.uppercased().hasPrefix("* CAPABILITY ") }.flatMap { $0.uppercased().split(whereSeparator: \.isWhitespace).dropFirst(2).map(String.init) })
    }
    /// RFC 7162: QRESYNC supplies vanished UIDs; CONDSTORE supplies changed
    /// flags. With CONDSTORE alone, SEARCH ALL reconciles membership only when
    /// SELECT reports a change. The baseline IMAP path remains compatible.
    public func syncInventory(_ folder: String, cursor: MailFolderSyncCursor?) async throws -> MailSyncInventory {
        do {
            if capabilities.contains("QRESYNC"), capabilities.contains("ENABLE"), !qresyncEnabled {
                let reply = try await command("ENABLE QRESYNC")
                qresyncEnabled = reply.lines.contains { $0.uppercased().split(whereSeparator: \.isWhitespace).contains("QRESYNC") }
            }
            let modSequence = cursor?.highestModSequence.flatMap { $0 > 0 ? $0 : nil }
            let useQResync = qresyncEnabled && cursor != nil && modSequence != nil
            let condstore = capabilities.contains("CONDSTORE") || qresyncEnabled
            selected = nil
            let parameters: String
            if useQResync, let cursor, let modSequence { parameters = " (QRESYNC (\(cursor.validity) \(modSequence)))" }
            else { parameters = condstore ? " (CONDSTORE)" : "" }
            let selection = try await command("SELECT \(try Self.quote(folder))" + parameters)
            let selectionText = selection.lines.joined(separator: "\n") + "\n" + selection.completion
            validity = Self.responseNumber("UIDVALIDITY", selectionText) ?? 0
            guard validity > 0, validity <= UInt64(UInt32.max) else { throw MailError.message("服务器没有提供有效 UIDVALIDITY。") }
            selected = folder
            let highest = Self.responseNumber("HIGHESTMODSEQ", selectionText)
            let uidNext = Self.responseNumber("UIDNEXT", selectionText)
            let count = MIMEParser.capture(#"(?im)^\*\s+(\d+)\s+EXISTS\b"#, selectionText).flatMap(Int.init)
            let incremental = condstore && highest != nil && modSequence != nil && cursor?.validity == validity && highest! >= modSequence!
            var flags = Self.syncFlags(selection.lines)
            let present: Set<UInt64>
            if incremental, let cursor, let modSequence {
                if useQResync {
                    var known = Set(cursor.knownUIDs)
                    for line in selection.lines where line.uppercased().hasPrefix("* VANISHED ") {
                        known.subtract(try Self.vanishedUIDs(line))
                    }
                    known.formUnion(flags.keys)
                    // A new UID can appear without a flag update for known mail.
                    if let next = cursor.uidNext, next <= UInt64(UInt32.max), uidNext == nil || uidNext! > next {
                        flags.merge(try await fetchSyncFlags("\(next):\(UInt32.max)", modSequence: nil), uniquingKeysWith: { _, new in new })
                        known.formUnion(flags.keys)
                    }
                    // Missing/inconsistent QRESYNC membership is reconciled safely.
                    if let count, count != known.count { present = try await searchUIDs() }
                    else { present = known }
                } else if highest == modSequence, uidNext != nil, uidNext == cursor.uidNext, count == cursor.knownUIDs.count {
                    present = Set(cursor.knownUIDs)
                } else {
                    flags.merge(try await fetchSyncFlags("1:*", modSequence: modSequence), uniquingKeysWith: { _, new in new })
                    present = try await searchUIDs()
                }
            } else {
                flags = try await fetchSyncFlags("1:*", modSequence: nil)
                if let count, count != flags.count { present = try await searchUIDs() }
                else { present = Set(flags.keys) }
            }
            flags = flags.filter { present.contains($0.key) }
            // Use SELECT's watermark, never a later FETCH watermark: concurrent
            // changes after SELECT must be replayed on the next sync.
            return .init(validity: validity, flags: flags, presentUIDs: present, highestModSequence: highest, uidNext: uidNext, incremental: incremental)
        } catch { close(); throw error }
    }
    private static func responseNumber(_ name: String, _ text: String) -> UInt64? {
        MIMEParser.capture("(?i)\\[" + name + "\\s+(\\d+)\\]", text).flatMap(UInt64.init)
    }
    private static func syncFlags(_ lines: [String]) -> [UInt64: MailSyncFlags] {
        var result: [UInt64: MailSyncFlags] = [:]
        for line in lines { if let row = IMAPFlagRow.parse(line) { result[row.uid] = .init(read: row.read, starred: row.starred) } }
        return result
    }
    private func fetchSyncFlags(_ set: String, modSequence: UInt64?) async throws -> [UInt64: MailSyncFlags] {
        let tag = nextTag()
        let modifier = modSequence.map { " (CHANGEDSINCE \($0))" } ?? ""
        try await write(Data("\(tag) UID FETCH \(set) (UID FLAGS)\(modifier)\r\n".utf8))
        var flags: [UInt64: MailSyncFlags] = [:]
        _ = try await readResponse(tag, retainLines: false, allowLiterals: false) { line in
            if let row = IMAPFlagRow.parse(line) { flags[row.uid] = .init(read: row.read, starred: row.starred) }
        }
        return flags
    }
    public func syncFlags(folder: String, uids: [UInt64], expectedValidity: UInt64) async throws -> [UInt64: MailSyncFlags] {
        guard try await select(folder) == expectedValidity else { throw MailError.message("文件夹已重建，请重新同步。") }
        // Reuse the bounded UID command builder; FLAGS never downloads bodies.
        var result: [UInt64: MailSyncFlags] = [:]
        for batch in try Self.flagBatches(uids, flag: "\\Seen", enabled: true) {
            let set = String(batch.command.dropFirst("UID STORE ".count).split(separator: " ")[0])
            result.merge(try await fetchSyncFlags(set, modSequence: nil), uniquingKeysWith: { _, new in new })
        }
        let allowed = Set(uids)
        return result.filter { allowed.contains($0.key) }
    }
    /// Small identity/header fetches can reuse Gmail bodies already cached in
    /// another folder. PEEK headers never mark the message read.
    public func gmailIdentities(accountID: String, folder: String, uids: [UInt64], expectedValidity: UInt64) async throws -> [UInt64: GmailMessageIdentity] {
        guard capabilities.contains("X-GM-EXT-1") else { return [:] }
        guard !uids.isEmpty, uids.count <= 64, Set(uids).count == uids.count,
              uids.allSatisfy({ $0 > 0 && $0 <= UInt64(UInt32.max) }) else { throw MailError.message("邮件身份查询UID无效。") }
        guard try await select(folder) == expectedValidity else { throw MailError.message("文件夹已重建，未复用旧正文。") }
        let set = uids.map(String.init).joined(separator: ",")
        let reply = try await command("UID FETCH \(set) (UID X-GM-MSGID RFC822.SIZE BODY.PEEK[HEADER.FIELDS (MESSAGE-ID)])", maximumLiteralBytes: 65536)
        return try Self.gmailIdentities(lines: reply.lines, literals: reply.literals, allowed: Set(uids), accountID: accountID, folder: folder, validity: expectedValidity)
    }
    /// A successful Gmail MOVE may omit COPYUID when the destination already
    /// has its label. Only a pre-MOVE global identity can locate that alias.
    public func resolveGmailMove(accountID: String, sourceIdentity: GmailMessageIdentity, destination: String) async -> MailMoveReceipt? {
        guard capabilities.contains("X-GM-EXT-1"), !accountID.isEmpty, sourceIdentity.valid,
              sourceIdentity.accountID == accountID, destination != sourceIdentity.folder else { return nil }
        do {
            try Task.checkCancellation()
            selected = nil
            let targetValidity = try await select(destination)
            let tag = nextTag()
            try await write(Data("\(tag) UID SEARCH X-GM-MSGID \(sourceIdentity.globalID)\r\n".utf8))
            var uids = Set<UInt64>(), received = false, invalid = false
            _ = try await readResponse(tag, retainLines: false, allowLiterals: false) { line in
                let words = line.split(whereSeparator: \.isWhitespace)
                guard words.count >= 2, words[0] == "*", words[1].uppercased() == "SEARCH" else { return }
                if received { invalid = true }; received = true
                for token in words.dropFirst(2) {
                    guard let uid = UInt64(token), uid > 0, uid <= UInt64(UInt32.max) else { invalid = true; continue }
                    uids.insert(uid)
                }
            }
            guard received, !invalid, uids.count == 1, let targetUID = uids.first else { return nil }
            // Re-select after SEARCH: a changed UIDVALIDITY must not turn a
            // unique old UID into a receipt for a newly rebuilt folder.
            selected = nil
            let target = try await gmailIdentities(accountID: accountID, folder: destination, uids: [targetUID], expectedValidity: targetValidity)[targetUID]
            guard let target, target.valid, target.accountID == accountID, target.folder == destination,
                  target.validity == targetValidity, target.uid == targetUID,
                  target.globalID == sourceIdentity.globalID, target.messageID == sourceIdentity.messageID,
                  target.rawSize == sourceIdentity.rawSize else { return nil }
            return MailMoveReceipt(destinationValidity: targetValidity, destinationUID: targetUID, sourceUID: sourceIdentity.uid)
        } catch {
            // MOVE has already been acknowledged. Failure or cancellation of
            // its lookup preserves awaiting-sync, not a false local rollback.
            close(); return nil
        }
    }
    static func gmailIdentities(lines: [String], literals: [Data], allowed: Set<UInt64>, accountID: String, folder: String, validity: UInt64) throws -> [UInt64: GmailMessageIdentity] {
        let headers = try fetchedBodies(lines: lines, literals: literals, allowed: allowed)
        var groups: [String] = [], metadata: [UInt64: (String, UInt64)] = [:]
        func finish() throws {
            defer { groups = [] }
            guard !groups.isEmpty else { return }
            let text = groups.joined(separator: " ")
            guard let uidText = MIMEParser.capture(#"(?i)\bUID\s+(\d+)\b"#, text), let uid = UInt64(uidText), headers[uid] != nil else { return }
            guard let global = MIMEParser.capture(#"(?i)\bX-GM-MSGID\s+(\d+)\b"#, text), UInt64(global).map({ $0 > 0 }) == true,
                  let sizeText = MIMEParser.capture(#"(?i)\bRFC822.SIZE\s+(\d+)\b"#, text), let size = UInt64(sizeText), size > 0, metadata[uid] == nil else { throw MailError.message("Gmail全局邮件身份响应无效。") }
            metadata[uid] = (global, size)
        }
        for line in lines {
            if MIMEParser.capture(#"(?i)^\*\s+\d+\s+(FETCH)\s*\("#, line) != nil { try finish() }
            else if line.hasPrefix("* ") || MIMEParser.capture(#"(?i)^\S+\s+(OK|NO|BAD)\b"#, line) != nil { try finish(); continue }
            groups.append(line)
        }
        try finish()
        var result: [UInt64: GmailMessageIdentity] = [:]
        for (uid, header) in headers {
            guard header.count <= 65536, let (global, size) = metadata[uid] else { throw MailError.message("Gmail身份头信息超过范围或不完整。") }
            let parsed = MIMEParser.parse(header, accountID: accountID)
            let identity = GmailMessageIdentity(accountID: accountID, folder: folder, uid: uid, validity: validity, globalID: global, messageID: parsed.messageID, rawSize: size)
            if identity.valid { result[uid] = identity }
        }
        return result
    }
    private func searchUIDs() async throws -> Set<UInt64> {
        let reply = try await command("UID SEARCH ALL")
        var result: Set<UInt64> = [], received = false
        for line in reply.lines {
            let words = line.split(whereSeparator: \.isWhitespace)
            guard words.count >= 2, words[0] == "*", words[1].uppercased() == "SEARCH" else { continue }
            received = true
            for word in words.dropFirst(2) {
                guard let uid = UInt64(word), uid > 0, uid <= UInt64(UInt32.max) else { throw MailError.message("服务器返回了无效 UID 清单。") }
                result.insert(uid)
            }
        }
        guard received else { throw MailError.message("服务器未返回 UID 清单，未更新同步断点。") }
        return result
    }
    static func vanishedUIDs(_ line: String) throws -> Set<UInt64> {
        let text = line.replacingOccurrences(of: "(EARLIER)", with: "", options: .caseInsensitive)
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count == 3, words[0] == "*", words[1].uppercased() == "VANISHED" else { throw MailError.message("无效 VANISHED 响应。") }
        var result: Set<UInt64> = []
        for token in words[2].split(separator: ",", omittingEmptySubsequences: false) {
            let ends = token.split(separator: ":", omittingEmptySubsequences: false)
            guard (1...2).contains(ends.count), let first = UInt64(ends[0]), let last = UInt64(ends.last!), first > 0, last > 0,
                  first <= UInt64(UInt32.max), last <= UInt64(UInt32.max), max(first, last) - min(first, last) < 1_000_000 else { throw MailError.message("VANISHED UID 范围无效或过大。") }
            for uid in min(first, last)...max(first, last) { result.insert(uid) }
            guard result.count <= 1_000_000 else { throw MailError.message("VANISHED 响应超过缓存限制。") }
        }
        return result
    }
    /// RFC 2177: renew before the server's 30-minute IDLE limit. DONE is sent
    /// exactly once; cancellation closes this dedicated socket promptly.
    public func waitForChange(folder: String, renewAfter seconds: Double = 25 * 60) async throws -> Bool {
        guard supportsIdle else { return false }
        do {
            _ = try await select(folder)
            let tag = nextTag(); try await write(Data("\(tag) IDLE\r\n".utf8))
            var changed = false
            while true {
                let response = try await line()
                if response.hasPrefix("+") { break }
                if response.hasPrefix(tag + " ") || response.uppercased().hasPrefix("* BYE") { throw MailError.message("服务器未接受实时邮箱监听。") }
                changed = changed || Self.isMailboxChange(response)
            }
            idleTag = tag
            let renewal = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(max(0.05, seconds))); try await self?.endIdle(tag) } catch { }
            }
            defer { renewal.cancel() }
            if changed { try await endIdle(tag) }
            while true {
                let response = try await line(timeout: max(90, seconds + 30))
                if response.hasPrefix(tag + " ") {
                    guard response.uppercased().hasPrefix(tag + " OK") else { throw MailError.message("实时邮箱监听结束失败。") }
                    return changed
                }
                if response.uppercased().hasPrefix("* BYE") { throw MailError.message("服务器断开实时邮箱监听。") }
                if Self.isMailboxChange(response) { changed = true; try await endIdle(tag) }
            }
        } catch { close(); throw error }
    }
    private func endIdle(_ tag: String) async throws {
        guard idleTag == tag else { return }; idleTag = nil
        try await write(Data("DONE\r\n".utf8))
    }
    private static func isMailboxChange(_ line: String) -> Bool {
        MIMEParser.capture(#"(?i)^\*\s+((?:\d+\s+(?:EXISTS|EXPUNGE|FETCH|RECENT)\b)|VANISHED\b)"#, line) != nil
    }
    public func fetch(folder: String, uid: UInt64, expectedValidity: UInt64) async throws -> Data {
        let v = try await select(folder)
        guard v == expectedValidity else { throw MailError.message("文件夹已在服务器重建，请重新同步。") }
        let result = try await command("UID FETCH \(uid) (UID BODY.PEEK[])")
        guard let data = result.literals.first, !data.isEmpty else { throw MailError.message("服务器未返回邮件正文。") }; return data
    }
    public struct DownloadTiming: Sendable { public var sizeSeconds: Double = 0; public var bodySeconds: Double = 0; public var bytes = 0; public var count = 0 }
    public private(set) var downloadTiming = DownloadTiming()
    public func fetchMany(folder: String, uids: [UInt64], expectedValidity: UInt64, maximumBatchBytes: UInt64 = 64 * 1024 * 1024 - 128 * 1024, maximumMessageBytes: UInt64 = 64 * 1024 * 1024) async throws -> [UInt64: Data] {
        guard !uids.isEmpty, uids.count <= 64, Set(uids).count == uids.count,
              uids.allSatisfy({ $0 > 0 && $0 <= UInt64(UInt32.max) }) else { throw MailError.message("批量读取的 UID 无效。") }
        let current = try await select(folder)
        guard current == expectedValidity else { throw MailError.message("文件夹已在服务器重建，请重新同步。") }
        let set = uids.map(String.init).joined(separator: ",")
        let sizeStarted = ProcessInfo.processInfo.systemUptime
        let metadata = try await command("UID FETCH \(set) (UID RFC822.SIZE)")
        downloadTiming.sizeSeconds = ProcessInfo.processInfo.systemUptime - sizeStarted
        var sizes: [UInt64: UInt64] = [:]
        for line in metadata.lines {
            guard let rawUID = MIMEParser.capture(#"(?i)\bUID\s+(\d+)\b"#, line), let uid = UInt64(rawUID),
                  let rawSize = MIMEParser.capture(#"(?i)\bRFC822.SIZE\s+(\d+)\b"#, line), let size = UInt64(rawSize), Set(uids).contains(uid) else { continue }
            if let old = sizes[uid], old != size { throw MailError.message("批量邮件大小响应不一致。") }
            sizes[uid] = size
        }
        let eligible = Self.boundedBodyBatch(uids: uids.filter { (sizes[$0] ?? UInt64.max) <= maximumMessageBytes }, sizes: sizes, maximumBytes: maximumBatchBytes)
        guard !eligible.isEmpty else { return [:] }
        let bodySet = eligible.map(String.init).joined(separator: ",")
        let bodyStarted = ProcessInfo.processInfo.systemUptime
        let reply = try await command("UID FETCH \(bodySet) (UID BODY.PEEK[])")
        let bodies = try Self.fetchedBodies(lines: reply.lines, literals: reply.literals, allowed: Set(eligible))
        downloadTiming.bodySeconds = ProcessInfo.processInfo.systemUptime - bodyStarted
        downloadTiming.bytes = bodies.values.reduce(0) { $0 + $1.count }; downloadTiming.count = bodies.count
        return bodies
    }
    public func fetchForSync(accountID: String, folder: String, uid: UInt64, expectedValidity: UInt64, attachmentLimit: Int) async throws -> MailSyncFetch {
        guard try await select(folder) == expectedValidity else { throw MailError.message("文件夹已重建，请重新同步。") }
        let size = try await command("UID FETCH \(uid) (UID RFC822.SIZE)")
        guard let bytes = MIMEParser.capture(#"(?i)RFC822.SIZE\s+(\d+)"#, size.lines.joined(separator: " ")).flatMap(Int.init) else { throw MailError.message("服务器未返回邮件大小。") }
        if bytes <= attachmentLimit { return .raw(try await fetch(folder: folder, uid: uid, expectedValidity: expectedValidity)) }
        let metadata = try await command("UID FETCH \(uid) (UID BODYSTRUCTURE BODY.PEEK[HEADER])")
        let headers = try Self.sectionLiteral(metadata, section: "HEADER")
        var mail = MIMEParser.parse(headers, accountID: accountID, folder: folder, uid: uid, validity: expectedValidity)
        mail.raw = Data(); mail.attachments = []; mail.contentAvailability = .complete
        let parts = try IMAPBodyStructure.parts(lines: metadata.lines, literals: metadata.literals)
        var remaining = 32 * 1024 * 1024
        for part in parts {
            try Task.checkCancellation()
            let budget = part.body ? min(part.encodedBytes, 4 * 1024 * 1024) : part.encodedBytes
            let eligible = part.body || (part.decodedUpperBound <= attachmentLimit && budget <= remaining)
            if eligible && budget > 0 {
                let data = try await fetchSection(part.section, folder: folder, uid: uid, expectedValidity: expectedValidity, count: budget)
                let head: Data
                if part.section == "TEXT" { head = headers }
                else { let result = try await command("UID FETCH \(uid) (BODY.PEEK[\(part.section).MIME])"); head = try Self.sectionLiteral(result, section: part.section + ".MIME") }
                var decoded = MIMEParser.parse(head + Data("\r\n".utf8) + data, accountID: accountID)
                if part.body { if !decoded.text.isEmpty { mail.text += (mail.text.isEmpty ? "" : "\n\n") + decoded.text }; if !decoded.html.isEmpty { mail.html += decoded.html } }
                else {
                    if decoded.attachments.isEmpty { let bytes = part.encoding.uppercased() == "BASE64" ? Data(base64Encoded: data, options: .ignoreUnknownCharacters) ?? Data() : part.encoding.uppercased() == "QUOTED-PRINTABLE" ? MIMEParser.quotedPrintable(data) : data; decoded.attachments = [MailAttachment(name: part.name ?? "附件", mimeType: part.mimeType, data: bytes, contentID: part.contentID)] }
                    for i in decoded.attachments.indices { decoded.attachments[i].id = MailStore.hash(mail.id + ":attachment:" + String(mail.attachments.count)); mail.attachments.append(decoded.attachments[i]) }
                }
                remaining -= budget
            } else if !part.body {
                var attachment = MailAttachment(name: part.name ?? "附件", mimeType: part.mimeType, data: Data(), contentID: part.contentID)
                attachment.id = MailStore.hash(mail.id + ":attachment:" + String(mail.attachments.count)); attachment.byteCount = part.decodedUpperBound
                attachment.remoteReference = .init(accountID: accountID, folder: folder, uid: uid, validity: expectedValidity, section: part.section, encoding: part.encoding, encodedBytes: part.encodedBytes)
                mail.attachments.append(attachment)
            }
        }
        if mail.text.isEmpty { mail.text = MIMEParser.plainText(mail.html) }
        return .selective(mail)
    }
    public func fetchSection(_ section: String, folder: String, uid: UInt64, expectedValidity: UInt64, count: Int) async throws -> Data {
        guard section.range(of: #"^(TEXT|[1-9]\d*(?:\.[1-9]\d*)*)$"#, options: .regularExpression) != nil, count > 0, count <= 64 * 1024 * 1024 else { throw MailError.message("附件读取参数无效或超过本机读取限制。") }
        guard try await select(folder) == expectedValidity else { throw MailError.message("文件夹已重建，请重新同步。") }
        let response = try await command("UID FETCH \(uid) (BODY.PEEK[\(section)]<0.\(count)>)")
        return try Self.sectionLiteral(response, section: section)
    }
    private static func sectionLiteral(_ response: Reply, section: String) throws -> Data {
        var index = 0
        for line in response.lines where line.range(of: #"\{\d+\+?\}$"#, options: .regularExpression) != nil {
            if line.range(of: "BODY[" + section + "]", options: .caseInsensitive) != nil, index < response.literals.count { return response.literals[index] }
            index += 1
        }
        throw MailError.message("服务器未返回请求的邮件部件。")
    }
    static func boundedBodyBatch(uids: [UInt64], sizes: [UInt64: UInt64], maximumBytes: UInt64 = 64 * 1024 * 1024) -> [UInt64] {
        var selected: [UInt64] = [], used: UInt64 = 0
        for uid in uids {
            guard let size = sizes[uid], size > 0, size <= maximumBytes, size <= maximumBytes - used else { continue }
            selected.append(uid); used += size
        }
        return selected
    }
    /// Associate literals with their enclosing FETCH response, including servers
    /// that put UID after BODY. Never assign a body by response order alone.
    static func fetchedBodies(lines: [String], literals: [Data], allowed: Set<UInt64>) throws -> [UInt64: Data] {
        var result: [UInt64: Data] = [:], fetchLines: [String] = [], bodies: [Data] = []
        var literal = 0
        func finish() throws {
            defer { fetchLines = []; bodies = [] }
            guard !bodies.isEmpty else { return }
            guard bodies.count == 1, let token = MIMEParser.capture(#"(?i)\bUID\s+(\d+)\b"#, fetchLines.joined(separator: " ")),
                  let uid = UInt64(token), allowed.contains(uid), result[uid] == nil, !bodies[0].isEmpty else {
                throw MailError.message("批量正文与 UID 无法安全对应，读取已停止。")
            }
            result[uid] = bodies[0]
        }
        for line in lines {
            if MIMEParser.capture(#"(?i)^\S+\s+(OK|NO|BAD)\b"#, line) != nil { try finish(); continue }
            if MIMEParser.capture(#"(?i)^\*\s+\d+\s+(FETCH)\s*\("#, line) != nil { try finish() }
            else if line.hasPrefix("* ") { try finish(); continue }
            fetchLines.append(line)
            if MIMEParser.capture(#"\{(\d+)\+?\}$"#, line) != nil {
                guard literal < literals.count else { throw MailError.message("批量正文响应不完整。") }
                bodies.append(literals[literal]); literal += 1
            }
        }
        try finish()
        guard literal == literals.count, !result.isEmpty else { throw MailError.message("服务器未返回可读取的批量正文。") }
        return result
    }
    public func list(accountID: String) async throws -> [MailFolder] {
        let r = try await command("LIST \"\" \"*\""); var lines = r.lines
        for (i, literal) in r.literals.enumerated() {
            if let row = lines.firstIndex(where: { $0.hasSuffix("{\(literal.count)}") }) { lines[row] = lines[row].replacingOccurrences(of: "{\(literal.count)}", with: "\"" + (String(data: literal, encoding: .utf8) ?? "") + "\"") }
            if i > 10000 { break }
        }; return MailTransport.parseFolders(lines.joined(separator: "\n"), accountID: accountID)
    }
    public func store(folder: String, uid: UInt64, flag: String, enabled: Bool, expectedValidity: UInt64? = nil) async throws {
        selected = nil; let current = try await select(folder)
        if let expectedValidity, current != expectedValidity { throw MailError.message("文件夹已重建，未执行标记，请重新同步。") }
        _ = try await command("UID STORE \(uid) \(enabled ? "+" : "-")FLAGS.SILENT (\(flag))")
    }
    struct UIDFlagBatch {
        var uids: [UInt64]
        var command: String
    }
    static func validateBulkFolder(_ folder: String) throws {
        guard !folder.isEmpty, !folder.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw MailError.message("邮箱字段包含无效控制字符。") }
        _ = try quote(folder)
    }
    static func flagBatches(_ values: [UInt64], flag: String, enabled: Bool, maximumCommandBytes: Int = 4096, maximumUIDs: Int = 500) throws -> [UIDFlagBatch] {
        guard ["\\Seen", "\\Flagged"].contains(flag), values.allSatisfy({ $0 > 0 && $0 <= UInt64(UInt32.max) }) else { throw MailError.message("批量邮件标记或 UID 无效。") }
        guard maximumCommandBytes >= 96, maximumUIDs > 0 else { throw MailError.message("批量邮件命令限制无效。") }
        let sorted = Array(Set(values)).sorted()
        guard !sorted.isEmpty else { return [] }
        var ranges: [[UInt64]] = [], current: [UInt64] = []
        for value in sorted {
            if let last = current.last, value != last + 1 { ranges.append(current); current = [] }
            current.append(value)
        }
        if !current.isEmpty { ranges.append(current) }
        var result: [UIDFlagBatch] = [], tokens: [String] = [], ids: [UInt64] = []
        let suffix = " \(enabled ? "+" : "-")FLAGS.SILENT (\(flag))"
        // Reserve enough for the generated tag and CRLF, not just UID syntax.
        let setBudget = min(4096, maximumCommandBytes) - 64
        func flush() {
            guard !ids.isEmpty else { return }
            result.append(UIDFlagBatch(uids: ids, command: "UID STORE " + tokens.joined(separator: ",") + suffix)); tokens = []; ids = []
        }
        for range in ranges {
            let token = range.count == 1 ? String(range[0]) : "\(range[0]):\(range[range.count - 1])"
            guard token.utf8.count <= setBudget else { throw MailError.message("UID 范围超过批量命令长度限制。") }
            if range.count > maximumUIDs {
                flush(); tokens = [token]; ids = range; flush(); continue
            }
            let bytes = tokens.reduce(0) { $0 + $1.utf8.count } + token.utf8.count + tokens.count
            if !ids.isEmpty && (ids.count + range.count > maximumUIDs || bytes > setBudget) { flush() }
            tokens.append(token); ids.append(contentsOf: range)
        }
        flush(); return result
    }
    public func storeMany(folder: String, uids: [UInt64], flag: String, enabled: Bool, expectedValidity: UInt64) async throws -> MailBulkFlagReceipt {
        let batches = try Self.flagBatches(uids, flag: flag, enabled: enabled)
        try Self.validateBulkFolder(folder)
        guard !batches.isEmpty else { return MailBulkFlagReceipt(uids: [], uidValidity: expectedValidity) }
        guard expectedValidity > 0 && expectedValidity <= UInt64(UInt32.max) else { throw MailError.message("UIDVALIDITY 无效，未执行批量标记。") }
        let current: UInt64
        do {
            selected = nil; current = try await select(folder)
            guard current == expectedValidity else { throw MailError.message("文件夹已重建，未执行批量标记，请重新同步。") }
        } catch { close(); throw error }
        return await applyFlagBatches(batches, uidValidity: current)
    }
    public func markFolderRead(folder: String, expectedValidity: UInt64? = nil) async throws -> MailBulkFlagReceipt {
        try Self.validateBulkFolder(folder)
        let current: UInt64
        let batches: [UIDFlagBatch]
        do {
            if let expectedValidity { guard expectedValidity > 0 && expectedValidity <= UInt64(UInt32.max) else { throw MailError.message("UIDVALIDITY 无效，未执行批量标记。") } }
            selected = nil; current = try await select(folder)
            if let expectedValidity { guard current == expectedValidity else { throw MailError.message("文件夹已重建，未执行批量标记，请重新同步。") } }
            let snapshot = try await command("UID SEARCH UNSEEN")
            var uids: [UInt64] = [], received = false
            for line in snapshot.lines {
                let parts = line.split(whereSeparator: \.isWhitespace)
                guard parts.count >= 2, parts[0] == "*", parts[1].uppercased() == "SEARCH" else { continue }
                received = true
                for value in parts.dropFirst(2) {
                    guard let uid = UInt64(value), uid > 0 && uid <= UInt64(UInt32.max) else { throw MailError.message("服务器返回了无效的未读 UID 快照，未执行标记。") }
                    uids.append(uid)
                }
            }
            guard received else { throw MailError.message("服务器未返回未读 UID 快照，未执行标记。") }
            batches = try Self.flagBatches(uids, flag: "\\Seen", enabled: true)
        } catch { close(); throw error }
        return await applyFlagBatches(batches, uidValidity: current)
    }
    private func applyFlagBatches(_ batches: [UIDFlagBatch], uidValidity: UInt64) async -> MailBulkFlagReceipt {
        var acknowledged: [UInt64] = []
        for batch in batches {
            do { try Task.checkCancellation(); _ = try await command(batch.command); acknowledged.append(contentsOf: batch.uids) }
            catch { close(); return MailBulkFlagReceipt(uids: acknowledged, uidValidity: uidValidity, failure: String(error.localizedDescription.prefix(240))) }
        }
        return MailBulkFlagReceipt(uids: acknowledged, uidValidity: uidValidity)
    }
    public func move(folder: String, uid: UInt64, destination: String, expectedValidity: UInt64? = nil) async throws -> MailMoveReceipt {
        selected = nil; let current = try await select(folder)
        if let expectedValidity, current != expectedValidity { throw MailError.message("文件夹已重建，未执行移动，请重新同步。") }
        let capabilities = try await command("CAPABILITY").lines.joined(separator: " ").uppercased()
        let reply: Reply
        if capabilities.contains("MOVE") { reply = try await command("UID MOVE \(uid) \(try Self.quote(destination))") }
        else if capabilities.contains("UIDPLUS") {
            reply = try await command("UID COPY \(uid) \(try Self.quote(destination))")
            _ = try await command("UID STORE \(uid) +FLAGS.SILENT (\\Deleted)")
            _ = try await command("UID EXPUNGE \(uid)")
        } else { throw MailError.message("此服务器不支持安全移动。原邮件已保留。") }
        return MailMoveReceipt.parse(reply.lines.joined(separator: "\n") + "\n" + reply.completion)
    }
    public func create(_ path: String) async throws { _ = try await command("CREATE \(try Self.quote(path))") }
    public func append(folder: String, raw: Data) async throws {
        let tag = nextTag(); try await write(Data("\(tag) APPEND \(try Self.quote(folder)) (\\Seen) {\(raw.count)}\r\n".utf8))
        while true {
            let l = try await line()
            if l.hasPrefix("+") { break }
            if l.hasPrefix(tag) { throw MailError.message("服务器拒绝保存已发送邮件。") }
        }
        try await write(raw + Data("\r\n".utf8))
        _ = try await readResponse(tag)
    }
    public struct Reply { var lines: [String]; var literals: [Data]; var completion: String = "" }
    public func command(_ text: String, sensitive: Bool = false, maximumLiteralBytes: Int = 64 * 1024 * 1024) async throws -> Reply {
        try Task.checkCancellation()
        let tag = nextTag(); try await write(Data("\(tag) \(text)\r\n".utf8))
        do { return try await readResponse(tag, maximumLiteralBytes: maximumLiteralBytes) }
        catch is CancellationError { close(); throw CancellationError() }
        catch { close(); if sensitive { throw MailError.message("邮箱认证失败，请确认已开启 IMAP 并使用客户端授权码。") }; throw error }
    }
    private func readResponse(_ tag: String, retainLines: Bool = true, allowLiterals: Bool = true, maximumLiteralBytes: Int = 64 * 1024 * 1024, onLine: ((String) -> Void)? = nil) async throws -> Reply {
        var lines: [String] = [], literals: [Data] = [], bytes = 0
        for _ in 0..<100000 {
            try Task.checkCancellation()
            let l = try await line()
            let lineBytes = l.utf8.count + 2
            guard lineBytes <= maximumResponseBytes - bytes else { throw MailError.message("邮件服务器的总响应超过缓存限制，读取已停止。") }; bytes += lineBytes
            if l.hasPrefix(tag + " ") {
                guard l.uppercased().hasPrefix(tag + " OK") else { throw MailError.message(String(l.dropFirst(tag.count + 1))) }; return Reply(lines: lines, literals: literals, completion: l)
            }
            if l.uppercased().hasPrefix("* BYE") { close(); throw MailError.message("服务器断开了邮件连接，请重新同步。") }
            if retainLines { lines.append(l) }; onLine?(l)
            if l.hasSuffix("}"), let opening = l.lastIndex(of: "{") {
                var rawSize = l[l.index(after: opening)..<l.index(before: l.endIndex)]
                if rawSize.last == "+" { rawSize = rawSize.dropLast() }
                guard let size = Int(rawSize), size >= 0 else { throw MailError.message("邮件服务器返回了无效正文长度。") }
                guard allowLiterals else { throw MailError.message("邮件库存响应包含了非预期正文，读取已停止。") }
                guard size <= 64 * 1024 * 1024 else { throw MailError.message("此邮件超过 64 MB，请在网页邮箱下载。") }
                guard size <= maximumLiteralBytes else { throw MailError.message("邮件服务器返回的片段超过本次查询限制。") }
                guard size <= maximumResponseBytes - bytes else { throw MailError.message("邮件服务器的总响应超过缓存限制，读取已停止。") }; bytes += size
                literals.append(try await read(size))
            }
        }; throw MailError.message("邮件服务器响应超出限制。")
    }
    private func nextTag() -> String { sequence += 1; return String(format: "S%05d", sequence) }
    private func line(timeout: TimeInterval = 90) async throws -> String {
        try Task.checkCancellation()
        var searchOffset = bufferOffset
        while true {
            if let range = buffer.range(of: Data([13, 10]), in: searchOffset..<buffer.count) {
                guard range.lowerBound - bufferOffset <= 4 * 1024 * 1024 else { throw MailError.message("邮件服务器响应行过长。") }
                let result = String(data: buffer[bufferOffset..<range.lowerBound], encoding: .utf8) ?? String(data: buffer[bufferOffset..<range.lowerBound], encoding: .isoLatin1) ?? ""
                consume(range.upperBound - bufferOffset); return result
            }
            guard buffer.count - bufferOffset <= 4 * 1024 * 1024 else { throw MailError.message("邮件服务器响应行过长。") }
            searchOffset = max(bufferOffset, buffer.count - 1); try await receive(timeout: timeout)
        }
    }
    private func read(_ count: Int) async throws -> Data {
        var result = Data(); result.reserveCapacity(min(count, 1024 * 1024))
        while result.count < count {
            try Task.checkCancellation()
            if bufferOffset == buffer.count { try await receive() }
            let length = min(count - result.count, buffer.count - bufferOffset)
            result.append(buffer[bufferOffset..<bufferOffset + length]); consume(length)
        }
        return result
    }
    private func consume(_ count: Int) {
        bufferOffset += count
        if bufferOffset == buffer.count { buffer = Data(); bufferOffset = 0 }
        else if bufferOffset >= 256 * 1024 { buffer = Data(buffer[bufferOffset...]); bufferOffset = 0 }
    }
    private func receive(timeout: TimeInterval = 90) async throws {
        guard let c = connection else { throw MailError.message("邮件连接未建立。") }
        let data = try await MailNetworkIO.receive(c, timeout: timeout)
        guard connection === c else { throw CancellationError() }; buffer.append(data)
    }
    private func write(_ data: Data) async throws {
        guard let c = connection else { throw MailError.message("邮件连接未建立。") }
        try await MailNetworkIO.write(data, to: c)
    }
    public static func quote(_ value: String) throws -> String {
        guard !value.contains(where: { $0.isNewline || $0 == "\0" }) else { throw MailError.message("邮箱字段包含无效控制字符。") }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
