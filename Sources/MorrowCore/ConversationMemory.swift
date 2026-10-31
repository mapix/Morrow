import Foundation

public struct ChatSession: Codable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    public var archived = false
    public var input = ""
    public var materials: [ChatMaterial] = []
    public var pinnedContext: WorkspaceContext?
    public var newWork = false
    public var summary = ""
    public var summaryThrough: String?
    public var draftRevision = 0
    public init(id: String = UUID().uuidString, title: String = "新对话") { self.id = id; self.title = title }
}
public enum MemoryKind: String, Codable, CaseIterable, Sendable { case preference = "偏好", fact = "事实", relationship = "联系", episodic = "工作经历" }
public enum MemoryScope: String, Codable, CaseIterable, Sendable { case global = "全局", contact = "联系人", session = "会话" }
public struct MemoryRevision: Codable, Sendable {
    public var content: String
    public var date: Date
    public var reason: String
    public init(content: String, date: Date, reason: String) { self.content = content; self.date = date; self.reason = reason }
}
public struct AgentMemory: Codable, Identifiable, Sendable {
    public var id: String = UUID().uuidString
    public var content: String
    public var kind: MemoryKind
    public var scope: MemoryScope
    public var scopeID: String?
    public var status = "active"
    public var confirmed = false
    public var confidence: Double = 1
    public var importance: Double = 0.7
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    public var expiresAt: Date?
    public var lastUsedAt: Date?
    public var useCount = 0
    public var source = "用户说明"
    public var sourceChatID: String?
    public var sourceSessionID: String?
    public var sourceMailIDs: [String] = []
    public var evidence = ""
    public var topicKey = ""
    public var supersededBy: String?
    public var revisions: [MemoryRevision] = []
    public var embedding: [Float]?
    public var embeddingModel: String?
    public init(content: String, kind: MemoryKind = .fact, scope: MemoryScope = .global, scopeID: String? = nil) { self.content = content; self.kind = kind; self.scope = scope; self.scopeID = scopeID }
    public func eligible(sessionID: String?, contactEmail: String?, now: Date = Date()) -> Bool {
        guard status == "active", expiresAt.map({ $0 > now }) ?? true else { return false }
        switch scope { case .global: return true; case .session: return scopeID == sessionID; case .contact: return scopeID?.lowercased() == contactEmail?.lowercased() }
    }
}
public struct MemoryHit: Identifiable, Sendable {
    public var memory: AgentMemory
    public var score: Double
    public var method: String
    public var id: String { memory.id }
}
public enum MemoryRanking {
    public static func search(_ entries: [AgentMemory], query: String, vector: [Float]? = nil, sessionID: String?, contactEmail: String?, now: Date = Date(), limit: Int = 8) -> [MemoryHit] {
        let terms = query.lowercased().split(whereSeparator: { $0.isWhitespace || "，。？！,:;".contains($0) }).map(String.init)
        return entries.filter { $0.eligible(sessionID: sessionID, contactEmail: contactEmail, now: now) }.compactMap { m in
            let text = m.content.lowercased()
            let lexical = terms.isEmpty ? 0 : Double(terms.filter { text.contains($0) }.count) / Double(terms.count)
            let semantic = cosine(vector, m.embedding)
            let scopeBoost = m.scope == .contact ? 0.30 : m.scope == .session ? 0.15 : 0
            let persistentPreference = m.kind == .preference && m.confirmed
            guard semantic > 0.25 || lexical > 0 || scopeBoost > 0 || persistentPreference || query.isEmpty else { return nil }
            let days = max(0, now.timeIntervalSince(m.updatedAt) / 86400)
            let score = max(0, semantic) * 0.55 + lexical * 0.25 + scopeBoost + m.importance * 0.10 + (m.confirmed ? 0.12 : 0) + 0.05 / (1 + days / 30)
            return MemoryHit(memory: m, score: score, method: semantic > 0 ? "语义与作用域" : "关键词与作用域")
        }.sorted { $0.score > $1.score }.prefix(limit).map { $0 }
    }
    private static func cosine(_ lhs: [Float]?, _ rhs: [Float]?) -> Double {
        guard let lhs, let rhs, lhs.count == rhs.count, !lhs.isEmpty, lhs.allSatisfy(\.isFinite), rhs.allSatisfy(\.isFinite) else { return 0 }
        var dot: Double = 0, a: Double = 0, b: Double = 0
        for (x,y) in zip(lhs,rhs) { dot += Double(x*y); a += Double(x*x); b += Double(y*y) }
        return a > 0 && b > 0 ? dot / sqrt(a*b) : 0
    }
}
public struct WorkspacePreferences: Codable, Sendable {
    public var density = "comfortable"
    public var memoryEnabled = true
    public var autoMemory = true
    public var activeSessionID: String?
    public init() {}
}
public struct AccountSyncState: Codable, Sendable {
    public var accountID: String
    public var lastSyncAt: Date?
    public var error: String?
    public var syncing = false
    public init(accountID: String) { self.accountID = accountID }
}
