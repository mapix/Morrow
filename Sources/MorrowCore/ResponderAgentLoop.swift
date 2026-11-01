import Foundation

public struct ResponderVerification: Codable, Sendable {
    public var approved: Bool
    public var issues: [String]
    public init(approved: Bool, issues: [String] = []) { self.approved = approved; self.issues = issues }
    private enum CodingKeys: String, CodingKey { case approved, issues }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        approved = try values.decode(Bool.self, forKey: .approved)
        issues = try values.decodeIfPresent([String].self, forKey: .issues) ?? []
    }
}
public struct ResponderAgentResult: Sendable {
    public var body: String
    public var analysis: String
    public var turns: Int
}

/// Every response uses the same bounded read/plan/tool/verify loop. Tool and
/// delivery authority are checked by the host, independently of model output.
public enum ResponderAgentLoop {
    public static let maximumTurns = 6
    public static let maximumTools = 10
    public static func run(mail: MailMessage, attachmentIDs: Set<String>, fixedBody: String? = nil, policy: ResponderExecutionPolicy = .init(),
        plan: @escaping ([PartnerChat]) async throws -> PartnerPlan,
        tool: @escaping (PartnerOperation) async throws -> String,
        verify: @escaping (String, [PartnerChat]) async throws -> ResponderVerification,
        checkpoint: @escaping () async throws -> Void,
        progress: @escaping (String, String) async -> Void = { _, _ in }) async throws -> ResponderAgentResult {
        try policy.validate()
        return try await withThrowingTaskGroup(of: ResponderAgentResult.self) { group in
            group.addTask { try await perform(mail: mail, attachmentIDs: attachmentIDs, fixedBody: fixedBody, policy: policy, plan: plan, tool: tool, verify: verify, checkpoint: checkpoint, progress: progress) }
            group.addTask { try await Task.sleep(for: .seconds(policy.maximumSeconds)); throw MailError.message("响应器达到总执行时间预算，已取消工具和模型请求；未投递。") }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
    }
    private static func perform(mail: MailMessage, attachmentIDs: Set<String>, fixedBody: String?, policy: ResponderExecutionPolicy,
        plan: ([PartnerChat]) async throws -> PartnerPlan, tool: (PartnerOperation) async throws -> String,
        verify: (String, [PartnerChat]) async throws -> ResponderVerification, checkpoint: () async throws -> Void,
        progress: (String, String) async -> Void) async throws -> ResponderAgentResult {
        try policy.validate()
        let deadline = Date().addingTimeInterval(Double(policy.maximumSeconds))
        var history: [PartnerChat] = []
        var tools = 0
        try await checkpoint()
        await progress("reading", "读取触发邮件的正文")
        let observation = try await tool(.init(type: "read", messageID: mail.id))
        history.append(PartnerChat(role: "tool", text: String(observation.prefix(4000)), messageIDs: [mail.id])); tools += 1
        for turn in 1...policy.maximumTurns {
            guard Date() < deadline else { throw MailError.message("响应器达到总执行时间预算，未投递。") }
            try Task.checkCancellation(); try await checkpoint()
            await progress("planning", "第\(turn)轮：根据实际资料规划回复")
            let next = try await plan(history)
            guard next.openUI == nil || next.openUI?.isEmpty == true,
                  (next.messageIDs ?? []).allSatisfy({ $0 == mail.id }), (next.operations ?? []).count <= 3 else {
                throw MailError.message("响应方案超出了绑定来源或工具数量，未交付。")
            }
            let operations = next.operations ?? []
            for op in operations {
                guard op.messageID == nil || op.messageID == mail.id,
                      op.accountID == nil || op.accountID == mail.accountID,
                      op.recipient == nil || op.recipient?.caseInsensitiveCompare(mail.from.email) == .orderedSame,
                      op.type == "draft" || policy.allowedTools.contains(op.type) else {
                    throw MailError.message("响应器请求了未授权的来源、收件人或工具，未交付。")
                }
                if op.type == "readAttachment", !attachmentIDs.contains(op.text ?? "") { throw MailError.message("附件不属于触发邮件，未读取。") }
            }
            let reads = operations.filter { $0.type != "draft" }
            if !reads.isEmpty {
                guard !operations.contains(where: { $0.type == "draft" }) else { throw MailError.message("读取和交付必须分轮完成，未交付。") }
                guard tools + reads.count <= policy.maximumTools else { throw MailError.message("响应器达到工具执行上限，未交付。") }
                for op in reads {
                    try await checkpoint(); await progress("tool", op.type)
                    let result = try await tool(op)
                    history.append(PartnerChat(role: "tool", text: String(result.prefix(4000)), messageIDs: [mail.id])); tools += 1
                }
                continue
            }
            guard operations.count == 1, let draft = operations.first, draft.type == "draft",
                  let body = draft.text, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, body.utf8.count <= 32768 else {
                history.append(PartnerChat(role: "tool", text: "还没有形成回复。请返回一个 draft 操作，text 是要发送的完整正文；不能把分析或计划当成已发送回复。")); continue
            }
            if let fixedBody, body != fixedBody {
                history.append(PartnerChat(role: "tool", text: "固定正文不允许改写。请逐字使用用户设定、变量展开后的正文。")); continue
            }
            try await checkpoint(); await progress("verifying", "核对来源、事实和回复正文")
            let reviewed = try await verify(body, history)
            if reviewed.approved {
                guard Date() < deadline else { throw MailError.message("核对完成时已超过执行预算，未投递。") }
                try await checkpoint()
                return ResponderAgentResult(body: body, analysis: next.answer, turns: turn)
            }
            history.append(PartnerChat(role: "tool", text: "回复核对未通过，请修正后再次提交：" + reviewed.issues.prefix(6).map { String($0.prefix(500)) }.joined(separator: "；")))
        }
        throw MailError.message("响应器达到\(policy.maximumTurns)轮上限，尚未通过核对；没有发送回复。")
    }
}

extension PartnerEngine {
    public func responderPlan(rule: MailResponder, mail: MailMessage, history: [PartnerChat], settings: AgentSettings, fixedBody: String?) async throws -> PartnerPlan {
        try await makeResponderPlan(rule: rule, mail: mail, history: history, settings: settings, fixedBody: fixedBody)
    }
}
