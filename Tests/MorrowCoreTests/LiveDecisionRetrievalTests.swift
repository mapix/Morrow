import XCTest
import MLX
@testable import MorrowCore

final class LiveDecisionRetrievalTests: XCTestCase {
    func testActualEmbeddingThenNimbleFiltersKeywordDecoys() async throws {
        guard ProcessInfo.processInfo.environment["MORROW_LIVE_DECISION"] == "1" else { throw XCTSkip("Set MORROW_LIVE_DECISION=1 for bundled EmbeddingGemma 2 and local Ollama nimble") }
        GPU.metallib = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MORROW_TEST_METALLIB"] ?? FileManager.default.currentDirectoryPath + "/.build/morrow-metal/mlx.metallib")
        let path = ProcessInfo.processInfo.environment["MORROW_EMBEDDING_DIR"] ?? "/Applications/Morrow.app/Contents/Resources/embeddinggemma-2"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("decision-live-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MailStore(root: root), index = EmbeddingIndex()
        try await index.load(directory: path)
        var answer = MailMessage(accountID: "fixture", from: .init(email: "supplier@example.invalid"), subject: "交付协议条款", text: "双方约定：设备交付后，买方应在七个工作日内检验数量、性能和质量。达到约定标准后签字确认，瑕疵应书面通知供货方。"); answer.id = "actual-answer"
        var ad = MailMessage(accountID: "fixture", from: .init(email: "newsletter@example.invalid"), subject: "学习验收与交付：课程广告", text: "报名课程可以学习验收、交付、买方和检验期限等概念。本广告不提供任何实际合同的检查期限或双方约定。"); ad.id = "keyword-decoy"
        var other = MailMessage(accountID: "fixture", from: .init(email: "events@example.invalid"), subject: "周末徒步", text: "周六上午九点在公园集合，带水和帽子。"); other.id = "unrelated"
        let candidateCount = min(40, max(3, Int(ProcessInfo.processInfo.environment["MORROW_LIVE_DECISION_CANDIDATES"] ?? "3") ?? 3))
        var candidates = [answer, ad, other]
        for i in 3..<candidateCount {
            var decoy = ad; decoy.id = "keyword-decoy-\(i)"
            decoy.text += " 第\(i)期课程通讯，仅为宣传。"
            candidates.append(decoy)
        }
        for mail in candidates { let saved = try await store.upsert(mail); _ = try await index.index(saved, store: store, attachments: false) }
        let query = "客户收货后多久需要检查是否达标并确认接收，具体约定在哪里？"
        let hits = try await index.search(query, store: store, allowedIDs: Set(candidates.map(\.id)), strategy: .semantic, limit: 40)
        XCTAssertEqual(hits.count, candidateCount)
        XCTAssertTrue(hits.contains { $0.id == answer.id })
        let ranking = try await MailDecisionReranker().rank(query: query, hits: hits, settings: .init())
        XCTAssertNil(ranking.failure); XCTAssertEqual(ranking.source,"nimble"); XCTAssertEqual(ranking.hits.first?.id,answer.id)
        XCTAssertFalse(ranking.hits.contains { $0.id == ad.id }); XCTAssertTrue(ranking.hits.allSatisfy { $0.decisionRelevance != nil })
        print("LIVE_EMBEDDING_NIMBLE: recalled=\(hits.count); retained=\(ranking.hits.count); filtered=\(ranking.filtered); scores=" + ranking.hits.map { "\($0.id):\($0.decisionRelevance!)" }.joined(separator:","))
    }
}
