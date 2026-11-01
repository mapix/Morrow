import Foundation

/// A small fingerprint of every embedding input, independent of read/star flags.
/// Body bytes are represented by the persisted content revision.
public enum MailIndexInput {
    public static func key(for mail: MailMessage, attachments: Bool) -> String? {
        guard let revision = mail.contentRevision, !revision.isEmpty else { return nil }
        var fields = [[MailEvidence.version, "windows-v1-1024", revision, mail.subject,
                      mail.from.display, mail.from.email, mail.date.ISO8601Format(), mail.note,
                      String(attachments)], mail.labels]
        if attachments {
            fields.append([AttachmentTextExtractor.version])
            for attachment in mail.attachments {
                // Legacy attachment bytes must be checked once before they can
                // be represented by a reliable revision in a fast-path receipt.
                guard let digest = attachment.contentRevision else { return nil }
                fields.append([attachment.name, attachment.mimeType, digest, String(attachment.byteCount)])
            }
        }
        guard let data = try? JSONEncoder().encode(fields) else { return nil }
        return MailStore.hash(data)
    }
}

public struct MailRemoteFlagUpdate: Sendable {
    public var id: String
    public var read: Bool
    public var starred: Bool
    public var overrideModifiedAt: Date?
    public init(id: String, read: Bool, starred: Bool, overrideModifiedAt: Date? = nil) {
        self.id = id; self.read = read; self.starred = starred; self.overrideModifiedAt = overrideModifiedAt
    }
}
