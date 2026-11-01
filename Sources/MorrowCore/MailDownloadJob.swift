import Foundation

/// Raw data lives at the final mail cache path. This record is a durable
/// processing receipt, not another raw-mail copy or database backup.
public struct MailDownloadJob: Codable, Identifiable, Sendable {
    public var accountID: String
    public var folder: String
    public var uid: UInt64
    public var validity: UInt64
    public var read: Bool
    public var starred: Bool
    public var byteCount: Int
    public var inventoryStarted: Date
    public var downloadedAt = Date()
    public var id: String { "\(accountID):\(folder):\(validity):\(uid)" }
    public init(accountID: String, folder: String, uid: UInt64, validity: UInt64, read: Bool, starred: Bool, byteCount: Int, inventoryStarted: Date) {
        self.accountID = accountID; self.folder = folder; self.uid = uid; self.validity = validity; self.read = read; self.starred = starred; self.byteCount = byteCount; self.inventoryStarted = inventoryStarted
    }
    public static let maximumPending = 32
    public static let maximumPendingBytes = 128 * 1024 * 1024
}
public struct MailDownloadQueueState: Sendable {
    public var count: Int
    public var bytes: Int
}
