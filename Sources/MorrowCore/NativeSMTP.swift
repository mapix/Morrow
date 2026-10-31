import Foundation
import CMail

/// Native TLS SMTP, including a verified STARTTLS upgrade. Credentials are sent
/// only after TLS succeeds. This transport never accepts a trust override.
public enum NativeSMTP {
    public static func request(url: String, username: String, password: String, upload: Data?, from: String?, recipients: [String], startTLS: Bool, testOnly: Bool = false, oauth: Bool) async throws -> TransportReply {
        try await Task.detached(priority: .utility) {
            guard let endpoint = URLComponents(string: url), ["smtp", "smtps"].contains(endpoint.scheme ?? ""), let host = endpoint.host else { throw MailError.message("移动端仅通过原生 IMAP/POP/SMTP 连接。") }
            let port = endpoint.port ?? (endpoint.scheme == "smtps" ? 465 : 587)
            guard endpoint.scheme == "smtps" || startTLS else { throw MailError.message("SMTP 必须使用 TLS 或 STARTTLS。") }
            var error: Int32 = 0
            guard let pointer = sm_native_open(host, Int32(port), &error) else { throw MailError.message("SMTP 服务器连接失败。") }
            defer { sm_native_close(pointer) }
            let session = Session(pointer: pointer)
            if endpoint.scheme == "smtps" { try session.secure(host) }
            try session.expect([220])
            var capabilities = try session.command("EHLO morrow.local", expected: [250])
            if endpoint.scheme == "smtp" {
                guard capabilities.uppercased().contains("STARTTLS") else { throw MailError.message("SMTP 服务器不支持 STARTTLS，未发送凭据。") }
                _ = try session.command("STARTTLS", expected: [220])
                guard session.buffer.isEmpty else { throw MailError.message("SMTP TLS 升级收到非预期数据。") }
                try session.secure(host)
                capabilities = try session.command("EHLO morrow.local", expected: [250])
            }
            try clean(username); try clean(password)
            if oauth {
                guard capabilities.uppercased().contains("XOAUTH2") else { throw MailError.message("SMTP 服务器不支持 OAuth。") }
                let auth = Data("user=\(username)\u{1}auth=Bearer \(password)\u{1}\u{1}".utf8).base64EncodedString()
                try session.write("AUTH XOAUTH2 " + auth + "\r\n")
                let reply = try session.reply()
                if reply.code == 334 { try session.write("\r\n"); _ = try session.reply(); throw MailError.message("SMTP OAuth 授权未被接受，请重新核对邮件权限。") }
                guard reply.code == 235 else { throw MailError.message("SMTP OAuth 认证失败（\(reply.code)）。") }
            } else if capabilities.uppercased().contains("PLAIN") {
                let auth = Data("\0\(username)\0\(password)".utf8).base64EncodedString()
                _ = try session.command("AUTH PLAIN " + auth, expected: [235])
            } else if capabilities.uppercased().contains("LOGIN") {
                _ = try session.command("AUTH LOGIN", expected: [334])
                _ = try session.command(Data(username.utf8).base64EncodedString(), expected: [334])
                _ = try session.command(Data(password.utf8).base64EncodedString(), expected: [235])
            } else { throw MailError.message("SMTP 服务器未提供受支持的认证机制。") }
            if !testOnly, let upload {
                guard let from, MailAddress.isValid(from), !recipients.isEmpty, recipients.allSatisfy(MailAddress.isValid) else { throw MailError.message("SMTP 发件人或收件人无效。") }
                _ = try session.command("MAIL FROM:<\(from)>", expected: [250])
                for recipient in recipients { _ = try session.command("RCPT TO:<\(recipient)>", expected: [250, 251]) }
                _ = try session.command("DATA", expected: [354])
                // Preserve bytes and dot-stuff lines; DATA terminal is distinct
                // from server acceptance. The caller persists sending/uncertain.
                var escaped = Data(); var lineStart = true
                for byte in upload { if lineStart && byte == 46 { escaped.append(46) }; escaped.append(byte); lineStart = byte == 10 }
                if !escaped.suffix(2).elementsEqual([13, 10]) { escaped.append(contentsOf: [13, 10]) }
                escaped.append(contentsOf: [46, 13, 10]); try session.write(escaped)
                try session.expect([250])
            }
            _ = try? session.command("QUIT", expected: [221])
            return TransportReply(data: Data(), headers: "SMTP TLS authenticated")
        }.value
    }
    private static func clean(_ value: String) throws { guard !value.isEmpty, !value.contains("\r"), !value.contains("\n"), !value.contains("\0"), !value.contains("\u{1}") else { throw MailError.message("SMTP 凭据包含无效控制字符。") } }
    private final class Session {
        let pointer: OpaquePointer; var buffer = Data()
        init(pointer: OpaquePointer) { self.pointer = pointer }
        func secure(_ host: String) throws { guard sm_native_start_tls(pointer, host) == 0 else { throw MailError.message("SMTP TLS 握手或服务器证书验证失败。") } }
        func write(_ text: String) throws { try write(Data(text.utf8)) }
        func write(_ data: Data) throws { let status = data.withUnsafeBytes { sm_native_write(pointer, $0.bindMemory(to: UInt8.self).baseAddress, data.count) }; guard status == 0 else { throw MailError.message("SMTP 写入失败；若已经提交正文，请先核对已发送邮件。") } }
        func line() throws -> String {
            while buffer.range(of: Data([13, 10])) == nil {
                var bytes = [UInt8](repeating: 0, count: 8192); var count = 0
                let status = sm_native_read(pointer, &bytes, bytes.count, &count)
                guard status == 0, count > 0 else { throw MailError.message("SMTP 响应中断或超时；若已经提交正文，请先核对已发送邮件。") }
                buffer.append(contentsOf: bytes.prefix(count)); guard buffer.count < 1024 * 1024 else { throw MailError.message("SMTP 响应超过限制。") }
            }
            let range = buffer.range(of: Data([13, 10]))!; let result = String(decoding: buffer[..<range.lowerBound], as: UTF8.self); buffer.removeSubrange(..<range.upperBound); return result
        }
        func reply() throws -> (code: Int, text: String) {
            var lines: [String] = []; var code: Int?
            for _ in 0..<200 {
                let row = try line(); guard row.utf8.count >= 4, let number = Int(row.prefix(3)), [" ", "-"].contains(String(row.dropFirst(3).prefix(1))), code == nil || code == number else { throw MailError.message("SMTP 响应格式无效。") }
                code = number; lines.append(row); if row.dropFirst(3).first == " " { return (number, lines.joined(separator: "\n")) }
            }
            throw MailError.message("SMTP 多行响应超过限制。")
        }
        @discardableResult func expect(_ codes: [Int]) throws -> String { let response = try reply(); guard codes.contains(response.code) else { throw MailError.message("SMTP 操作未被接受（\(response.code)）。") }; return response.text }
        func command(_ value: String, expected: [Int]) throws -> String { try write(value + "\r\n"); return try expect(expected) }
    }
}
