import Foundation
import MorrowCore

/// Fictional presentation state for the isolated native gallery. This never
/// creates SDK checkpoints, workspaces, model requests or gateway jobs.
@MainActor enum UIQualityChatFixture {
    static let screens = ["chat-question", "chat-media-job", "chat-failed", "chat-empty"]
    private static let primarySessionID = "quality-chat-primary"
    private static let secondarySessionID = "quality-chat-secondary"
    private static let primaryRunID = "sdk-run:quality-review"
    private static let secondaryRunID = "sdk-run:quality-contract"
    private static let date = Date(timeIntervalSince1970: 1_793_584_800)
    private static var baselines: [ObjectIdentifier: Baseline] = [:]

    /// Call before selecting every gallery screen. Returning false also
    /// restores the previous chat state, so later screens keep their fixture.
    static func configure(screen: String, model: AppModel) -> Bool {
        guard model.isQualityPreview else { return false }
        let key = ObjectIdentifier(model)
        guard screens.contains(screen) else {
            if let baseline = baselines.removeValue(forKey: key), baseline.owner === model { baseline.restore(in: model) }
            return false
        }
        if baselines[key]?.owner !== model { baselines[key] = Baseline(model: model) }

        let english = L10n.languageCode != "zh-Hans"
        func words(_ chinese: String, _ englishText: String) -> String { english ? englishText : chinese }
        var reviewContext = WorkspaceContext(page: "materials", label: words("示例评审材料", "Sample review materials"))
        reviewContext.scopeMode = "scope"
        var contractContext = WorkspaceContext(page: "materials", label: words("示例合同材料", "Sample contract materials"))
        contractContext.scopeMode = "scope"
        var primary = ChatSession(id: primarySessionID, title: words("项目材料与回复", "Project review and reply"))
        primary.createdAt = date; primary.updatedAt = date; primary.pinnedContext = reviewContext
        var secondary = ChatSession(id: secondarySessionID, title: words("合同条款核对", "Contract review"))
        secondary.createdAt = date.addingTimeInterval(-3600); secondary.updatedAt = secondary.createdAt
        secondary.input = words("保留在另一段对话中的未发送内容。", "Unsent text retained in the other conversation.")
        secondary.pinnedContext = contractContext
        let secondaryHuman = message(id: "quality-contract-request", role: "user", text: words("核对示例合同中的验收期限。", "Check the acceptance date in the sample contract."), sessionID: secondarySessionID, runID: secondaryRunID, context: contractContext, offset: -3600)
        let secondaryReply = message(id: "quality-contract-reply", role: "partner", text: words("合同中的验收期限尚待确认，已保留这项问题。", "The acceptance date still needs confirmation. This question has been retained."), sessionID: secondarySessionID, runID: secondaryRunID, context: contractContext, offset: -3580)
        var primaryMessages: [PartnerChat] = []
        var interactions: [OpenUIInteraction] = []

        if screen != "chat-empty" {
            let request = words("核对示例评审材料，整理需要确认的问题。", "Review the sample materials and identify what needs confirmation.")
            let human = message(id: "quality-review-request", role: "user", text: request, sessionID: primarySessionID, runID: primaryRunID, context: reviewContext, offset: 0)
            var reply = message(id: "quality-review-reply", role: "partner", text: "", sessionID: primarySessionID, runID: primaryRunID, context: reviewContext, offset: 20)
            switch screen {
            case "chat-question":
                reply.text = words("继续整理前，需要确认本次核对范围。", "Confirm the review scope before I continue.")
                reply.sdkResumeKind = "question"
                reply.continuationPrompt = words("按确认的评审范围继续。", "Continue with the confirmed review scope.")
                let title = words("本次需要核对哪些内容？", "What should this review cover?")
                let placeholder = words("填写核对范围", "Enter the review scope")
                let answer = words("交付范围与验收期限", "Delivery scope and acceptance date")
                let button = words("确认范围并继续", "Confirm scope and continue")
                let source = "root = Form(\"choice\", [TextContent(\(quote(title))), TextArea(\"response\", \(quote(placeholder)), \(quote(answer))), Button(\(quote(button)), @ToAssistant(\(quote(button))))])"
                var page = OpenUIInteraction(source: source, runID: primaryRunID)
                page.id = "quality-review-question"; page.sessionID = primarySessionID; page.chatID = reply.id; page.createdAt = date.addingTimeInterval(20)
                reply.openUIID = page.id
                interactions = [page]
            case "chat-media-job":
                reply.text = words("示例视频任务正在等待结果。完成后会显示预览。", "The sample video job is awaiting its result. A preview will appear when it finishes.")
                reply.sdkResumeKind = "mediaJob"
                reply.workspaceVideoJobs = fictionalLease().map { [AgentWorkspaceVideoJob(id: "quality-fictional-video-job", model: "veo-3.1-fast-generate-preview", lease: $0)] }
            case "chat-failed":
                reply.text = words("示例任务在整理材料时中断，原始要求和资料范围已保留。可以继续这项任务。", "The sample review was interrupted. The original request and material scope have been retained. You can continue this task.")
                reply.sdkResumeKind = "continuation"
                reply.continuationPrompt = words("继续核对示例评审材料。", "Continue reviewing the sample materials.")
                var trace = AgentExecutionTrace(); trace.startedAt = date; trace.finishedAt = date.addingTimeInterval(18); trace.status = "failed"
                reply.executionTrace = trace
            default: break
            }
            primaryMessages = [human, reply]
        }

        // Set presentation data directly; session-switch helpers persist state.
        model.chatSessions = [primary, secondary]
        model.chat = [secondaryHuman, secondaryReply] + primaryMessages
        model.openUIInteractions = interactions
        model.activeSessionID = primarySessionID
        model.chatInput = primary.input; model.chatMaterials = primary.materials
        model.chatPinnedContext = primary.pinnedContext; model.newChatWork = primary.newWork
        model.scrollChatID = primaryMessages.last?.id
        return true
    }

