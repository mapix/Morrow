import Foundation
import MorrowCore

struct BriefConversationOrigin { let sessionID: String; let sourceChatID: String? }

extension AppModel {
    func rebuildBriefConversationOrigins() {
        var origins: [String: BriefConversationOrigin] = [:]
        for (sessionID, messages) in Dictionary(grouping: chat, by: { $0.sessionID ?? "legacy" }) {
            var sourceChatID: String?
            var sourcesByRun: [String: String] = [:]
            for message in messages.sorted(by: { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }) {
                if message.role == "user" { sourceChatID = message.id; if let run = message.sdkRunID { sourcesByRun[run] = message.id } }
                let origin = BriefConversationOrigin(sessionID: sessionID, sourceChatID: message.sdkRunID.flatMap { sourcesByRun[$0] } ?? sourceChatID)
                for id in message.artifactIDs ?? [] { origins[id] = origin }
                for tool in message.executionTrace?.tools ?? [] where tool.tool == "save_report" {
                    origins[MailStore.hash(sessionID + ":" + tool.id)] = origin
                    if let run = message.sdkRunID { origins[MailStore.hash(sessionID + ":" + run + ":" + tool.id)] = origin }
                }
            }
        }
        briefConversationOrigins = origins
    }
    var briefArtifacts: [AgentArtifact] { agentArtifacts.filter(\.isBrief).sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt } }
    var selectedBrief: AgentArtifact? { briefArtifacts.first { $0.id == selectedBriefID } }
    func briefSessionID(_ artifact: AgentArtifact) -> String? {
        if let id = artifact.sessionID { return id }
        if let origin = briefConversationOrigins[artifact.id] { return origin.sessionID }
        let linkedRuns = agentRuns.filter { $0.artifactIDs.contains(artifact.id) }
        let linkedSessions = Set(linkedRuns.compactMap { confirmedSessionID(for: $0) })
        if linkedSessions.count == 1 { return linkedSessions.first }
        if !linkedRuns.isEmpty { return nil }
        if let run = agentRuns.first(where: { $0.id == artifact.runID }) { return confirmedSessionID(for: run) }
        return legacySDKSessionID(artifact.runID)
    }
    private func confirmedSessionID(for run: AgentRun) -> String? {
        if let id = run.sessionID { return chatSessions.contains { $0.id == id } ? id : nil }
        return legacySDKSessionID(run.id)
    }
    private func legacySDKSessionID(_ runID: String) -> String? {
        let prefix = "sdk-chat:"
        guard runID.hasPrefix(prefix) else { return nil }
        let id = String(runID.dropFirst(prefix.count))
        guard !id.hasPrefix("sdk-run:"), chatSessions.contains(where: { $0.id == id }) else { return nil }
        return id
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
