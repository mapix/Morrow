import Foundation
import MorrowCore

/// Temporary feedback for a mail action, not another work lifecycle.
struct MailFolderMutation {
    let nonce: UUID
    let destination: MailFolder
    var acknowledged = false
    var awaitingSync = false
    var task: Task<Void, Never>?
}
struct MailFolderCacheChange {
    let version: Int
    let header: MailMessage?
}
