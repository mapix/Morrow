import Foundation

/// Metadata and user/AI fields have distinct owners. Equality is structural,
/// so refreshes do not serialize multi-megabyte proof dictionaries on the UI.
public enum ContactProfilePersistence {
    public static func sameMetadata(_ lhs: ContactProfile, _ rhs: ContactProfile) -> Bool {
        lhs.email == rhs.email && lhs.name == rhs.name && lhs.aliases == rhs.aliases && lhs.mailIDs == rhs.mailIDs && lhs.accountIDs == rhs.accountIDs && lhs.received == rhs.received && lhs.sent == rhs.sent && lhs.copied == rhs.copied && lhs.firstSeen == rhs.firstSeen && lhs.lastSeen == rhs.lastSeen && lhs.topics == rhs.topics && lhs.fingerprint == rhs.fingerprint
    }
    public static func sameMutableFields(_ lhs: ContactProfile, _ rhs: ContactProfile) -> Bool {
        lhs.correction == rhs.correction && lhs.analysisFingerprint == rhs.analysisFingerprint && lhs.analysisStatus == rhs.analysisStatus && lhs.analyzedAt == rhs.analyzedAt && lhs.analyzedMailVersions == rhs.analyzedMailVersions && lhs.analysisRetryAt == rhs.analysisRetryAt && lhs.claims.count == rhs.claims.count && zip(lhs.claims, rhs.claims).allSatisfy { pair in pair.0.id == pair.1.id && pair.0.text == pair.1.text && pair.0.mailID == pair.1.mailID && pair.0.quote == pair.1.quote }
    }
    public static func preservingMutableFields(_ metadata: ContactProfile, from current: ContactProfile) -> ContactProfile {
        var value = metadata
        value.correction = current.correction; value.claims = current.claims
        value.analysisFingerprint = current.analysisFingerprint; value.analysisStatus = current.analysisStatus; value.analyzedAt = current.analyzedAt
        value.analyzedMailVersions = current.analyzedMailVersions; value.analysisRetryAt = current.analysisRetryAt
        return value
    }
}
