import Foundation

/// Replies follow the direction of the original conversation. A message in
/// Sent is a follow-up to its recipients, not a new message to its own sender.
public struct ReplyRecipients: Sendable, Equatable {
    public let to: [MailAddress]
    public let cc: [MailAddress]
    public static func resolve(mail: MailMessage, ownEmails: Set<String>, isSent: Bool, replyAll: Bool) -> Self {
        let own = Set(ownEmails.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        func unique(_ values: [MailAddress], excluding excluded: Set<String> = []) -> [MailAddress] {
            var seen = excluded
            return values.filter { value in
                let key = value.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return !key.isEmpty && seen.insert(key).inserted
            }
        }
        let primary: [MailAddress]
        if isSent {
            let external = unique(mail.to, excluding: own)
            primary = external.isEmpty ? unique(mail.to) : external
        } else { primary = unique(mail.replyTo.isEmpty ? [mail.from] : mail.replyTo) }
        guard replyAll else { return .init(to: primary, cc: []) }
        let excluded = own.union(primary.map { $0.email.lowercased() })
        let copied = unique(isSent ? mail.cc : mail.to + mail.cc, excluding: excluded)
        return .init(to: primary, cc: copied)
    }
}
