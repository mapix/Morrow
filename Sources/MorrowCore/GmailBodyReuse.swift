import Foundation

/// Gmail's immutable global identity disambiguates RFC Message-ID collisions
/// across folders. Folder UIDs alone never authorize body reuse.
public struct GmailMessageIdentity: Codable, Sendable, Equatable {
    public var accountID: String
    public var folder: String
    public var uid: UInt64
    public var validity: UInt64
    public var globalID: String
    public var messageID: String
    public var rawSize: UInt64
    public var accountFingerprint: String?
    public var id: String { MailStore.hash(accountID + "\n" + folder + "\n" + String(validity) + "\n" + String(uid)) }
    public init(accountID: String, folder: String, uid: UInt64, validity: UInt64, globalID: String, messageID: String, rawSize: UInt64) {
        self.accountID = accountID; self.folder = folder; self.uid = uid; self.validity = validity
        self.globalID = globalID; self.messageID = messageID.trimmingCharacters(in: .whitespacesAndNewlines); self.rawSize = rawSize
    }
    public var valid: Bool {
        uid > 0 && uid <= UInt64(UInt32.max) && validity > 0 && validity <= UInt64(UInt32.max)
            && UInt64(globalID).map({ $0 > 0 }) == true && !messageID.isEmpty && messageID.utf8.count <= 4096
            && rawSize > 0 && rawSize <= 64 * 1024 * 1024
    }
    public var mailID: String { "\(accountID):\(folder):\(validity):\(uid)" }
    public static func lookupID(accountID: String, folder: String, uid: UInt64, validity: UInt64) -> String {
        MailStore.hash(accountID + "\n" + folder + "\n" + String(validity) + "\n" + String(uid))
    }
}
