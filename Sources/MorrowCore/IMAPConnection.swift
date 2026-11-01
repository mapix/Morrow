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
    private let maximumResponseBytes: Int
    public init() { maximumResponseBytes = 96 * 1024 * 1024 }
    init(maximumResponseBytes: Int) { self.maximumResponseBytes = max(1, maximumResponseBytes) }
    public var connected: Bool { connection != nil }

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
    }
    public func close() { connection?.cancel(); connection = nil; buffer = Data(); bufferOffset = 0; selected = nil; validity = 0 }
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
    public func fetch(folder: String, uid: UInt64, expectedValidity: UInt64) async throws -> Data {
        let v = try await select(folder)
        guard v == expectedValidity else { throw MailError.message("文件夹已在服务器重建，请重新同步。") }
        let result = try await command("UID FETCH \(uid) (UID BODY.PEEK[])")
        guard let data = result.literals.first, !data.isEmpty else { throw MailError.message("服务器未返回邮件正文。") }; return data
    }
    public struct DownloadTiming: Sendable { public var sizeSeconds: Double = 0; public var bodySeconds: Double = 0; public var bytes = 0; public var count = 0 }
    public private(set) var downloadTiming = DownloadTiming()
    public func fetchMany(folder: String, uids: [UInt64], expectedValidity: UInt64, maximumBatchBytes: UInt64 = 64 * 1024 * 1024 - 128 * 1024) async throws -> [UInt64: Data] {
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
        let eligible = Self.boundedBodyBatch(uids: uids, sizes: sizes, maximumBytes: maximumBatchBytes)
        guard !eligible.isEmpty else { return [:] }
        let bodySet = eligible.map(String.init).joined(separator: ",")
        let bodyStarted = ProcessInfo.processInfo.systemUptime
        let reply = try await command("UID FETCH \(bodySet) (UID BODY.PEEK[])")
        let bodies = try Self.fetchedBodies(lines: reply.lines, literals: reply.literals, allowed: Set(eligible))
        downloadTiming.bodySeconds = ProcessInfo.processInfo.systemUptime - bodyStarted
        downloadTiming.bytes = bodies.values.reduce(0) { $0 + $1.count }; downloadTiming.count = bodies.count
        return bodies
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
    public func command(_ text: String, sensitive: Bool = false) async throws -> Reply {
        try Task.checkCancellation()
        let tag = nextTag(); try await write(Data("\(tag) \(text)\r\n".utf8))
        do { return try await readResponse(tag) }
        catch is CancellationError { close(); throw CancellationError() }
        catch { close(); if sensitive { throw MailError.message("邮箱认证失败，请确认已开启 IMAP 并使用客户端授权码。") }; throw error }
    }
    private func readResponse(_ tag: String, retainLines: Bool = true, allowLiterals: Bool = true, onLine: ((String) -> Void)? = nil) async throws -> Reply {
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
                guard size <= maximumResponseBytes - bytes else { throw MailError.message("邮件服务器的总响应超过缓存限制，读取已停止。") }; bytes += size
                literals.append(try await read(size))
            }
        }; throw MailError.message("邮件服务器响应超出限制。")
    }
    private func nextTag() -> String { sequence += 1; return String(format: "S%05d", sequence) }
    private func line() async throws -> String {
        try Task.checkCancellation()
        var searchOffset = bufferOffset
        while true {
            if let range = buffer.range(of: Data([13, 10]), in: searchOffset..<buffer.count) {
                guard range.lowerBound - bufferOffset <= 4 * 1024 * 1024 else { throw MailError.message("邮件服务器响应行过长。") }
                let result = String(data: buffer[bufferOffset..<range.lowerBound], encoding: .utf8) ?? String(data: buffer[bufferOffset..<range.lowerBound], encoding: .isoLatin1) ?? ""
                consume(range.upperBound - bufferOffset); return result
            }
            guard buffer.count - bufferOffset <= 4 * 1024 * 1024 else { throw MailError.message("邮件服务器响应行过长。") }
            searchOffset = max(bufferOffset, buffer.count - 1); try await receive()
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
    private func receive() async throws {
        guard let c = connection else { throw MailError.message("邮件连接未建立。") }
        let data = try await MailNetworkIO.receive(c)
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
