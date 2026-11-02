import Foundation
import MorrowCore

/// Capture observable inputs once, instead of reading @Published properties
/// repeatedly while filtering and sorting a large mailbox.
struct MailListScope {
    var destination: Destination
    var account: String?
    var folder: String?
    var unreadOnly: Bool
    var category: MailCategory?
    var roles: [String: String]
    var ownEmails: [String: String]
    var now: Date

    func matches(_ mail: MailMessage) -> Bool {
        if let account, mail.accountID != account { return false }
        if let folder, mail.folder != folder { return false }
        if unreadOnly && mail.isRead { return false }
        if let category, mail.analysis?.category != category { return false }
        let role = roles[mail.accountID + "\u{1f}" + mail.folder] ?? (mail.uid == 0 && mail.folder == "Sent" && mail.id.hasPrefix("sent:") ? "sent" : "inbox")
        switch destination {
        case .focus, .partner:
            let outbound = ownEmails[mail.accountID].map { own in
                mail.from.email.lowercased() == own && (mail.to.contains { $0.email.lowercased() != own } || role == "sent")
            } ?? false
            return mail.actionable && !outbound && role != "trash" && role != "junk" && (mail.snoozedUntil.map { $0 <= now } ?? true)
        case .starred: return mail.isStarred && role != "trash"
        case .snoozed: return mail.snoozedUntil.map { $0 > now } ?? false
        case .sent: return role == "sent"
        case .outbox, .drafts: return false
        case .trash: return role == "trash"
        default: return folder != nil || role == "inbox"
        }
    }
}

struct MailViewProjectionKey: Equatable {
    var revision: Int
    var metadata: Int
    var destination: String
    var account: String?
    var folder: String?
    var category: String?
    var unread: Bool
    var search: Bool
    var query: String
    var strategy: String
    var scope: String
    var results: Int
    var clockBucket: Int
}
