import Foundation

public struct AgentPlanItem: Codable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var status: String
}
public struct AgentToolActivity: Codable, Identifiable, Sendable {
    public var id: String
    public var tool: String
    public var status: String
    public var startedAt: Date
    public var seconds: Double?
}
public struct AgentModelActivity: Codable, Identifiable, Sendable {
    public var step: Int
    public var model: String?
    public var startedAt: Date
    public var seconds: Double?
    public var queueSeconds: Double?
    public var requestSeconds: Double?
    public var promptSeconds: Double?
    public var generationSeconds: Double?
    public var outputTokens: Int?
    public var id: Int { step }
}
public struct AgentExecutionTrace: Codable, Sendable {
    public var startedAt = Date()
    public var finishedAt: Date?
    public var status = "running"
    public var plan: [AgentPlanItem] = []
    public var tools: [AgentToolActivity] = []
    public var models: [AgentModelActivity] = []
    public init() {}
    public mutating func finish(status: String) {
        finishedAt = Date(); self.status = status
        for index in tools.indices where tools[index].status == "running" { tools[index].status = status == "failed" ? "failed" : "paused"; tools[index].seconds = finishedAt!.timeIntervalSince(tools[index].startedAt) }
        for index in models.indices where models[index].seconds == nil { models[index].seconds = finishedAt!.timeIntervalSince(models[index].startedAt) }
    }
    public mutating func consume(_ event: OpenUIJSON) {
        let fields = event.object, type = fields["type"]?.text ?? ""
        func number(_ key: String) -> Double? { Double(fields[key]?.text ?? "") }
        func seconds(_ key: String) -> Double? { number(key).map { $0 / 1000 } }
        let timestamp = number("startedAt").map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
        if type == "plan", let data = try? JSONEncoder().encode(fields["steps"] ?? .array([])), let items = try? JSONDecoder().decode([AgentPlanItem].self, from: data) { plan = Array(items.prefix(16)); return }
        if type == "model_timing", let step = Int(fields["step"]?.text ?? ""), let index = models.lastIndex(where: { $0.step == step }) {
            models[index].model = fields["model"]?.text; models[index].seconds = seconds("elapsedMs"); models[index].queueSeconds = seconds("queueMs"); models[index].requestSeconds = seconds("requestMs"); models[index].promptSeconds = seconds("promptMs"); models[index].generationSeconds = seconds("generationMs"); models[index].outputTokens = Int(fields["outputTokens"]?.text ?? ""); return
        }
        guard type == "phase" else { return }
        let stage = fields["stage"]?.text ?? ""
        if stage == "model", let step = Int(fields["step"]?.text ?? "") { models.append(.init(step: step, startedAt: timestamp)); return }
        guard let id = fields["id"]?.text else { return }
        if stage == "tool_start" { tools.append(.init(id: id, tool: fields["name"]?.text ?? "tool", status: "running", startedAt: timestamp)) }
        else if let index = tools.lastIndex(where: { $0.id == id }) { tools[index].status = stage == "tool_error" ? "failed" : "completed"; tools[index].seconds = seconds("elapsedMs") }
        if tools.count > 128 { tools.removeFirst(tools.count - 128) }
    }
}
