import Foundation

/// Metadata evidence for choosing which contacts warrant a body read. These
/// signals describe correspondence; they do not establish a human identity.
public struct ContactTriage: Sendable {
    public var profile: ContactProfile
    public var mails: [MailMessage]
    public var directReceived: Int
    public var directSent: Int
    public var copied: Int
    public var automationHints: [String]
    public var hasDirectExchange: Bool { directReceived > 0 && directSent > 0 }

    public var samples: [MailMessage] {
        var result: [MailMessage] = [], seen = Set<String>()
        let incoming = mails.first { $0.from.email.lowercased() == profile.email.lowercased() }
        let outgoing = mails.first { $0.from.email.lowercased() != profile.email.lowercased() && $0.to.contains { $0.email.lowercased() == profile.email.lowercased() } }
        for mail in [incoming, outgoing].compactMap({ $0 }) + mails {
            if seen.insert(mail.canonicalID).inserted { result.append(mail) }
            if result.count == 3 { break }
        }
        return result
    }

    public static func build(profiles: [ContactProfile], mails: [MailMessage], accounts: [MailAccount], includeUnmailed: Bool) -> [Self] {
        let own = Set(accounts.map { $0.email.lowercased() })
        let byID = Dictionary(mails.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return profiles.compactMap { profile -> Self? in
            var seen = Set<String>()
            let sources = profile.mailIDs.compactMap { byID[$0] }.filter { seen.insert($0.canonicalID).inserted }.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
            guard !sources.isEmpty || (includeUnmailed && profile.mailIDs.isEmpty) else { return nil }
            let email = profile.email.lowercased()
            let received = sources.filter { $0.from.email.lowercased() == email && $0.to.contains { own.contains($0.email.lowercased()) } }.count
            let sent = sources.filter { own.contains($0.from.email.lowercased()) && $0.to.contains { $0.email.lowercased() == email } }.count
            let copied = sources.filter { $0.cc.contains { $0.email.lowercased() == email } }.count
            let local = email.components(separatedBy: "@").first ?? ""
            let hints = ["no-reply", "noreply", "donotreply", "notification", "newsletter", "mailer-daemon"].filter { local.contains($0) }
            return Self(profile: profile, mails: sources, directReceived: received, directSent: sent, copied: copied, automationHints: hints)
        }
    }

    public static func interactionOrder(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.hasDirectExchange != rhs.hasDirectExchange { return lhs.hasDirectExchange }
        if (lhs.directSent > 0) != (rhs.directSent > 0) { return lhs.directSent > 0 }
        if lhs.directSent != rhs.directSent { return lhs.directSent > rhs.directSent }
        if lhs.directReceived != rhs.directReceived { return lhs.directReceived > rhs.directReceived }
        let left = lhs.mails.first?.date ?? .distantPast, right = rhs.mails.first?.date ?? .distantPast
        return left == right ? lhs.profile.email < rhs.profile.email : left > right
    }
}
