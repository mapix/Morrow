import Foundation

struct IMAPBodyPart {
    var section: String
    var mimeType: String
    var encoding: String
    var encodedBytes: Int
    var name: String?
    var contentID: String?
    var body: Bool
    var decodedUpperBound: Int { encoding.uppercased() == "BASE64" ? ((encodedBytes + 3) / 4) * 3 : encodedBytes }
}

enum IMAPBodyStructure {
    indirect enum Value { case atom(String), list([Value]); var string: String? { if case .atom(let value) = self, value.uppercased() != "NIL" { return value }; return nil }; var values: [Value] { if case .list(let values) = self { return values }; return [] } }
    struct Parser {
        var bytes: [UInt8]; var offset = 0; var literals: [Data]; var literalIndex: Int; var tokens = 0
        mutating func parse(depth: Int = 0) throws -> Value {
            guard depth < 20, tokens < 20000 else { throw MailError.message("邮件结构超过解析限制。") }; tokens += 1
            while offset < bytes.count && [9,10,13,32].contains(bytes[offset]) { offset += 1 }
            guard offset < bytes.count else { throw MailError.message("邮件结构不完整。") }
            if bytes[offset] == 40 { offset += 1; var values: [Value] = []; while true { while offset < bytes.count && [9,10,13,32].contains(bytes[offset]) { offset += 1 }; guard offset < bytes.count else { throw MailError.message("邮件结构不完整。") }; if bytes[offset] == 41 { offset += 1; return .list(values) }; values.append(try parse(depth: depth + 1)) } }
            if bytes[offset] == 34 { offset += 1; var value: [UInt8] = []; while offset < bytes.count { let c = bytes[offset]; offset += 1; if c == 34 { return .atom(String(decoding: value, as: UTF8.self)) }; if c == 92 { guard offset < bytes.count else { break }; value.append(bytes[offset]); offset += 1 } else { value.append(c) } }; throw MailError.message("邮件结构引号不完整。") }
            if bytes[offset] == 123 { while offset < bytes.count && bytes[offset] != 125 { offset += 1 }; guard offset < bytes.count, literalIndex < literals.count else { throw MailError.message("邮件结构文字块不完整。") }; offset += 1; defer { literalIndex += 1 }; return .atom(String(decoding: literals[literalIndex], as: UTF8.self)) }
            let start = offset; while offset < bytes.count && ![9,10,13,32,40,41].contains(bytes[offset]) { offset += 1 }; guard offset > start else { throw MailError.message("邮件结构格式无效。") }; return .atom(String(decoding: bytes[start..<offset], as: UTF8.self))
        }
    }
    static func parts(lines: [String], literals: [Data]) throws -> [IMAPBodyPart] {
        let source = lines.joined(separator: "\r\n")
        guard let range = source.range(of: "BODYSTRUCTURE", options: .caseInsensitive) else { throw MailError.message("服务器未返回邮件结构。") }
        let prefix = String(source[..<range.upperBound])
        let markers = try NSRegularExpression(pattern: #"\{\d+\+?\}"#).numberOfMatches(in: prefix, range: NSRange(prefix.startIndex..., in: prefix))
        var parser = Parser(bytes: Array(source[range.upperBound...].utf8), literals: literals, literalIndex: markers)
        var result: [IMAPBodyPart] = []
        try flatten(parser.parse(), path: "", into: &result)
        return Array(result.prefix(100))
    }
    private static func parameters(_ value: Value) -> [String: String] {
        let values = value.values; var result: [String: String] = [:]
        for i in stride(from: 0, to: max(0, values.count - 1), by: 2) { if let key = values[i].string, let value = values[i + 1].string { result[key.lowercased()] = value } }
        return result
    }
    private static func filename(_ params: [String: String]) -> String? {
        if let name = params["filename"] ?? params["name"] { return MIMEParser.decodeHeader(name) }
        if let encoded = params["filename*"] ?? params["name*"] { return String(encoded.components(separatedBy: "''").last ?? encoded).removingPercentEncoding ?? encoded }
        for base in ["filename", "name"] {
            var pieces: [String] = []
            for index in 0..<32 { guard let value = params[base + "*" + String(index) + "*"] ?? params[base + "*" + String(index)] else { break }; pieces.append(value) }
            if !pieces.isEmpty { let encoded = pieces.joined(); return String(encoded.components(separatedBy: "''").last ?? encoded).removingPercentEncoding ?? MIMEParser.decodeHeader(encoded) }
        }
        return nil
    }
    private static func flatten(_ value: Value, path: String, into parts: inout [IMAPBodyPart]) throws {
        let fields = value.values; guard !fields.isEmpty, parts.count < 100 else { return }
        if case .list = fields[0] {
            var index = 0
            while index < fields.count, case .list = fields[index] { try flatten(fields[index], path: path.isEmpty ? String(index + 1) : path + "." + String(index + 1), into: &parts); index += 1 }
            return
        }
        guard fields.count >= 7, let type = fields[0].string, let subtype = fields[1].string, let encoding = fields[5].string, let bytes = fields[6].string.flatMap(Int.init), bytes >= 0, bytes <= Int(UInt32.max) else { throw MailError.message("邮件部件结构无效。") }
        let mime = (type + "/" + subtype).lowercased(), extensionStart = type.uppercased() == "TEXT" ? 8 : type.uppercased() == "MESSAGE" && subtype.uppercased() == "RFC822" ? 10 : 7
        let disposition = fields.count > extensionStart + 1 ? fields[extensionStart + 1].values : []
        let mode = disposition.first?.string?.lowercased() ?? ""
        let name = filename(disposition.count > 1 ? parameters(disposition[1]) : [:]) ?? filename(parameters(fields[2]))
        let body = ["text/plain", "text/html"].contains(mime) && mode != "attachment" && (name == nil || mode == "inline" || path.isEmpty)
        parts.append(.init(section: path.isEmpty ? "TEXT" : path, mimeType: mime, encoding: encoding, encodedBytes: bytes, name: name, contentID: fields[3].string?.trimmingCharacters(in: CharacterSet(charactersIn: "<>")), body: body))
    }
}

public struct MailRemoteAttachment: Codable, Hashable, Sendable {
    public var accountID: String
    public var folder: String
    public var uid: UInt64
    public var validity: UInt64
    public var section: String
    public var encoding: String
    public var encodedBytes: Int
    public init(accountID: String, folder: String, uid: UInt64, validity: UInt64, section: String, encoding: String, encodedBytes: Int) { self.accountID = accountID; self.folder = folder; self.uid = uid; self.validity = validity; self.section = section; self.encoding = encoding; self.encodedBytes = encodedBytes }
}

public enum MailSyncFetch: Sendable { case raw(Data), selective(MailMessage) }
