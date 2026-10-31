import Foundation

public enum DelegationPolicy {
    public static func maySend(_ draft: ComposeDraft, delegation: Delegation, accounts: [MailAccount]) -> Bool {
        let recipients = draft.addresses(draft.to) + draft.addresses(draft.cc) + draft.addresses(draft.bcc)
        return delegation.active && delegation.sendAuthorized && MailAddress.isValid(delegation.recipient) && recipients.count == 1 && recipients[0].email.caseInsensitiveCompare(delegation.recipient) == .orderedSame && accounts.contains { $0.id == draft.accountID && !$0.isDemo && $0.enabled }
    }
    public static func runID(delegation: Delegation, evidence: [MailMessage], now: Date) -> String {
        let timed = ["briefing", "followUp"].contains(delegation.kind)
        let timeKey = timed ? String(Int((delegation.nextRun ?? now).timeIntervalSince1970)) : "incoming"
        return "delegation-" + MailStore.hash(delegation.id + ":" + timeKey + ":" + evidence.map(\.canonicalID).sorted().joined(separator: ","))
    }
}
