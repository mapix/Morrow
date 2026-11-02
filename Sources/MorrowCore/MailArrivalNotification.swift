import Foundation

public enum MailArrivalNotificationPolicy {
    public static func isNewArrival(uid: UInt64, inventory: MailSyncInventory, previous: MailFolderSyncCursor?, account: MailAccount, folder: MailFolder) -> Bool {
        guard folder.role == "inbox", !account.isDemo, let previous, previous.matches(account, folder: folder.path), previous.validity == inventory.validity else { return false }
        // Cursors persist known UIDs in ascending order. Avoid constructing a
        // 50k-element set for each missing historical body in a sync plan.
        let next = previous.uidNext ?? previous.knownUIDs.last.map { $0 + 1 }
        guard let next else { return false }
        return uid >= next && !previous.knownUIDs.contains(uid) && !inventory.deletedUIDs.contains(uid)
    }
    public static func shouldNotify(_ mail: MailMessage, isNewArrival: Bool, account: MailAccount, folders: [MailFolder], ownEmails: Set<String>) -> Bool {
        let hasServerIdentity = account.usesPOP ? mail.popUID?.isEmpty == false : mail.uid > 0 && mail.uidValidity > 0
        guard isNewArrival, !account.isDemo, mail.accountID == account.id, hasServerIdentity,
              folders.contains(where: { $0.accountID == account.id && $0.path == mail.folder && $0.role == "inbox" }) else { return false }
        return !Set(ownEmails.map { $0.lowercased() }).contains(mail.from.email.lowercased())
    }
}

public struct POPArrivalCursor: Codable, Sendable {
    public let accountFingerprint: String
    public let knownUIDs: Set<String>
    public init(account: MailAccount, knownUIDs: Set<String>) { accountFingerprint = MailFolderSyncCursor.fingerprint(account); self.knownUIDs = knownUIDs }
    public func newUIDs(account: MailAccount, current: Set<String>) -> Set<String> {
        accountFingerprint == MailFolderSyncCursor.fingerprint(account) ? current.subtracting(knownUIDs) : []
    }
}

public struct MailArrivalNotice: Sendable {
    public let id: String
    public let mailID: String
    public let createdAt: Date
}