    private static func message(id: String, role: String, text: String, sessionID: String, runID: String, context: WorkspaceContext, offset: TimeInterval) -> PartnerChat {
        var value = PartnerChat(role: role, text: text)
        value.id = id; value.sessionID = sessionID; value.sdkRunID = runID; value.context = context; value.date = date.addingTimeInterval(offset)
        return value
    }
    private static func quote(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value), let text = String(data: data, encoding: .utf8) else { return "\"\"" }
        return text
    }
    private static func fictionalLease() -> AgentWorkspaceLease? {
        // Codable supplies a presentation value without opening a real lease.
        // Quality mode blocks polling before this nonexistent path is consulted.
        let value = "{\"sessionID\":\"quality-chat-primary\",\"generation\":\"quality-fictional-generation\",\"directory\":\"file:///private/tmp/morrow-quality-fictional-chat/\"}"
        return try? JSONDecoder().decode(AgentWorkspaceLease.self, from: Data(value.utf8))
    }

    @MainActor private final class Baseline {
        weak var owner: AppModel?
        let chat: [PartnerChat]
        let sessions: [ChatSession]
        let interactions: [OpenUIInteraction]
        let sessionID: String
        let input: String
        let materials: [ChatMaterial]
        let context: WorkspaceContext?
        let newWork: Bool
        let scrollID: String?
        init(model: AppModel) {
            owner = model; chat = model.chat; sessions = model.chatSessions; interactions = model.openUIInteractions
            sessionID = model.activeSessionID; input = model.chatInput; materials = model.chatMaterials
            context = model.chatPinnedContext; newWork = model.newChatWork; scrollID = model.scrollChatID
        }
        func restore(in model: AppModel) {
            model.chatSessions = sessions; model.chat = chat; model.openUIInteractions = interactions; model.activeSessionID = sessionID
            model.chatInput = input; model.chatMaterials = materials; model.chatPinnedContext = context; model.newChatWork = newWork; model.scrollChatID = scrollID
        }
    }
}
