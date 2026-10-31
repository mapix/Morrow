import Foundation
import MorrowCore

struct ReaderDocumentInput: Equatable, Sendable {
    var mailID: String
    var body: String
    var usesHTML: Bool
    var allowsRemoteImages: Bool
    var themeCSS: String
    var emptyMessage: String
    var blockedImageLabel: String = "外部图片已阻止"
    var attachments: [MailAttachment]
}

struct ReaderInlineAsset: Sendable {
    var id: String
    var mimeType: String
    var data: Data
    var path: String?
    var byteCount: Int
}

struct ReaderDocument: Sendable {
    var id: String
    var host: String
    var content: String
    var assets: [String: ReaderInlineAsset]
    var invitations: [CalendarInvitation]
    var hasRemoteImages: Bool
    var allowsRemoteImages: Bool
}

/// In-memory only. Preparation and calendar file reads run off the UI actor.
actor ReaderDocumentCache {
    static let shared = ReaderDocumentCache()
    private struct Entry { var input: ReaderDocumentInput; var assetVersion: String; var document: ReaderDocument; var cost: Int }
    private var entries: [Entry] = []
    private var bytes = 0
    private(set) var preparationCount = 0
    private let maximumEntries: Int
    private let maximumBytes: Int
    init(maximumEntries: Int = 8, maximumBytes: Int = 8 * 1024 * 1024) {
        self.maximumEntries = maximumEntries; self.maximumBytes = maximumBytes
    }
    func prepare(_ input: ReaderDocumentInput) throws -> ReaderDocument {
        try Task.checkCancellation()
        let assetVersion = ReaderHTMLDocument.assetVersion(input.attachments)
        if let index = entries.firstIndex(where: { $0.input == input && $0.assetVersion == assetVersion }) {
            let entry = entries.remove(at: index); entries.append(entry); return entry.document
        }
        preparationCount += 1
        let document = try ReaderHTMLDocument.prepare(input, assetVersion: assetVersion)
        let cost = document.content.utf8.count + input.body.utf8.count + input.attachments.reduce(0) { $0 + $1.data.count }
        if cost <= maximumBytes, maximumEntries > 0 {
            while !entries.isEmpty && (entries.count >= maximumEntries || bytes + cost > maximumBytes) { bytes -= entries.removeFirst().cost }
            entries.append(Entry(input: input, assetVersion: assetVersion, document: document, cost: cost)); bytes += cost
        }
        return document
    }
    func retainedBytes() -> Int { bytes }
}

