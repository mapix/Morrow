import Foundation

public enum AgentPhase: String, Codable, CaseIterable, Sendable {
    case queued, reading, working, waitingUser, waitingReply, monitoring, completed, failed, paused
    public var label: String { switch self { case .queued: return "已接下"; case .reading: return "正在取证"; case .working: return "正在推进"; case .waitingUser: return "等你决定"; case .waitingReply: return "等待回复"; case .monitoring: return "持续关注"; case .completed: return "已完成"; case .failed: return "需要处理"; case .paused: return "已暂停" } }
}
public enum AgentStepState: String, Codable, Sendable { case pending, active, completed, failed }
public struct AgentStep: Codable, Identifiable, Sendable {
    public var id: String = UUID().uuidString
    public var title: String
    public var tool: String
    public var detail: String
    public var state: AgentStepState
    public var date: Date
    public var sourceMailIDs: [String]
    public init(title: String, tool: String, detail: String = "", state: AgentStepState = .pending, date: Date = Date(), sourceMailIDs: [String] = []) { self.title = title; self.tool = tool; self.detail = detail; self.state = state; self.date = date; self.sourceMailIDs = sourceMailIDs }
}
public struct AgentRun: Codable, Identifiable, Sendable {
    public var id: String = UUID().uuidString
    public var delegationID: String?
    public var responderID: String?
    public var title: String
    public var instruction: String
    public var phase: AgentPhase
    public var summary: String
    public var steps: [AgentStep]
    public var sourceMailIDs: [String]
    public var artifactIDs: [String]
    public var updatedAt: Date
    public var isDemo: Bool
    public var agreement: WorkAgreement?
    public init(title: String, instruction: String, phase: AgentPhase = .queued, summary: String = "", steps: [AgentStep] = [], sourceMailIDs: [String] = [], isDemo: Bool = false) {
        self.title = title; self.instruction = instruction; self.phase = phase; self.summary = summary; self.steps = steps; self.sourceMailIDs = sourceMailIDs; self.artifactIDs = []; self.updatedAt = Date(); self.isDemo = isDemo
    }
}
public enum AgentArtifactKind: String, Codable, Sendable { case draft, report, brief, action }
public struct ArtifactRevision: Codable, Identifiable, Sendable {
    public var id: String = UUID().uuidString
    public var content: String
    public var sourceMailIDs: [String]
    public var createdAt: Date
    public init(content: String, sourceMailIDs: [String], createdAt: Date) { self.content = content; self.sourceMailIDs = sourceMailIDs; self.createdAt = createdAt }
}
public struct AgentArtifact: Codable, Identifiable, Sendable {
    public var id: String = UUID().uuidString
    public var runID: String
    public var title: String
    public var kind: AgentArtifactKind
    public var content: String
    public var sourceMailIDs: [String]
    public var linkedDraftID: String?
    public var createdAt: Date = Date()
    public var revisions: [ArtifactRevision]?
    public var updatedAt: Date?
    public init(runID: String, title: String, kind: AgentArtifactKind, content: String, sourceMailIDs: [String] = [], linkedDraftID: String? = nil) { self.runID = runID; self.title = title; self.kind = kind; self.content = content; self.sourceMailIDs = sourceMailIDs; self.linkedDraftID = linkedDraftID }
}
public struct AgentDecision: Codable, Identifiable, Sendable {
    public var id: String = UUID().uuidString
    public var runID: String
    public var title: String
    public var detail: String
    public var artifactID: String?
    public var state: String = "pending"
    public var answer: String?
    public var createdAt: Date = Date()
    public var kind: String?
    public var delegationID: String?
    public init(runID: String, title: String, detail: String, artifactID: String? = nil) { self.runID = runID; self.title = title; self.detail = detail; self.artifactID = artifactID }
}
