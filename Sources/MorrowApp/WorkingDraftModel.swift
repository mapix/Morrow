import Foundation
import MorrowCore

extension AppModel {
    func draftIsEditable(_ draft: ComposeDraft) -> Bool { !["sent", "queued", "sending", "uncertain"].contains(draft.state) }
    func sameDraftContent(_ a: ComposeDraft, _ b: ComposeDraft) -> Bool {
        a.id == b.id && a.accountID == b.accountID && a.body == b.body && a.subject == b.subject && a.to == b.to && a.cc == b.cc && a.bcc == b.bcc && a.attachments == b.attachments && a.htmlBody == b.htmlBody && a.state == b.state && a.scheduledAt == b.scheduledAt && a.inReplyTo == b.inReplyTo && a.references == b.references && a.automaticResponse == b.automaticResponse
    }
    func activateWorkingDraft(_ draft: ComposeDraft, artifactID: String) {
        guard draftIsEditable(draft), drafts.first(where: { $0.id == draft.id }).map(draftIsEditable) ?? true else { return }
        if workingArtifactID == artifactID, let current = workingDraft, sameDraftContent(current, draft) { return }
        workingArtifactID = artifactID; workingDraft = draft
    }
    func liveSidebarDraft(id: String) -> ComposeDraft? {
        if let stored = drafts.first(where: { $0.id == id }), !draftIsEditable(stored) { return stored }
        if let current = workingDraft, current.id == id { return current }
        if let current = composer, current.id == id { return current }
        return nil
    }
    func workingArtifact(for draftID: String) -> AgentArtifact? {
        if let id = workingArtifactID, let artifact = agentArtifacts.first(where: { $0.id == id && $0.linkedDraftID == draftID }) { return artifact }
        return agentArtifacts.first { $0.linkedDraftID == draftID }
    }
    /// Publish a successful draft/artifact write together; failed writes never get a success receipt.
    @discardableResult func persistWorkingDraft(_ value: ComposeDraft, artifactID: String? = nil) async throws -> ComposeDraft {
        var draft = value; draft.updatedAt = Date()
        var artifact = artifactID.flatMap { id in agentArtifacts.first { $0.id == id && $0.linkedDraftID == draft.id } } ?? workingArtifact(for: draft.id)
        if var output = artifact {
            output.content = draft.body; output.title = draft.subject; output.updatedAt = draft.updatedAt
            artifact = output
        }
        try await store.commitWorkingDraft(draft, artifact: artifact)
        if let i = drafts.firstIndex(where: { $0.id == draft.id }) { drafts[i] = draft } else { drafts.append(draft) }
        if let artifact, let i = agentArtifacts.firstIndex(where: { $0.id == artifact.id }) { agentArtifacts[i] = artifact }
        return draft
    }
    func finishWorkingDraft(_ local: ComposeDraft, baseline: ComposeDraft, artifactID: String) async {
        let ownsBuffer = workingArtifactID == artifactID && workingDraft?.id == local.id
        let latest = ownsBuffer ? workingDraft ?? local : local
        // An old view must not write a stale local copy over a newer host result.
        let stored = drafts.first { $0.id == local.id }
        if draftIsEditable(latest), stored.map(draftIsEditable) ?? true,
           ownsBuffer || (stored.map({ sameDraftContent($0, baseline) }) ?? true) {
            do { _ = try await persistWorkingDraft(latest, artifactID: artifactID) } catch { self.error = error.localizedDescription }
        }
        if workingArtifactID == artifactID, let current = workingDraft, sameDraftContent(current, latest) { workingDraft = nil; workingArtifactID = nil }
    }
}
