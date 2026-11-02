import Foundation
import MorrowCore

/// Dialogue is shared by the conversation; SDK execution checkpoints remain
/// task-specific. A pinned evidence scope admits only dialogue from that scope.
enum ChatConversationHistory {
    static func messages(_ history: [PartnerChat], before currentID: String, scope: WorkspaceContext?, executionID: String?, resuming: Bool, materialIDs: Set<String> = []) -> [OpenUIJSON] {
        let preceding = records(history, before: currentID, scope: scope, materialIDs: materialIDs).filter { message in
            !resuming || message.sdkRunID == executionID
        }
        var selected: [OpenUIJSON] = [], remaining = 24_000
        for message in preceding.suffix(24).reversed() {
            let value = clipped(message.text, limit: min(6_000, remaining))
            guard !value.isEmpty else { continue }
            selected.append(.object(["role": .string(message.role), "text": .string(value)]))
            remaining -= value.count
            if remaining < 256 { break }
        }
        return selected.reversed()
    }
    private static func records(_ history: [PartnerChat], before currentID: String, scope: WorkspaceContext?, materialIDs: Set<String>) -> [PartnerChat] {
        var materialTurnMatches = false
        return Array(history.prefix { $0.id != currentID }.filter { message in
            guard ["user", "partner"].contains(message.role) else { return false }
            guard let scope, scope.enforcesMailScope else { return true }
            if scope.page == "materials", message.role == "user" { materialTurnMatches = !materialIDs.isEmpty && Set((message.materials ?? []).map(\.id)) == materialIDs }
            guard let previous = message.context, previous.enforcesMailScope else { return false }
            return sameScope(previous, scope) && (scope.page != "materials" || materialTurnMatches)
        })
    }
    /// Evidence for pre-filling a disabled, review-required responder. Neither
    /// assistant suggestions nor contact/mail evidence grants a sender scope.
    static func userAddresses(_ history: [PartnerChat], before currentID: String, scope: WorkspaceContext?, current: String, materialIDs: Set<String> = []) -> Set<String> {
        let texts = records(history, before: currentID, scope: scope, materialIDs: materialIDs).suffix(24).filter { $0.role == "user" }.map(\.text) + [current]
        guard let regex = try? NSRegularExpression(pattern: #"[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#) else { return [] }
        return Set(texts.flatMap { text in
            regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match -> String? in
                guard let range = Range(match.range, in: text) else { return nil }
                let email = String(text[range]); return MailAddress.isValid(email) ? email.lowercased() : nil
            }
        })
    }
    private static func clipped(_ text: String, limit: Int) -> String {
        guard limit > 0 else { return "" }
        guard text.count > limit else { return text }
        let marker = "\n[较长历史消息的中间部分已省略；未展示内容不能视为已核验。]\n"
        let available = max(0, limit - marker.count), head = available * 2 / 3
        return String(text.prefix(head)) + marker + String(text.suffix(available - head))
    }
    private static func sameScope(_ left: WorkspaceContext, _ right: WorkspaceContext) -> Bool {
        guard left.page == right.page, Set(left.mailIDs) == Set(right.mailIDs),
              Set(left.attachmentIDs) == Set(right.attachmentIDs), left.contactEmail == right.contactEmail,
              left.accountID == right.accountID, left.runID == right.runID, left.draftID == right.draftID,
              left.artifactID == right.artifactID, left.query == right.query, left.filter == right.filter else { return false }
        switch (left.mailList, right.mailList) {
        case (nil, nil): return left.page != "materials" || left.label == right.label
        case (let a?, let b?):
            return Set(a.accountIDs) == Set(b.accountIDs) && a.folderPath == b.folderPath && a.destination == b.destination && a.unreadOnly == b.unreadOnly && a.category == b.category && a.folderRoles == b.folderRoles
        default: return false
        }
    }
}
