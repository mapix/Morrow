import Foundation

/// Explicit read-only projections: credentials, raw MIME, attachment bytes and
/// local filesystem paths are never serialized into the MCP interface.
public struct MCPMailTools: Sendable {
    private let store: MailStore
    public init(store: MailStore) { self.store = store }
    private typealias JSON = OpenUIJSON

    public static var definitions: [OpenUIJSON] {
        let string: JSON = .object(["type": .string("string")])
        let limit: JSON = .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(100), "default": .number(25)])
        let offset: JSON = .object(["type": .string("integer"), "minimum": .number(0), "maximum": .number(1000000), "default": .number(0)])
        func tool(_ name: String, _ description: String, _ properties: [String: JSON] = [:], required: [String] = []) -> JSON {
            .object(["name": .string(name), "description": .string(description),
                     "inputSchema": .object(["type": .string("object"), "properties": .object(properties), "required": .array(required.map(JSON.string)), "additionalProperties": .bool(false)]),
                     "annotations": .object(["readOnlyHint": .bool(true), "destructiveHint": .bool(false), "idempotentHint": .bool(true), "openWorldHint": .bool(false)])])
        }
        return [
            tool("list_accounts", "List connected mailbox IDs, names and addresses. No credentials."),
            tool("list_folders", "List cached mailbox folders.", ["account_id": string]),
            tool("list_mail", "List locally cached mail, newest first. Returns previews, not full bodies. Copies in different folders have distinct IDs.", ["account_id": string, "folder": string, "limit": limit, "offset": offset]),
            tool("search_mail", "Search cached mail by keywords or filters: from:, to:, subject:, after:, before:, is:unread, has:attachment. No remote/model calls. Results may be incomplete; narrow the query when has_more is true.", ["query": string, "limit": limit], required: ["query"]),
            tool("get_mail", "Read cached mail text without marking it read. Body is paginated by Unicode characters; use next_offset for the rest. Attachments return metadata only.", ["id": string, "offset": offset], required: ["id"]),
            tool("list_contacts", "List local manual contacts and contacts derived from mail, filtered by name or email.", ["query": string, "limit": limit, "offset": offset]),
            tool("list_briefs", "List saved briefs and reports, newest first. Saved findings are not newly verified.", ["limit": limit, "offset": offset]),
            tool("get_brief", "Read a saved brief/report with source mail IDs. Content is paginated by Unicode characters.", ["id": string, "offset": offset], required: ["id"])
        ]
    }

    public func call(name: String, arguments: OpenUIJSON) async throws -> OpenUIJSON {
        guard let definition = Self.definitions.first(where: { $0.object["name"]?.text == name }) else { throw MCPRPCError(code: -32602, message: "Unknown tool: " + name) }
        guard case .object(let fields) = arguments else { throw MCPRPCError(code: -32602, message: "arguments must be an object") }
        let schema = definition.object["inputSchema"]!.object
        guard fields.keys.allSatisfy({ schema["properties"]!.object[$0] != nil }) else { throw MCPRPCError(code: -32602, message: "Unknown argument") }
        for (key, value) in fields {
            let type = schema["properties"]!.object[key]!.object["type"]?.text
            if type == "string", case .string = value { continue }
            if type == "integer", case .number(let number) = value, number.isFinite, number.rounded() == number,
               number >= (key == "limit" ? 1 : 0), number <= (key == "limit" ? 100 : 1000000) { continue }
            throw MCPRPCError(code: -32602, message: "Invalid argument: " + key)
        }
        if case .array(let required) = schema["required"] {
            for key in required where fields[key.text]?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { throw MCPRPCError(code: -32602, message: "Missing argument: " + key.text) }
        }
        let limit = Int(fields["limit"]?.text ?? "25") ?? 25, offset = Int(fields["offset"]?.text ?? "0") ?? 0
        let result: JSON
        switch name {
        case "list_accounts":
            let values = try await store.load(MailAccount.self, kind: "account")
            result = .object(["accounts": .array(values.map { .object(["id": .string($0.id), "name": .string($0.name), "email": .string($0.email), "enabled": .bool($0.enabled)]) })])
        case "list_folders":
            let values = try await store.load(MailFolder.self, kind: "folder").filter { fields["account_id"] == nil || $0.accountID == fields["account_id"]?.text }
            result = .object(["folders": .array(values.map { .object(["id": .string($0.id), "account_id": .string($0.accountID), "path": .string($0.path), "name": .string($0.name), "role": .string($0.role)]) })])
        case "list_mail":
            let values = try await store.messageSummaries(account: fields["account_id"]?.text, folder: fields["folder"]?.text, limit: limit + 1, offset: offset)
            result = page(values.map { Self.mail($0.displayMessage) }, key: "mail", limit: limit, offset: offset)
        case "search_mail":
            let query = fields["query"]!.text
            guard query.count <= 2000 else { throw MCPRPCError(code: -32602, message: "query exceeds 2000 characters") }
            let values = try await store.keywordSearch(query, limit: limit + 1)
            result = page(values.map { Self.mail($0.message) }, key: "mail", limit: limit, offset: 0)
        case "get_mail":
            guard let value = try await store.message(fields["id"]!.text) else { throw MailError.message("未找到这封本机邮件。") }
            var fields = Self.mail(value).object
            fields.merge(Self.textPage(value.text, offset: offset, key: "text").object) { _, new in new }
            fields["content_availability"] = .string(value.contentAvailability?.rawValue ?? "complete")
            fields["attachments"] = .array(value.attachments.map { .object(["id": .string($0.id), "name": .string($0.name), "mime_type": .string($0.mimeType), "byte_count": .number(Double($0.byteCount))]) })
            result = .object(fields)
        case "list_contacts":
            let manual = try await store.load(ContactEntry.self, kind: "contact")
            let profiles = try await store.load(ContactProfile.self, kind: "contact-profile")
            var values = Dictionary(profiles.map { ($0.email.lowercased(), JSON.object(["id": .string($0.id), "name": .string($0.name), "email": .string($0.email)])) }, uniquingKeysWith: { first, _ in first })
            for value in manual { values[value.email.lowercased().isEmpty ? value.id : value.email.lowercased()] = .object(["id": .string(value.id), "name": .string(value.name), "email": .string(value.email), "phone": .string(value.phone), "company": .string(value.company)]) }
            let query = fields["query"]?.text ?? ""
            let matching = values.values.filter { query.isEmpty || ($0.object["name"]!.text + " " + $0.object["email"]!.text).localizedCaseInsensitiveContains(query) }.sorted { $0.object["email"]!.text < $1.object["email"]!.text }
            result = page(Array(matching.dropFirst(offset).prefix(limit + 1)), key: "contacts", limit: limit, offset: offset)
        case "list_briefs":
            let values = try await store.load(AgentArtifact.self, kind: "agent-artifact").filter(\.isBrief).sorted { ($0.updatedAt ?? $0.createdAt) > ($1.updatedAt ?? $1.createdAt) }
            result = page(Array(values.dropFirst(offset).prefix(limit + 1)).map { .object(["id": .string($0.id), "title": .string($0.title), "updated_at": Self.date($0.updatedAt ?? $0.createdAt), "source_mail_ids": .array($0.sourceMailIDs.map(JSON.string))]) }, key: "briefs", limit: limit, offset: offset)
        case "get_brief":
            guard let value = try await store.object(AgentArtifact.self, kind: "agent-artifact", id: fields["id"]!.text), value.isBrief else { throw MailError.message("未找到这份本机简报。") }
            var fields = Self.textPage(value.content, offset: offset, key: "content").object
            fields["id"] = .string(value.id); fields["title"] = .string(value.title)
            fields["source_mail_ids"] = .array(value.sourceMailIDs.map(JSON.string))
            result = .object(fields)
        default: throw MCPRPCError(code: -32602, message: "Unknown tool")
        }
        let encoded = try JSONEncoder().encode(result)
        guard encoded.count <= 1024 * 1024 else { throw MailError.message("MCP 查询结果过大，请缩小范围。") }
        return .object(["content": .array([.object(["type": .string("text"), "text": .string(String(decoding: encoded, as: UTF8.self))])]), "structuredContent": result, "isError": .bool(false)])
    }

    private func page(_ values: [JSON], key: String, limit: Int, offset: Int) -> JSON {
        .object([key: .array(Array(values.prefix(limit))), "has_more": .bool(values.count > limit), "next_offset": values.count > limit ? .number(Double(offset + limit)) : .null])
    }
    private static func textPage(_ text: String, offset: Int, key: String) -> JSON {
        let content = String(text.dropFirst(offset).prefix(20000)), next = offset + content.count
        return .object([key: .string(content), "offset": .number(Double(offset)), "truncated": .bool(next < text.count), "next_offset": next < text.count ? .number(Double(next)) : .null])
    }
    private static func date(_ date: Date) -> JSON { .string(ISO8601DateFormatter().string(from: date)) }
    private static func address(_ value: MailAddress) -> JSON { .object(["name": .string(value.name), "email": .string(value.email)]) }
    private static func mail(_ mail: MailMessage) -> JSON {
        .object(["id": .string(mail.id), "account_id": .string(mail.accountID), "folder": .string(mail.folder), "subject": .string(mail.subject), "from": address(mail.from), "to": .array(mail.to.map(address)), "cc": .array(mail.cc.map(address)), "date": date(mail.date), "is_read": .bool(mail.isRead), "is_starred": .bool(mail.isStarred), "preview": .string(mail.preview)])
    }
}
