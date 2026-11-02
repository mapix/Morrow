import Foundation
import MorrowCore

struct CompanionPaneLayout: Equatable {
    static let minimumWorkspace: CGFloat = 440
    static let minimumChat: CGFloat = 300
    static let maximumChat: CGFloat = 440
    static let divider: CGFloat = 1
    var workspace: CGFloat
    var chat: CGFloat
    static func resolve(available: CGFloat, preferredChat: CGFloat, expanded: Bool) -> Self {
        let measured = available.isFinite ? max(0, available) : 0
        guard expanded else { return .init(workspace: max(minimumWorkspace, measured), chat: 0) }
        let width = max(minimumWorkspace + minimumChat + divider, measured)
        let maximum = min(maximumChat, width - minimumWorkspace - divider)
        let preferred = preferredChat.isFinite ? preferredChat : 340
        let chat = min(max(minimumChat, preferred), maximum)
        return .init(workspace: width - chat - divider, chat: chat)
    }
}

struct CompanionActivity: Equatable {
    enum Kind: Equatable { case currentConversation, otherConversation, work }
    var kind: Kind
    var sessionID: String?
    var runID: String?
    var title: String
    var label: String {
        switch kind { case .currentConversation: return "当前对话正在处理"; case .otherConversation: return "另一对话正在处理"; case .work: return "工作正在推进" }
    }
    static func resolve(activeSessionID: String, executingSessionID: String?, sidebarRunning: Bool,
                        executingRunIDs: Set<String>, runs: [AgentRun]) -> Self? {
        if sidebarRunning, let session = executingSessionID {
            return .init(kind: session == activeSessionID ? .currentConversation : .otherConversation,
                         sessionID: session, runID: nil, title: "")
        }
        guard !executingRunIDs.isEmpty else { return nil }
        // A saved phase is not evidence that a task is alive. Only actual
        // execution IDs supplied by the host may create a running indicator.
        if let run = runs.filter({ executingRunIDs.contains($0.id) && [.queued, .reading, .working].contains($0.phase) }).max(by: { $0.updatedAt < $1.updatedAt }) {
            return .init(kind: .work, sessionID: nil, runID: run.id, title: run.title)
        }
        return nil
    }
}
