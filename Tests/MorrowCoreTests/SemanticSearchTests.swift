import XCTest
import MLX
@testable import MorrowCore

final class SemanticSearchTests: XCTestCase {
    private func makeMail(_ id: String, subject: String, body: String, account: String = "a") -> MailMessage {
        var mail = MailMessage(accountID: account, from: .init(name: "合作方", email: "source@example.com"), subject: subject, text: body)
        mail.id = id; mail.messageID = "<\(id)@example.com>"
        return mail
    }
    func testKeywordModeDoesNotNeedModelAndMissingModelIsExplicitForSemantic() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MailStore(root: root), index = EmbeddingIndex()
        let mail = makeMail("contract", subject: "合同", body: "验收条款")
        try await store.upsert(mail)
        let keyword = try await index.search("合同", store: store, strategy: .keyword)
        XCTAssertEqual(keyword.map(\.id), [mail.id]); XCTAssertEqual(keyword.first?.method, "关键词")
        do { _ = try await index.search("合同", store: store, strategy: .semantic); XCTFail("Semantic mode must not silently use keywords") }
        catch { XCTAssertTrue(error.localizedDescription.contains("未执行语义检索")) }
        let coverage = try await index.searchCoverage(store: store)
        XCTAssertEqual(coverage.eligibleCount, 1); XCTAssertEqual(coverage.indexedCount, 0)
        XCTAssertFalse(coverage.isLoaded); XCTAssertFalse(coverage.isComplete)
    }
    func testCoverageCountsCurrentIdentityDimensionAndAllowedScopeOnly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MailStore(root: root)
        let current = makeMail("current", subject: "协议", body: "验收")
        var copy = current; copy.id = "copy"; copy.folder = "Archive"
        let old = makeMail("old", subject: "协议", body: "旧索引")
        let wrongSize = makeMail("wrong-size", subject: "协议", body: "维度错误")
        let excluded = makeMail("excluded", subject: "协议", body: "另一邮箱", account: "b")
        for mail in [current, copy, old, wrongSize, excluded] { try await store.upsert(mail) }
        let fixtureVector = Array(repeating: Float(0), count: 768)
        try await store.putVectors(messageID: current.id, chunks: ["fixture"], vectors: [fixtureVector], model: EmbeddingIndex.checkpoint, hash: "fixture")
        _ = try await store.reuseVectors(canonical: current.canonicalID, targetID: copy.id, model: EmbeddingIndex.checkpoint, hash: "fixture")
        try await store.putVectors(messageID: old.id, chunks: ["fixture"], vectors: [fixtureVector], model: "old-model", hash: "fixture")
        try await store.putVectors(messageID: wrongSize.id, chunks: ["fixture"], vectors: [[1, 0]], model: EmbeddingIndex.checkpoint, hash: "fixture")
        try await store.putVectors(messageID: excluded.id, chunks: ["fixture"], vectors: [fixtureVector], model: EmbeddingIndex.checkpoint, hash: "fixture")
        let coverage = try await store.searchIndexCoverage(model: EmbeddingIndex.checkpoint, allowedIDs: [current.id, copy.id, old.id, wrongSize.id])
        XCTAssertEqual(coverage.eligibleCount, 3); XCTAssertEqual(coverage.indexedCount, 1)
        let noCurrent = try await store.searchIndexCoverage(model: EmbeddingIndex.checkpoint, allowedIDs: [old.id])
        XCTAssertEqual(noCurrent.eligibleCount, 1); XCTAssertEqual(noCurrent.indexedCount, 0)
    }
    func testVectorRankingDeduplicatesBeforeLimitAndSupportsExplicitThreshold() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MailStore(root: root)
        let first = makeMail("first", subject: "协议", body: "fixture")
        var copy = first; copy.id = "copy"; copy.folder = "Archive"
        let next = makeMail("next", subject: "检验", body: "fixture")
        let unrelated = makeMail("unrelated", subject: "徒步", body: "fixture")
        let excluded = makeMail("excluded", subject: "另一邮箱", body: "fixture", account: "b")
        for mail in [first, copy, next, unrelated, excluded] { try await store.upsert(mail) }
        for (mail, vector) in [(first, [Float(1), 0]), (copy, [Float(1), 0]), (next, [Float(0.8), 0.6]), (unrelated, [Float(0), 1]), (excluded, [Float(1), 0])] {
            try await store.putVectors(messageID: mail.id, chunks: [mail.subject], vectors: [vector], model: "fixture", hash: "fixture")
        }
        let hits = try await store.vectorSearch([1, 0], model: "fixture", limit: 2, allowedIDs: [first.id, copy.id, next.id, unrelated.id], minimumScore: 0.5)
        XCTAssertEqual(hits.map(\.id), [first.id, next.id])
        XCTAssertEqual(hits.first?.score, 1); XCTAssertTrue(hits.allSatisfy { $0.method == "语义（EmbeddingGemma 2）" })
    }
    func testHybridProvenanceNeverClaimsSemanticForKeywordOnlyResults() {
        let semanticMail = makeMail("semantic", subject: "检验标准", body: "")
        let keywordMail = makeMail("keyword", subject: "合同", body: "")
        let semantic = SearchHit(message: semanticMail, score: 0.8, method: "fixture", snippet: "语义片段")
        let keyword = SearchHit(message: keywordMail, score: 1, method: "关键词")
        let hits = EmbeddingIndex.fusedResults(semantic: [semantic], lexical: [keyword], limit: 10)
        XCTAssertEqual(hits.first { $0.id == keywordMail.id }?.method, "关键词")
        XCTAssertEqual(hits.first { $0.id == semanticMail.id }?.method, "语义（EmbeddingGemma 2）")
        let fallback = EmbeddingIndex.fusedResults(semantic: [], lexical: [keyword], limit: 10)
        XCTAssertEqual(fallback.first?.method, "关键词")
    }
    func testActualEmbeddingGemma2RetrievesAcceptanceWithoutLiteralQueryOverlap() async throws {
        guard ProcessInfo.processInfo.environment["MORROW_LIVE_SEMANTIC"] == "1" else { throw XCTSkip("Set MORROW_LIVE_SEMANTIC=1 for actual bundled EmbeddingGemma 2 weights") }
        let shader = ProcessInfo.processInfo.environment["MORROW_TEST_METALLIB"] ?? FileManager.default.currentDirectoryPath + "/.build/morrow-metal/mlx.metallib"
        GPU.metallib = URL(fileURLWithPath: shader)
        let model = ProcessInfo.processInfo.environment["MORROW_EMBEDDING_DIR"] ?? "/Applications/Morrow.app/Contents/Resources/embeddinggemma-2"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MailStore(root: root), index = EmbeddingIndex()
        try await index.load(directory: model)
        let contract = makeMail("acceptance", subject: "补充协议：交付检验规则", body: "设备交付后，客户有七个工作日检验数量、性能和质量，达到双方约定的标准后签字确认；出现瑕疵应书面通知供应方并安排整改。")
        let mails = [contract,
            makeMail("invoice", subject: "费用清单", body: "本月服务费一万二千元，请核对税号和银行账户。"),
            makeMail("meeting", subject: "部门会议", body: "星期三下午开周会，请提前准备产品销售数据。"),
            makeMail("hiking", subject: "周末活动", body: "周六在公园集合，带水和帽子，一起徒步。"),
            makeMail("login", subject: "登录确认", body: "验证码将在五分钟后失效，请尽快登录。")]
        for mail in mails { try await store.upsert(mail); _ = try await index.index(mail, store: store, attachments: false) }
        let coverage = try await index.searchCoverage(store: store)
        XCTAssertEqual(coverage.indexedCount, mails.count); XCTAssertTrue(coverage.isComplete)
        for query in ["买方拿到货以后，用多少时间检查是否达标并完成接收？", "Which agreement defines how the delivered product will be accepted and how long the customer has to inspect it?"] {
            let literal = try await index.search(query, store: store, strategy: .keyword)
            XCTAssertFalse(literal.contains { $0.id == contract.id }, "Target must not have literal query overlap")
            let hits = try await index.search(query, store: store, strategy: .semantic)
            XCTAssertEqual(hits.first?.id, contract.id)
            XCTAssertTrue(hits.allSatisfy { $0.method == "语义（EmbeddingGemma 2）" })
            print("ACTUAL_SEMANTIC_QUERY: \(query); literal_target=false; ranked=" + hits.map { "\($0.id):\($0.score)" }.joined(separator: ","))
        }
        let allowed = Set(mails.filter { $0.id != contract.id }.map(\.id))
        let excluded = try await index.search("交付检验", store: store, allowedIDs: allowed, strategy: .semantic)
        XCTAssertFalse(excluded.contains { $0.id == contract.id })
        let filtered = try await index.search("subject:规则 product acceptance criteria", store: store, strategy: .semantic, limit: 1)
        XCTAssertEqual(filtered.map(\.id), [contract.id])
        let obsoleteRoot = root.appendingPathComponent("obsolete-index")
        let obsoleteStore = try MailStore(root: obsoleteRoot)
        try await obsoleteStore.upsert(contract)
        var fixtureVector = Array(repeating: Float(0), count: 768); fixtureVector[0] = 1
        try await obsoleteStore.putVectors(messageID: contract.id, chunks: ["synthetic obsolete identity fixture"], vectors: [fixtureVector], model: "obsolete-model", hash: "fixture")
        do { _ = try await index.search("交付检验", store: obsoleteStore, strategy: .semantic); XCTFail("Obsolete model vectors cannot satisfy semantic search") }
        catch { XCTAssertTrue(error.localizedDescription.contains("尚无当前模型的有效向量索引")) }
        let fallback = try await index.search("交付检验", store: obsoleteStore, strategy: .hybrid)
        XCTAssertEqual(fallback.map(\.id), [contract.id]); XCTAssertEqual(fallback.first?.method, "关键词")
    }
}