enum ReaderHTMLDocument {
    private static let cid = try! NSRegularExpression(pattern: #"(?i)cid:([^\s\"')]+)"#)
    private static let head = try! NSRegularExpression(pattern: #"(?i)<head\b[^>]*>"#)
    private static let html = try! NSRegularExpression(pattern: #"(?i)<html\b[^>]*>"#)
    private static let remoteImage = try! NSRegularExpression(pattern: #"(?i)url\(\s*[\"']?(?:https?:)?//"#)
    // Skip comments/script literals and respect quotes inside the image tag.
    private static let imageTags = try! NSRegularExpression(pattern: #"(?is)<!--.*?-->|<script\b(?:[^>\"']|\"[^\"]*\"|'[^']*')*>.*?</script\s*>|(<img\b(?:[^>\"']|\"[^\"]*\"|'[^']*')*>)"#)
    private static let imageAttributes = try! NSRegularExpression(pattern: #"(?is)(?:\s|^)(src|srcset|alt)\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s>]+))"#)
    private static let remoteSourceSet = try! NSRegularExpression(pattern: #"(?i)(?:^|[\s,])(?:https?:)?//"#)
    private static let attributeEntities = try! NSRegularExpression(pattern: #"(?i)&(amp|lt|gt|quot|apos|nbsp|colon|sol|tab|newline|#[0-9]+|#x[0-9a-f]+);"#)
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    private static func normalizedCID(_ value: String) -> String {
        (value.removingPercentEncoding ?? value).trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\r\n")).lowercased()
    }
    private static func decodedAttribute(_ value: String) -> String {
        var decoded = value
        let entities = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "colon": ":", "sol": "/", "tab": "\t", "newline": "\n"]
        for match in attributeEntities.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
            guard let tokenRange = Range(match.range(at: 1), in: decoded), let whole = Range(match.range, in: decoded) else { continue }
            let token = String(decoded[tokenRange]).lowercased()
            let replacement: String?
            if token.hasPrefix("#x"), let number = UInt32(token.dropFirst(2), radix: 16), let scalar = UnicodeScalar(number) { replacement = String(scalar) }
            else if token.hasPrefix("#"), let number = UInt32(token.dropFirst()), let scalar = UnicodeScalar(number) { replacement = String(scalar) }
            else { replacement = entities[token] }
            if let replacement { decoded.replaceSubrange(whole, with: replacement) }
        }
        return decoded
    }
    private static func attributes(in tag: String) -> [String: String] {
        var values: [String: String] = [:]
        for match in imageAttributes.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) {
            guard let nameRange = Range(match.range(at: 1), in: tag) else { continue }
            for index in 2...4 where match.range(at: index).location != NSNotFound {
                if let range = Range(match.range(at: index), in: tag) { values[String(tag[nameRange]).lowercased()] = decodedAttribute(String(tag[range])); break }
            }
        }
        return values
    }
    private static func isRemoteImage(_ values: [String: String]) -> Bool {
        let source = (values["src"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if source.hasPrefix("http://") || source.hasPrefix("https://") || source.hasPrefix("//") { return true }
        guard let sources = values["srcset"] else { return false }
        return remoteSourceSet.firstMatch(in: sources, range: NSRange(sources.startIndex..., in: sources)) != nil
    }
    private static func blockedImages(in original: String, label: String, replace: Bool) throws -> (body: String, found: Bool) {
        var body = original, found = false
        for match in imageTags.matches(in: original, range: NSRange(original.startIndex..., in: original)).reversed() {
            try Task.checkCancellation()
            guard match.range(at: 1).location != NSNotFound, let range = Range(match.range(at: 1), in: body) else { continue }
            let values = attributes(in: String(body[range])); guard isRemoteImage(values) else { continue }
            found = true; guard replace else { continue }
            let alt = (values["alt"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let description = label + (alt.isEmpty ? "" : " · " + alt)
            // No source dimensions/styles survive. Keep one compact line while
            // retaining the complete original alt in accessible text and title.
            let visible = label + (alt.isEmpty ? "" : " · " + String(alt.prefix(180)))
            let style = "display:inline-block!important;box-sizing:border-box;width:auto!important;height:auto!important;min-height:0!important;max-height:32px!important;max-width:100%;margin:4px 0;padding:5px 8px;border:1px solid var(--rule);border-radius:5px;font:12px/1.4 system-ui,-apple-system,sans-serif;color:var(--muted);background:var(--paper);white-space:nowrap!important;overflow:hidden;text-overflow:ellipsis;vertical-align:middle;"
            let placeholder = "<span class=\"morrow-blocked-image\" role=\"img\" aria-label=\"" + escape(description) + "\" title=\"" + escape(description) + "\" style=\"" + style + "\">" + escape(visible) + "</span>"
            body.replaceSubrange(range, with: placeholder)
        }
        return (body, found)
    }
    static func assetVersion(_ attachments: [MailAttachment]) -> String {
        attachments.map { attachment in
            let file = attachment.storedPath.flatMap { try? URL(fileURLWithPath: $0).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) }
            return attachment.id + ":" + (attachment.contentID ?? "") + ":" + attachment.mimeType + ":" + (attachment.storedPath ?? "") + ":" + String(file?.fileSize ?? attachment.byteCount) + ":" + String(describing: file?.contentModificationDate) + ":" + (attachment.data.isEmpty ? "" : MailStore.hash(attachment.data))
        }.joined(separator: "|")
    }
    static func prepare(_ input: ReaderDocumentInput, assetVersion: String? = nil) throws -> ReaderDocument {
        let assetVersion = assetVersion ?? self.assetVersion(input.attachments)
        let host = MailStore.hash(input.mailID + assetVersion)
        var assetByCID: [String: ReaderInlineAsset] = [:]
        var assets: [String: ReaderInlineAsset] = [:]
        for attachment in input.attachments where attachment.mimeType.lowercased().hasPrefix("image/") {
            guard let contentID = attachment.contentID, !contentID.isEmpty else { continue }
            let asset = ReaderInlineAsset(id: attachment.id, mimeType: attachment.mimeType, data: attachment.data, path: attachment.storedPath, byteCount: attachment.byteCount)
            assetByCID[normalizedCID(contentID)] = asset; assets[attachment.id] = asset
        }
        var body = input.usesHTML ? input.body : "<pre class=\"morrow-plain\">" + escape(input.body.isEmpty ? input.emptyMessage : input.body) + "</pre>"
        var hasRemoteImageTag = false
        if input.usesHTML {
            // Replace only declared inline IDs. Files are streamed by WebKit on
            // demand, rather than read and base64-expanded on every UI refresh.
            let matches = cid.matches(in: body, range: NSRange(body.startIndex..., in: body))
            for match in matches.reversed() {
                try Task.checkCancellation()
                guard let reference = Range(match.range(at: 1), in: body), let whole = Range(match.range, in: body),
                      let asset = assetByCID[normalizedCID(String(body[reference]))] else { continue }
                let identifier = asset.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? asset.id
                body.replaceSubrange(whole, with: "morrow-cid://" + host + "/" + identifier)
            }
            let blocked = try blockedImages(in: body, label: input.blockedImageLabel, replace: !input.allowsRemoteImages)
            body = blocked.body; hasRemoteImageTag = blocked.found
        }
        let imageSources = input.allowsRemoteImages ? "data: morrow-cid: https: http:" : "data: morrow-cid:"
        let policy = "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; script-src 'none'; connect-src 'none'; img-src " + imageSources + "; style-src 'unsafe-inline'; font-src 'none'; frame-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none';\">"
        // Preserve the sender's layout, colors and head styles. Original HTML
        // uses a light canvas; plain text follows the application theme.
        let canvas = input.usesHTML ? "html,body{background:#fff;color:#202124;color-scheme:light;}" : "html,body{background:var(--paper);color:var(--ink);}"
        let style = "<style>" + input.themeCSS + canvas + "html{min-width:0;}body{margin:0;padding:20px;box-sizing:border-box;overflow-wrap:anywhere;font-family:system-ui,-apple-system,sans-serif;font-size:15px;line-height:1.65;}img{max-width:100%;height:auto;}table{max-width:100%;}pre.morrow-plain{margin:0;white-space:pre-wrap;overflow-wrap:anywhere;font:inherit;}blockquote{margin-left:0;padding-left:14px;border-left:2px solid var(--rule);}a{overflow-wrap:anywhere;}</style>"
        let securityHead = "<meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">" + policy + style
        let fullRange = NSRange(body.startIndex..., in: body)
        let content: String
        if let match = head.firstMatch(in: body, range: fullRange), let range = Range(match.range, in: body) {
            var original = body; original.insert(contentsOf: securityHead, at: range.upperBound); content = original
        } else if let match = html.firstMatch(in: body, range: fullRange), let range = Range(match.range, in: body) {
            var original = body; original.insert(contentsOf: "<head>" + securityHead + "</head>", at: range.upperBound); content = original
        } else { content = "<!doctype html><html><head>" + securityHead + "</head><body>" + body + "</body></html>" }
        var invitations: [CalendarInvitation] = []
        for attachment in input.attachments where attachment.mimeType == "text/calendar" || attachment.name.lowercased().hasSuffix(".ics") {
            try Task.checkCancellation()
            let data: Data
            if !attachment.data.isEmpty { guard attachment.data.count <= 2 * 1024 * 1024 else { continue }; data = attachment.data }
            else if let path = attachment.storedPath,
                    let size = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey]).fileSize,
                    size <= 2 * 1024 * 1024 { data = (try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)) ?? Data() }
            else { continue }
            invitations += CalendarInvitation.parse(data)
        }
        let hasRemote = input.usesHTML && (hasRemoteImageTag || remoteImage.firstMatch(in: input.body, range: NSRange(input.body.startIndex..., in: input.body)) != nil)
        return ReaderDocument(id: MailStore.hash(content + assetVersion), host: host, content: content, assets: assets, invitations: invitations, hasRemoteImages: hasRemote, allowsRemoteImages: input.allowsRemoteImages)
    }
}
