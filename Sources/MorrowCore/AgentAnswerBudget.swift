import Foundation

/// A checkpoint for delivering an interactive answer, independent of the hard
/// execution allowance used by accepted, sustained work.
public enum AgentAnswerBudget {
    public static let modelTurns = 20
    public static let toolCalls = 48
    public static let seconds = 90
    public static let maximumBatchMails = 12
    public static let batchCharacters = 24000
}
