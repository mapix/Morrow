import Foundation
import MorrowCore

extension AppModel {
    func rankChatMailCandidates(_ query: String, hits: [SearchHit]) async throws -> MailDecisionRanking {
        let config = settings.retrievalDecision ?? RetrievalDecisionSettings()
        return try await mailDecisionReranker.rank(query: query, hits: hits, settings: config) { [weak self] completed, count in
            await self?.updateDecisionProgress(completed, count: count, model: config.model)
        }
    }
    private func updateDecisionProgress(_ completed: Int, count: Int, model: String) {
        sidebarToolStatus = L10n.format("决策复核 {0}/{1} · {2}", "\(completed)", "\(count)", model)
    }
}
