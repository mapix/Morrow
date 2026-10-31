import Foundation
import MorrowCore

struct MobileDraftSnapshot {
    let draft: ComposeDraft
    let owner: UUID
    let revision: Int
}

extension MobileModel {
    func activateDraft(_ value: ComposeDraft, owner: UUID) {
        guard value.state == "draft" else { return }
        draftOwner = owner; workingDraft = value; workingDraftRevision = 0
    }
    func publishDraft(_ value: ComposeDraft, owner: UUID) {
        guard draftOwner == owner, workingDraft?.id == value.id, value.state == "draft" else { return }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let old = (try? encoder.encode(workingDraft)) ?? Data()
        let new = (try? encoder.encode(value)) ?? Data()
        guard old != new else { return }
        workingDraft = value; workingDraftRevision += 1
    }
    func captureDraft() -> MobileDraftSnapshot? {
        guard let value = workingDraft, let owner = draftOwner, value.state == "draft" else { return nil }
        return MobileDraftSnapshot(draft: value, owner: owner, revision: workingDraftRevision)
    }
    func releaseDraft(owner: UUID) {
        guard draftOwner == owner else { return }
        workingDraft = nil; draftOwner = nil
    }
    func applyDraftUpdate(_ snapshot: MobileDraftSnapshot, body: String?, subject: String?) async throws -> String {
        guard body != nil || subject != nil else { throw MailError.message("草稿修改没有提供新内容。") }
        var updated = snapshot.draft; updated.body = body ?? updated.body; updated.subject = subject ?? updated.subject; updated.updatedAt = Date()
        let sameOwner = draftOwner == snapshot.owner && workingDraft?.id == snapshot.draft.id && workingDraftRevision == snapshot.revision
        let stored = try await store.object(ComposeDraft.self, kind: "draft", id: snapshot.draft.id)
        guard stored.map({ $0.state == "draft" }) ?? true else { throw MailError.message("草稿已经进入发送流程，修改未应用。") }
        if !sameOwner || (stored?.updatedAt ?? .distantPast) > snapshot.draft.updatedAt {
            updated.id = UUID().uuidString; updated.state = "draft"
            try await store.commitWorkingDraft(updated, artifact: nil); await reload()
            return "编辑期间草稿发生变化；你的输入已保留，AI 建议保存为另一份草稿。Draft ID: " + updated.id
        }
        var artifact = try await store.load(AgentArtifact.self, kind: "agent-artifact").first { $0.linkedDraftID == updated.id }
        artifact?.content = updated.body; artifact?.title = updated.subject; artifact?.updatedAt = updated.updatedAt
        try await store.commitWorkingDraft(updated, artifact: artifact)
        // The await above may overlap a later user edit. Preserve it rather than
        // pushing an old model result back into the live text editor.
        if draftOwner == snapshot.owner, workingDraftRevision == snapshot.revision {
            workingDraft = updated; workingDraftRevision += 1
        }
        await reload(); return "草稿与对应工作输出已保存，未发送。Draft ID: " + updated.id
    }
    func appendVoice(_ text: String, sessionID: String) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              var session = sessions.first(where: { $0.id == sessionID }) else { return }
        session.input += (session.input.isEmpty ? "" : "\n") + text; session.draftRevision += 1
        sessions = sessions.map { $0.id == sessionID ? session : $0 }; await updateSession(session)
    }
}
