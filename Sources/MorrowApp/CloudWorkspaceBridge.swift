import Foundation
import MorrowCore

extension AppModel {
    func reloadCloudWorkspace() async {
        do {
            let localSession = chatSessions.first { $0.id == activeSessionID }
            var sessions = try await store.load(ChatSession.self, kind: "chat-session")
            // The active editor is user-owned; arriving sync must not replace unsaved text or files.
            if let localSession, let i = sessions.firstIndex(where: { $0.id == activeSessionID }) {
                sessions[i].input = localSession.input; sessions[i].materials = localSession.materials
                sessions[i].draftRevision = localSession.draftRevision
            }
            chatSessions = sessions
            chat = try await store.load(PartnerChat.self, kind: "chat")
            memories = try await store.load(AgentMemory.self, kind: "agent-memory")
            contacts = try await store.load(ContactEntry.self, kind: "contact")
            agentArtifacts = try await store.load(AgentArtifact.self, kind: "agent-artifact")
            await refreshContactProfiles(); scheduleMemoryIndex()
        } catch { self.error = error.localizedDescription }
    }
}
