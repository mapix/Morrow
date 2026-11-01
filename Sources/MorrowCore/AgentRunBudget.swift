import Foundation

public struct AgentRunBudget: Codable, Sendable {
    public var modelTurns = 128
    public var toolCalls = 1024
    public var seconds = 3600
    public init() {}
    public var bounded: Self {
        var value = self; value.modelTurns = min(512, max(16, modelTurns)); value.toolCalls = min(4096, max(64, toolCalls)); value.seconds = min(14400, max(300, seconds)); return value
    }
}
