import Foundation

public enum DraftDeliveryOutcome: String, Sendable { case sent, uncertain, cancelled }
public struct DraftDeliveryReceipt: Codable, Sendable {
    public let id: String
    public let accountID: String
    public let messageID: String
    public let confirmedAt: Date
    public let source: String
}

