import Foundation

/// Credentials, provider caches and executable queues deliberately have separate owners.
public enum CloudWorkspacePolicy {
    public static let kinds: Set<String> = ["chat-session", "chat", "agent-memory", "contact", "agent-artifact"]
    public static let maximumAssetBytes = 50 * 1024 * 1024
    public static func objectID(_ data: Data, kind: String) throws -> String {
        let decoder = JSONDecoder()
        switch kind {
        case "chat-session": return try decoder.decode(ChatSession.self, from: data).id
        case "chat": return try decoder.decode(PartnerChat.self, from: data).id
        case "agent-memory": return try decoder.decode(AgentMemory.self, from: data).id
        case "contact": return try decoder.decode(ContactEntry.self, from: data).id
        case "agent-artifact": return try decoder.decode(AgentArtifact.self, from: data).id
        default: throw MailError.message("Invalid iCloud object type.")
        }
    }
    public static func preparedPayload(_ data: Data, kind: String) throws -> Data {
        let decoder = JSONDecoder(), encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        switch kind {
        case "chat-session": return try encoder.encode(decoder.decode(ChatSession.self, from: data))
        case "chat": return try encoder.encode(decoder.decode(PartnerChat.self, from: data))
        case "agent-memory":
            var value = try decoder.decode(AgentMemory.self, from: data)
            value.embedding = nil; value.embeddingModel = nil
            return try encoder.encode(value)
        case "contact": return try encoder.encode(decoder.decode(ContactEntry.self, from: data))
        case "agent-artifact":
            var value = try decoder.decode(AgentArtifact.self, from: data)
            value.linkedDraftID = nil
            return try encoder.encode(value)
        default: throw MailError.message("This record is excluded from iCloud synchronization.")
        }
    }
}
public struct CloudWorkspaceChange: Codable, Sendable, Identifiable {
    public var kind: String
    public var objectID: String
    public var payload: Data?
    public var clock: Int64
    public var deviceID: String
    public var dirty: Bool
    public var id: String { MailStore.hash(kind + ":" + objectID) }
    public init(kind: String, objectID: String, payload: Data?, clock: Int64, deviceID: String, dirty: Bool = true) {
        self.kind = kind; self.objectID = objectID; self.payload = payload; self.clock = clock; self.deviceID = deviceID; self.dirty = dirty
    }
    public func precedes(_ other: Self) -> Bool { clock == other.clock ? deviceID < other.deviceID : clock < other.clock }
}
public struct CloudWorkspaceConflict: Codable, Identifiable, Sendable {
    public var id: String
    public var kind: String
    public var objectID: String
    public var localPayload: Data?
    public var remotePayload: Data?
    public var createdAt: Date
    public init(local: CloudWorkspaceChange, remote: CloudWorkspaceChange) {
        id = local.id + ":" + String(local.clock) + ":" + String(remote.clock)
        kind = local.kind; objectID = local.objectID; localPayload = local.payload; remotePayload = remote.payload; createdAt = Date()
    }
}
