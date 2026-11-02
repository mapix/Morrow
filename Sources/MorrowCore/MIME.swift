import Foundation
import CoreFoundation

public enum MIMEParser {
    private static let hiddenHTML = try! NSRegularExpression(pattern: #"(?is)<(script|style|head|template)\b[^>]*>.*?</\1\s*>"#)
    private static let htmlComments = try! NSRegularExpression(pattern: #"(?s)<!--.*?-->"#)
    private static let htmlBreaks = try! NSRegularExpression(pattern: #"(?i)<br\b(?:[^>"']|"[^"]*"|'[^']*')*>|</(?:p|div|tr|li|h[1-6]|blockquote|section|article|header|footer|main)\s*>"#)
    private static let htmlCells = try! NSRegularExpression(pattern: #"(?i)</(?:td|th)\s*>"#)
    private static let htmlTags = try! NSRegularExpression(pattern: #"<(?:[^>"']|"[^"]*"|'[^']*')+>"#)
    private static let htmlEntity = try! NSRegularExpression(pattern: #"&(#(?:[xX][0-9a-fA-F]+|[0-9]+)|[A-Za-z][A-Za-z0-9]+);"#)
    private static let namedEntities = [
        "nbsp": " ", "amp": "&", "AMP": "&", "lt": "<", "LT": "<", "gt": ">", "GT": ">", "quot": "\"", "QUOT": "\"", "apos": "'",
        "ndash": "–", "mdash": "—", "bull": "•", "hellip": "…", "copy": "©", "reg": "®", "trade": "™", "euro": "€", "pound": "£", "yen": "¥", "cent": "¢",
        "laquo": "«", "raquo": "»", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "ensp": " ", "emsp": " ", "thinsp": " ", "shy": "", "zwnj": "\u{200c}", "zwj": "\u{200d}",
        "Agrave": "À", "Aacute": "Á", "Acirc": "Â", "Atilde": "Ã", "Auml": "Ä", "Aring": "Å", "AElig": "Æ", "Ccedil": "Ç", "Egrave": "È", "Eacute": "É", "Ecirc": "Ê", "Euml": "Ë",
        "Igrave": "Ì", "Iacute": "Í", "Icirc": "Î", "Iuml": "Ï", "Ntilde": "Ñ", "Ograve": "Ò", "Oacute": "Ó", "Ocirc": "Ô", "Otilde": "Õ", "Ouml": "Ö", "Oslash": "Ø", "Ugrave": "Ù", "Uacute": "Ú", "Ucirc": "Û", "Uuml": "Ü", "szlig": "ß",
        "agrave": "à", "aacute": "á", "acirc": "â", "atilde": "ã", "auml": "ä", "aring": "å", "aelig": "æ", "ccedil": "ç", "egrave": "è", "eacute": "é", "ecirc": "ê", "euml": "ë",
        "igrave": "ì", "iacute": "í", "icirc": "î", "iuml": "ï", "ntilde": "ñ", "ograve": "ò", "oacute": "ó", "ocirc": "ô", "otilde": "õ", "ouml": "ö", "oslash": "ø", "ugrave": "ù", "uacute": "ú", "ucirc": "û", "uuml": "ü", "yuml": "ÿ",
        "times": "×", "divide": "÷", "plusmn": "±", "deg": "°", "micro": "µ", "middot": "·"
    ]
    public static func parse(_ data: Data, accountID: String, folder: String = "INBOX", uid: UInt64 = 0, validity: UInt64 = 0) -> MailMessage {
        let source = String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
        let (headers, _) = split(source)
        var mail = MailMessage(accountID: accountID, from: parseAddresses(headers["from"] ?? "").first ?? .init(email: "unknown@invalid.local"), subject: decodeHeader(headers["subject"] ?? "(无主题)"), text: "")
        mail.folder = folder; mail.uid = uid; mail.uidValidity = validity
        if uid > 0 { mail.id = "\(accountID):\(folder):\(validity):\(uid)" }
        mail.messageID = headers["message-id"] ?? ""; mail.inReplyTo = headers["in-reply-to"] ?? ""; mail.references = headers["references"] ?? ""
        mail.to = parseAddresses(headers["to"] ?? ""); mail.cc = parseAddresses(headers["cc"] ?? ""); mail.bcc = parseAddresses(headers["bcc"] ?? ""); mail.replyTo = parseAddresses(headers["reply-to"] ?? "")
        if let date = parseDate(headers["date"] ?? "") { mail.date = date }
        var texts: [String] = [], htmls: [String] = [], files: [MailAttachment] = []
        parsePart(source, depth: 0, texts: &texts, htmls: &htmls, attachments: &files)
        mail.text = texts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        mail.html = htmls.joined(separator: "\n")
        if mail.text.isEmpty { mail.text = plainText(mail.html) }
        mail.attachments = files; mail.raw = data
        return mail
    }

    private static func split(_ source: String) -> ([String: String], String) {
        // Normalize headers only. Rewriting the complete message on every
        // recursion both copies large payloads and corrupts binary MIME parts.
        let separators = [source.range(of: "\r\n\r\n"), source.range(of: "\n\n")].compactMap { $0 }
        guard let separator = separators.min(by: { $0.lowerBound < $1.lowerBound }) else { return ([:], source) }
        let head = String(source[..<separator.lowerBound]).replacingOccurrences(of: "\r\n", with: "\n")
        let unfolded = head.replacingOccurrences(of: "\n[ \t]+", with: " ", options: .regularExpression)
        var values: [String: String] = [:]
        for line in unfolded.components(separatedBy: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].lowercased(); let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            values[key] = values[key].map { $0 + ", " + value } ?? value
        }
        return (values, String(source[separator.upperBound...]))
    }

    private static func parsePart(_ source: String, depth: Int, allowNamedBody: Bool = false, texts: inout [String], htmls: inout [String], attachments: inout [MailAttachment]) {
        guard depth < 16 else { return }
        let (head, body) = split(source)
        let type = head["content-type"] ?? "text/plain; charset=utf-8"
        let mime = type.components(separatedBy: ";")[0].trimmingCharacters(in: .whitespaces).lowercased()
        if mime.hasPrefix("multipart/"), let boundary = parameter("boundary", in: type) {
            let marker = "--" + boundary
            let pattern = "(?m)^" + NSRegularExpression.escapedPattern(for: marker) + "(--)?[ \t]*\\r?$"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            let ns = body as NSString; let matches = regex.matches(in: body, range: NSRange(location: 0, length: ns.length))
            var plainChoice: (Int, [String])?, htmlChoice: (Int, [String])?
            var partFiles: [(Int, [MailAttachment])] = []
            let relatedRoot = parameter("start", in: type)?.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            for i in matches.indices {
                if matches[i].range(at: 1).location != NSNotFound { break }
                var start = matches[i].range.location + matches[i].range.length
                var end = i + 1 < matches.count ? matches[i + 1].range.location : ns.length
                // Offsets from NSRegularExpression are UTF-16 offsets. CRLF is
                // one Swift Character, so removeFirst/Last(2) would also eat a
                // real header/body character. Slice exactly the framing bytes.
                if end - start >= 2, ns.substring(with: NSRange(location: start, length: 2)) == "\r\n" { start += 2 }
                else if start < end, ns.character(at: start) == 10 { start += 1 }
                if i + 1 < matches.count {
                    if end - start >= 2, ns.substring(with: NSRange(location: end - 2, length: 2)) == "\r\n" { end -= 2 }
                    else if start < end, ns.character(at: end - 1) == 10 { end -= 1 }
                }
                let part = ns.substring(with: NSRange(location: start, length: end - start))
                let childHead = split(part).0
                let childType = (childHead["content-type"] ?? "text/plain").components(separatedBy: ";")[0].trimmingCharacters(in: .whitespaces).lowercased()
                let disposition = childHead["content-disposition"]?.lowercased() ?? ""
                if mime == "multipart/alternative", ["text/x-amp-html", "text/watch-html"].contains(childType), !disposition.contains("attachment") { continue }
                let contentID = childHead["content-id"]?.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
                let rootPart = mime == "multipart/alternative" || (mime == "multipart/related" && (relatedRoot.map { $0 == contentID } ?? (i == 0)))
                if mime == "multipart/alternative" {
                    var childTexts: [String] = [], childHTML: [String] = [], files: [MailAttachment] = []
                    parsePart(part, depth: depth + 1, allowNamedBody: rootPart, texts: &childTexts, htmls: &childHTML, attachments: &files)
                    if !childTexts.isEmpty { plainChoice = (i, childTexts) }
                    if !childHTML.isEmpty { htmlChoice = (i, childHTML) }
                    if !files.isEmpty { partFiles.append((childTexts.isEmpty && childHTML.isEmpty ? -1 : i, files)) }
                } else { parsePart(part, depth: depth + 1, allowNamedBody: rootPart, texts: &texts, htmls: &htmls, attachments: &attachments) }
            }
            if mime == "multipart/alternative" {
                texts += plainChoice?.1 ?? []; htmls += htmlChoice?.1 ?? []
                for (index, files) in partFiles where index == -1 || index == plainChoice?.0 || index == htmlChoice?.0 { attachments += files.prefix(max(0, 100 - attachments.count)) }
            }
            return
        }
        let disposition = head["content-disposition"] ?? ""
        let name = parameter("filename", in: disposition) ?? parameter("name", in: type)
        let bodyRepresentation = (mime == "text/plain" || mime == "text/html") && (name == nil || disposition.lowercased().contains("inline") || depth == 0 || allowNamedBody) && !disposition.lowercased().contains("attachment")
        if !bodyRepresentation, attachments.count >= 100 { return }
        let encoding = (head["content-transfer-encoding"] ?? "").lowercased()
        let decoded: Data
        if encoding.contains("base64") { decoded = Data(base64Encoded: body, options: .ignoreUnknownCharacters) ?? Data() }
        else { let raw = body.data(using: .isoLatin1) ?? Data(body.utf8); decoded = encoding.contains("quoted-printable") ? quotedPrintable(raw) : raw }
        if !bodyRepresentation {
            let fallback = mime == "message/rfc822" ? "转发邮件.eml" : mime == "text/calendar" ? "邀请.ics" : "附件"
            let filename = decodeHeader(name ?? fallback)
            attachments.append(.init(name: filename, mimeType: mime, data: decoded, contentID: head["content-id"]?.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))))
        } else {
            let text = decode(decoded, charset: parameter("charset", in: type) ?? "utf-8").replacingOccurrences(of: "\r\n", with: "\n")
            if mime == "text/html" { htmls.append(text) } else { texts.append(text) }
        }
    }

    public static func parameter(_ name: String, in value: String) -> String? {
        let star = NSRegularExpression.escapedPattern(for: name) + #"\*\s*=\s*([^;]+)"#
        if let encoded = capture(star, value), let split = encoded.range(of: "''") {
            return String(encoded[split.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "\" ")).removingPercentEncoding
        }
        let pattern = "(?:^|;)\\s*" + NSRegularExpression.escapedPattern(for: name) + #"\s*=\s*(?:"([^"]*)"|([^;]*))"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive), let m = re.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        for i in 1...2 { if let r = Range(m.range(at: i), in: value) { return String(value[r]).trimmingCharacters(in: .whitespaces) } }
        return nil
    }

    public static func decodeHeader(_ value: String) -> String {
        let joined = value.replacingOccurrences(of: #"(\?=)\s+(=\?)"#, with: "$1$2", options: .regularExpression)
        guard let regex = try? NSRegularExpression(pattern: #"=\?([^?]+)\?([bBqQ])\?([^?]*)\?="#) else { return value }
        var result = joined
        for m in regex.matches(in: joined, range: NSRange(joined.startIndex..., in: joined)).reversed() {
            let ns = joined as NSString; let charset = ns.substring(with: m.range(at: 1)); let encoding = ns.substring(with: m.range(at: 2)).lowercased(); let content = ns.substring(with: m.range(at: 3))
            let bytes = encoding == "b" ? (Data(base64Encoded: content) ?? Data()) : quotedPrintable(Data(content.replacingOccurrences(of: "_", with: " ").utf8))
            if let r = Range(m.range, in: result) { result.replaceSubrange(r, with: decode(bytes, charset: charset)) }
        }
        if result == value, let bytes = value.data(using: .isoLatin1), let utf = String(data: bytes, encoding: .utf8) { return utf }
        return result
    }

    public static func decode(_ data: Data, charset: String) -> String {
        let cf = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
        if cf != kCFStringEncodingInvalidId, let result = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))) { return result }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    public static func quotedPrintable(_ data: Data) -> Data {
        data.withUnsafeBytes { (b: UnsafeRawBufferPointer) -> Data in
            var out = Data(); out.reserveCapacity(b.count); var i = 0
            while i < b.count {
                if b[i] == 61 {
                    if i + 1 < b.count, b[i + 1] == 10 { i += 2; continue }
                    if i + 2 < b.count, b[i + 1] == 13, b[i + 2] == 10 { i += 3; continue }
                    if i + 2 < b.count, let first = hexDigit(b[i + 1]), let second = hexDigit(b[i + 2]) { out.append(first * 16 + second); i += 3; continue }
                }
                out.append(b[i]); i += 1
            }
            return out
        }
    }
    private static func hexDigit(_ value: UInt8) -> UInt8? {
        switch value { case 48...57: return value - 48; case 65...70: return value - 55; case 97...102: return value - 87; default: return nil }
    }

    public static func parseAddresses(_ value: String) -> [MailAddress] {
        let decoded = decodeHeader(value); var parts: [String] = []; var current = ""; var quoted = false; var angle = 0
        for c in decoded {
            if c == "\"" { quoted.toggle() }; if c == "<" { angle += 1 }; if c == ">" { angle = max(0, angle - 1) }
            if c == ",", !quoted, angle == 0 { parts.append(current); current = "" } else { current.append(c) }
        }; parts.append(current)
        return parts.compactMap { part in
            let p = part.trimmingCharacters(in: .whitespacesAndNewlines); guard !p.isEmpty else { return nil }
            if let a = p.firstIndex(of: "<"), let z = p[a...].firstIndex(of: ">") {
                return .init(name: String(p[..<a]).trimmingCharacters(in: CharacterSet(charactersIn: "\" ")), email: String(p[p.index(after: a)..<z]).trimmingCharacters(in: .whitespaces))
            }; return .init(email: p)
        }
    }

    public static func plainText(_ html: String) -> String {
        func replace(_ regex: NSRegularExpression, _ value: String, _ replacement: String) -> String {
            regex.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: replacement)
        }
        var s = replace(hiddenHTML, html, "")
        s = replace(htmlComments, s, "")
        s = replace(htmlBreaks, s, "\n")
        s = replace(htmlCells, s, "\t")
        s = replace(htmlTags, s, "")
        // Build the decoded output once. Repeated replaceSubrange/range
        // conversions become quadratic in entity-heavy mail or Office XML.
        let source = s as NSString
        let matches = htmlEntity.matches(in: s, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        var output = ""; output.reserveCapacity(s.utf8.count); var position = 0
        for match in matches {
            output += source.substring(with: NSRange(location: position, length: match.range.location - position))
            let token = source.substring(with: match.range(at: 1))
            var decoded = namedEntities[token]
            if token.hasPrefix("#") {
                let value = token.dropFirst()
                let number = value.first == "x" || value.first == "X" ? UInt32(value.dropFirst(), radix: 16) : UInt32(value)
                if let number { decoded = number == 0 ? "\u{fffd}" : UnicodeScalar(number).map { String($0) } ?? "\u{fffd}" }
            }
            output += decoded ?? source.substring(with: match.range)
            position = NSMaxRange(match.range)
        }
        output += source.substring(from: position)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func parseDate(_ value: String) -> Date? {
        let s = value.replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        for format in ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z", "d MMM yyyy HH:mm Z"] { f.dateFormat = format; if let date = f.date(from: s) { return date } }; return nil
    }
    static func capture(_ pattern: String, _ value: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive), let m = re.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)), m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: value) else { return nil }; return String(value[r])
    }
}

