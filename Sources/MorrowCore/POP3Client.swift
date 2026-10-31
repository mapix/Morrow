import Foundation

public actor POP3Client {
    private let socket = MailSocket()
    public init() {}
    public var connected: Bool { get async { await socket.connected } }
    public func close() async { await socket.close() }
    public func quit() async { if await socket.connected { try? await send("QUIT"); _ = try? await status() }; await socket.close() }
    public func connect(host: String, port: Int, email: String, password: String, tls: Bool = true, oauth: Bool = false) async throws {
        try await socket.connect(host: host, port: port, tls: tls)
        _ = try await status()
        if oauth {
            let token = Data("user=\(email)\u{01}auth=Bearer \(password)\u{01}\u{01}".utf8).base64EncodedString()
            try await send("AUTH XOAUTH2 " + token); let line = try await socket.line()
            if line == "+" || line.hasPrefix("+ ") { try await send(token); _ = try await status() }
            else { guard line.hasPrefix("+OK") else { throw MailError.message("POP3 OAuth认证失败，请重新登录。") } }
        } else {
            guard !email.contains(where: \.isNewline), !password.contains(where: \.isNewline) else { throw MailError.message("邮箱凭据包含控制字符。") }
            do { try await send("USER " + email); _ = try await status(); try await send("PASS " + password); _ = try await status() }
            catch is CancellationError { throw CancellationError() }
            catch { throw MailError.message("POP3认证失败，请检查邮箱授权码及POP服务是否开启。") }
        }
    }
    public func inventory() async throws -> [String: Int] {
        try await send("UIDL"); _ = try await status()
        var result: [String: Int] = [:], bytes = 0
        do {
            while true {
                try Task.checkCancellation()
                let line = try await socket.lineData(); if line == Data([46]) { break }
                guard line.count + 2 <= 8 * 1024 * 1024 - bytes else { throw MailError.message("POP3邮件库存超过 8 MB 缓存限制。") }; bytes += line.count + 2
                let values = String(decoding: line, as: UTF8.self).split(whereSeparator: \.isWhitespace)
                if values.count == 2, let number = Int(values[0]), number > 0 { result[String(values[1])] = number }
            }
            return result
        } catch { await socket.close(); throw error }
    }
    public static func parseUIDL(_ text: String) -> [String: Int] {
        var result: [String: Int] = [:]
        for line in text.components(separatedBy: .newlines) { let values = line.split(whereSeparator: \.isWhitespace); if values.count == 2, let number = Int(values[0]), number > 0 { result[String(values[1])] = number } }; return result
    }
    public func fetch(number: Int, expectedUID: String) async throws -> Data {
        guard number > 0 else { throw MailError.message("POP3邮件序号无效。") }
        // Check UIDL in this session before RETR; message numbers can change between sessions.
        try await send("UIDL \(number)"); let identity = try await status()
        guard identity.split(whereSeparator: \.isWhitespace).last.map(String.init) == expectedUID else { throw MailError.message("POP3邮件编号已改变，请重新同步。") }
        try await send("RETR \(number)"); _ = try await status(); return try await multiline(maxBytes: 128 * 1024 * 1024)
    }
    private func send(_ text: String) async throws { try await socket.write(Data((text + "\r\n").utf8)) }
    private func status() async throws -> String {
        let line = try await socket.line(); guard line.hasPrefix("+OK") else { throw MailError.message("POP3服务器拒绝请求：" + String(line.prefix(200))) }; return line
    }
    private func multiline(maxBytes: Int) async throws -> Data {
        var data = Data()
        do {
            while true {
                try Task.checkCancellation()
                var line = try await socket.lineData(); if line == Data([46]) { break }
                if line.starts(with: [46, 46]) { line.removeFirst() }
                guard line.count + 2 <= maxBytes - data.count else { throw MailError.message("POP3邮件超过\(maxBytes / (1024 * 1024)) MB缓存限制。") }
                data.append(line); data.append(contentsOf: [13, 10])
            }
            return data
        } catch { await socket.close(); throw error }
    }
}
