import Foundation
import MorrowCore

struct BriefConversationOrigin { let sessionID: String; let sourceChatID: String? }

extension AppModel {
    func rebuildBriefConversationOrigins() {
        var origins: [String: BriefConversationOrigin] = [:]
        for (sessionID, messages) in Dictionary(grouping: chat, by: { $0.sessionID ?? "legacy" }) {
            var sourceChatID: String?
            for message in messages.sorted(by: { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }) {
                if message.role == "user" { sourceChatID = message.id }
                let origin = BriefConversationOrigin(sessionID: sessionID, sourceChatID: sourceChatID)
                for id in message.artifactIDs ?? [] { origins[id] = origin }
                for tool in message.executionTrace?.tools ?? [] where tool.tool == "save_report" { origins[MailStore.hash(sessionID + ":" + tool.id)] = origin }
            }
        }
        briefConversationOrigins = origins
    }
    var briefArtifacts: [AgentArtifact] { agentArtifacts.filter(\.isBrief).sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt } }
    var selectedBrief: AgentArtifact? { briefArtifacts.first { $0.id == selectedBriefID } }
    func briefSessionID(_ artifact: AgentArtifact) -> String? {
        if let id = artifact.sessionID { return id }
        if let origin = briefConversationOrigins[artifact.id] { return origin.sessionID }
        let prefix = "sdk-chat:"
        if artifact.runID.hasPrefix(prefix) { return String(artifact.runID.dropFirst(prefix.count)) }
        return nil
    }
    func briefs(in sessionID: String) -> [AgentArtifact] { briefArtifacts.filter { briefSessionID($0) == sessionID } }
    func openBriefs(sessionID: String? = nil) { dismissInlineTools(); briefSessionFilter = sessionID; selectedBriefID = nil; workspacePage = .briefs }
    func openBrief(_ artifact: AgentArtifact) {
        guard artifact.isBrief else { return }
        dismissInlineTools(); selectedBriefID = artifact.id; workspacePage = .briefs
        if let id = briefSessionID(artifact), chatSessions.contains(where: { $0.id == id && !$0.archived }) { switchChatSession(id) }
    }
    func openBriefSource(_ artifact: AgentArtifact) async {
        guard let id = briefSessionID(artifact), chatSessions.contains(where: { $0.id == id }) else { error = "没有对应的来源对话"; return }
        if let chatID = artifact.sourceChatID ?? briefConversationOrigins[artifact.id]?.sourceChatID, chat.contains(where: { $0.id == chatID && $0.sessionID == id }) { await openSessionSource(id, chatID: chatID) }
        else { if chatSessions.first(where: { $0.id == id })?.archived == true { await archiveChatSession(id, archived: false) }; switchChatSession(id) }
    }
}
