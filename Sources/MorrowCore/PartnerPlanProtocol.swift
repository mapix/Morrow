import Foundation

/// The planner protocol is separate from presentation markup and tool authority.
enum PartnerPlanProtocol {
    static let allowedOperations = Set(["search", "rerank", "read", "stats", "draft", "delegate", "label", "star", "markRead", "complete", "snooze", "archive", "addAccount", "addContact", "calendar", "import", "navigate", "select", "selectContact", "selectAttachment", "sync", "reply", "replyAll", "forward", "compose", "markUnread", "unstar", "trash", "move", "createFolder", "exportMail", "saveAttachment", "undo", "contacts", "attachments", "readAttachment", "updateDraft", "showSearch"])
    static var schema: Data {
        var fields: [String: Any] = ["type": ["type": "string", "enum": allowedOperations.sorted()]]
        for key in ["messageID", "text", "recipient", "subject", "kind", "match", "accountID", "start", "end", "location"] { fields[key] = ["type": ["string", "null"]] }
        fields["hours"] = ["type": ["integer", "null"]]
        let object: [String: Any] = ["type": "object", "properties": [
            "answer": ["type": "string"], "messageIDs": ["type": "array", "items": ["type": "string"]],
            "operations": ["type": "array", "maxItems": 8, "items": ["type": "object", "properties": fields, "required": fields.keys.sorted(), "additionalProperties": false]],
            "openUI": ["type": ["string", "null"]]
        ], "required": ["answer", "messageIDs", "operations", "openUI"], "additionalProperties": false]
        return try! JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
    }
    static func decode(_ response: AIResult) throws -> PartnerPlan {
        if response.completionReason == "length" { throw PlanOutputError.truncated }
        if response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw response.reasoningOnly ? PlanOutputError.reasoningOnly : PlanOutputError.empty }
        do {
            let plan = try JSONDecoder().decode(PartnerPlan.self, from: jsonData(response.text))
            guard let operations = plan.operations, operations.count <= 8, plan.messageIDs != nil else { throw PlanOutputError.malformed }
            return plan
        } catch { throw PlanOutputError.malformed }
    }
    static func jsonData(_ text: String) throws -> Data {
        // Reasoning is never an executable plan. Accept a complete JSON object
        // with prose/fence wrappers, but reject competing objects and truncation.
        var text = text
        while let start = text.range(of: "<think>") {
            if let objectStart = text.firstIndex(of: "{"), objectStart < start.lowerBound { break }
            guard let end = text.range(of: "</think>", range: start.upperBound..<text.endIndex) else { throw PlanOutputError.malformed }
            text.removeSubrange(start.lowerBound..<end.upperBound)
        }
        guard let start = text.firstIndex(of: "{") else { throw PlanOutputError.malformed }
        var depth = 0, quoted = false, escaped = false
        for index in text[start...].indices {
            let char = text[index]
            if quoted {
                if escaped { escaped = false } else if char == "\\" { escaped = true } else if char == "\"" { quoted = false }
            } else if char == "\"" { quoted = true }
            else if char == "{" { depth += 1 }
            else if char == "}" {
                depth -= 1
                if depth == 0 {
                    let tail = text[text.index(after: index)...]
                    guard !tail.contains("{") else { throw PlanOutputError.malformed }
                    return Data(text[start...index].utf8)
                }
            }
        }
        throw PlanOutputError.malformed
    }
}

enum PlanOutputError: LocalizedError {
    case malformed, empty, reasoningOnly, truncated
    var errorDescription: String? {
        switch self {
        case .malformed: return "模型的执行方案格式不完整，自动修复后仍无法解析；本轮未据此执行操作。"
        case .empty: return "模型返回了空的执行方案，自动重试后仍无有效结果。"
        case .reasoningOnly: return "模型只返回了思考内容，没有执行方案；自动重试后仍未完成。"
        case .truncated: return "模型达到输出长度上限，执行方案被截断；增加输出预算重试后仍未完成。"
        }
    }
}