public enum MIMEWriter {
    public static func encode(_ draft: ComposeDraft, account: MailAccount, date: Date = Date()) throws -> Data {
        try draft.validate()
        guard MailAddress.isValid(account.email), !account.name.contains("\n"), !account.name.contains("\r") else { throw MailError.message("发件人配置无效。") }
        let boundary = "morrow-" + UUID().uuidString
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        var lines = ["From: \(address(.init(name: account.name, email: account.email)))", "To: \(draft.addresses(draft.to).map(address).joined(separator: ", "))", "Subject: \(header(draft.subject))", "Date: \(f.string(from: date))", "Message-ID: <\(draft.id)@morrow.local>", "MIME-Version: 1.0"]
        if !draft.cc.isEmpty { lines.append("Cc: " + draft.addresses(draft.cc).map(address).joined(separator: ", ")) }
        if !draft.inReplyTo.isEmpty { lines.append("In-Reply-To: " + safe(draft.inReplyTo)) }
        if !draft.references.isEmpty { lines.append("References: " + safe(draft.references)) }
        if draft.automaticResponse == true { lines += ["Auto-Submitted: auto-replied", "X-Auto-Response-Suppress: All"] }
        lines.append("Content-Type: multipart/mixed; boundary=\"\(boundary)\""); lines.append("")
        if let html = draft.htmlBody, !html.isEmpty {
            let alternative = "alternative-" + UUID().uuidString
            lines += ["--\(boundary)", "Content-Type: multipart/alternative; boundary=\"\(alternative)\"", "", "--\(alternative)", "Content-Type: text/plain; charset=utf-8", "Content-Transfer-Encoding: base64", "", base64(Data(draft.body.utf8)), "--\(alternative)", "Content-Type: text/html; charset=utf-8", "Content-Transfer-Encoding: base64", "", base64(Data(html.utf8)), "--\(alternative)--"]
        } else { lines += ["--\(boundary)", "Content-Type: text/plain; charset=utf-8", "Content-Transfer-Encoding: base64", "", base64(Data(draft.body.utf8))] }
        for a in draft.attachments {
            let name = a.name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "attachment"
            let type = a.mimeType.range(of: #"^[a-zA-Z0-9.+-]+/[a-zA-Z0-9.+-]+$"#, options: .regularExpression) != nil ? a.mimeType : "application/octet-stream"
            let calendarMethod = type == "text/calendar" ? MIMEParser.capture(#"(?m)^METHOD:(REPLY|REQUEST|CANCEL|PUBLISH)\r?$"#, String(decoding: a.data, as: UTF8.self)) : nil
            let contentType = type + (calendarMethod.map { "; method=" + $0 + "; charset=utf-8" } ?? "")
            lines += ["--\(boundary)", "Content-Type: \(contentType)", "Content-Disposition: attachment; filename*=UTF-8''\(name)", "Content-Transfer-Encoding: base64", "", base64(a.data)]
        }; lines += ["--\(boundary)--", ""]
        return Data(lines.joined(separator: "\r\n").utf8)
    }
    public static func header(_ text: String) -> String {
        let cleaned = safe(text)
        // Split on Character boundaries to keep each RFC 2047 encoded word under 75 bytes.
        var words: [String] = []; var chunk = ""
        for c in cleaned { if (chunk + String(c)).utf8.count > 42 { words.append("=?UTF-8?B?" + Data(chunk.utf8).base64EncodedString() + "?="); chunk = "" }; chunk.append(c) }
        if !chunk.isEmpty { words.append("=?UTF-8?B?" + Data(chunk.utf8).base64EncodedString() + "?=") }; return words.joined(separator: "\r\n ")
    }
    static func address(_ a: MailAddress) -> String { a.name.isEmpty ? safe(a.email) : header(a.name) + " <" + safe(a.email) + ">" }
    static func safe(_ s: String) -> String { s.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "") }
    static func base64(_ data: Data) -> String { data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]) }
}
