import Foundation
import Network

/// One serialized IMAP session. Reads literals by byte count; never marks fetched mail as read.
public actor IMAPConnection {
    private var connection: NWConnection?
    private var buffer = Data()
    private var sequence = 0
    private var selected: String?
    private var validity: UInt64 = 0
    public init() {}
    public var connected: Bool { connection != nil }

    public func connect(host: String, port: Int, email: String, password: String, tls: Bool = true, oauth: Bool = false) async throws {
        close()
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else { throw MailError.message("IMAP 端口无效。") }
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
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = ConnectionGate(continuation)
            c.stateUpdateHandler = { state in
                switch state { case .ready: gate.finish(nil); case .failed(let error): gate.finish(error); case .cancelled: gate.finish(MailError.message("邮件连接已关闭。")); default: break }
            }
            c.start(queue: DispatchQueue.global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + 20) { if gate.finish(MailError.message("连接邮件服务器超时。")) { c.cancel() } }
        }
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
    public func close() { connection?.cancel(); connection = nil; buffer = Data(); selected = nil; validity = 0 }
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
        let result = try await command("UID FETCH 1:* (UID FLAGS)")
        return (v, MailTransport.parseFlags(result.lines.joined(separator: "\n")))
    }
    public func fetch(folder: String, uid: UInt64, expectedValidity: UInt64) async throws -> Data {
        let v = try await select(folder)
        guard v == expectedValidity else { throw MailError.message("文件夹已在服务器重建，请重新同步。") }
        let result = try await command("UID FETCH \(uid) (UID BODY.PEEK[])")
        guard let data = result.literals.first, !data.isEmpty else { throw MailError.message("服务器未返回邮件正文。") }; return data
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
        let tag = nextTag(); try await write(Data("\(tag) \(text)\r\n".utf8))
        do { return try await readResponse(tag) } catch { if sensitive { throw MailError.message("邮箱认证失败，请确认已开启 IMAP 并使用客户端授权码。") }; throw error }
    }
    private func readResponse(_ tag: String) async throws -> Reply {
        var lines: [String] = []; var literals: [Data] = []
        for _ in 0..<100000 {
            let l = try await line()
            if l.hasPrefix(tag + " ") {
                guard l.uppercased().hasPrefix(tag + " OK") else { throw MailError.message(String(l.dropFirst(tag.count + 1))) }; return Reply(lines: lines, literals: literals, completion: l)
            }
            if l.uppercased().hasPrefix("* BYE") { close(); throw MailError.message("服务器断开了邮件连接，请重新同步。") }
            lines.append(l)
            if let size = Int(MIMEParser.capture(#"\{(\d+)\+?\}$"#, l) ?? "") { guard size <= 64 * 1024 * 1024 else { throw MailError.message("此邮件超过 64 MB，请在网页邮箱下载。") }; literals.append(try await read(size)) }
        }; throw MailError.message("邮件服务器响应超出限制。")
    }
    private func nextTag() -> String { sequence += 1; return String(format: "S%05d", sequence) }
    private func line() async throws -> String {
        while buffer.range(of: Data([13, 10])) == nil { try await receive(); guard buffer.count < 4 * 1024 * 1024 else { throw MailError.message("邮件服务器响应行过长。") } }
        let range = buffer.range(of: Data([13, 10]))!; let result = buffer[..<range.lowerBound]; buffer.removeSubrange(..<range.upperBound)
        return String(data: result, encoding: .utf8) ?? String(data: result, encoding: .isoLatin1) ?? ""
    }
    private func read(_ count: Int) async throws -> Data {
        while buffer.count < count { try await receive() }; let d = Data(buffer.prefix(count)); buffer.removeFirst(count); return d
    }
    private func receive() async throws {
        guard let c = connection else { throw MailError.message("邮件连接未建立。") }
        let data: Data = try await withCheckedThrowingContinuation { cont in
            let gate = DataGate(cont)
            c.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, done, error in
                if let error { gate.finish(.failure(error)) }
                else if let data, !data.isEmpty { gate.finish(.success(data)) }
                else { gate.finish(.failure(MailError.message(done ? "邮件服务器已关闭连接。" : "邮件服务器返回了空响应。"))) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 90) { if gate.finish(.failure(MailError.message("读取邮件服务器超时。"))) { c.cancel() } }
        }; buffer.append(data)
    }
    private func write(_ data: Data) async throws {
        guard let c = connection else { throw MailError.message("邮件连接未建立。") }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in c.send(content: data, completion: .contentProcessed { error in if let error { cont.resume(throwing: error) } else { cont.resume() } }) }
    }
    public static func quote(_ value: String) throws -> String {
        guard !value.contains(where: { $0.isNewline || $0 == "\0" }) else { throw MailError.message("邮箱字段包含无效控制字符。") }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

private final class ConnectionGate: @unchecked Sendable {
    private let lock = NSLock(); private var continuation: CheckedContinuation<Void, Error>?
    init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
    @discardableResult func finish(_ error: Error?) -> Bool { lock.lock(); let c = continuation; continuation = nil; lock.unlock(); guard let c else { return false }; if let error { c.resume(throwing: error) } else { c.resume() }; return true }
}
private final class DataGate: @unchecked Sendable {
    private let lock = NSLock(); private var continuation: CheckedContinuation<Data, Error>?
    init(_ continuation: CheckedContinuation<Data, Error>) { self.continuation = continuation }
    @discardableResult func finish(_ result: Result<Data, Error>) -> Bool { lock.lock(); let c = continuation; continuation = nil; lock.unlock(); guard let c else { return false }; c.resume(with: result); return true }
}
