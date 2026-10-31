import Foundation

public struct WorkAgreement: Codable, Sendable {
    public static var schema: Data {
        let string: [String: Any] = ["type": "string"]
        let strings: [String: Any] = ["type": "array", "items": string]
        let fields: [String: Any] = ["goal": string, "doneWhen": string, "scope": string, "boundaries": strings, "steps": strings, "kind": ["type": "string", "enum": ["watch", "reply", "briefing", "followUp", "organize"]], "match": string, "intervalHours": ["type": "integer", "minimum": 1, "maximum": 168], "recipient": ["type": ["string", "null"]]]
        return try! JSONSerialization.data(withJSONObject: ["type": "object", "properties": fields, "required": Array(fields.keys), "additionalProperties": false])
    }
    public var goal: String
    public var doneWhen: String
    public var scope: String
    public var boundaries: [String]
    public var steps: [String]
    public var kind: String
    public var match: String
    public var intervalHours: Int
    public var recipient: String?
    public var resolvedScope: WorkScope?
    public var hostScope: WorkContextLimit?
    public func contains(_ mail: MailMessage) -> Bool {
        (resolvedScope?.contains(mail) ?? false) && (hostScope?.contains(mail) ?? true)
    }
    public init(goal: String, doneWhen: String, scope: String, boundaries: [String], steps: [String], kind: String = "watch", match: String = "", intervalHours: Int = 24, recipient: String? = nil) { self.goal = goal; self.doneWhen = doneWhen; self.scope = scope; self.boundaries = boundaries; self.steps = steps; self.kind = kind; self.match = match; self.intervalHours = intervalHours; self.recipient = recipient }
}
