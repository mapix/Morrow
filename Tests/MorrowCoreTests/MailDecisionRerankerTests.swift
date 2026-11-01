import XCTest
@testable import MorrowCore

private actor DecisionFixture: MailDecisionEvaluating {
    var requests = 0
    let probabilities: [String: Double]
    let failAt: Int?
    init(_ probabilities: [String: Double], failAt: Int? = nil) { self.probabilities = probabilities; self.failAt = failAt }
    func relevance(_ candidate: MailDecisionCandidate, settings: RetrievalDecisionSettings) async throws -> Double {
        requests += 1
        if requests == failAt { throw MailError.message("synthetic decision failure") }
        return probabilities[candidate.subject] ?? 0.5
    }
}

final class MailDecisionRerankerTests: XCTestCase {
    private func hit(_ id: String, score: Float) -> SearchHit {
        var mail = MailMessage(accountID: "fixture", from: .init(email: "source@example.invalid"), subject: id, text: "full original text"); mail.id = id
        return .init(message: mail, score: score, method: "语义（EmbeddingGemma 2）", snippet: "retrieved passage")
    }
    func testRerankingCorrectsEmbeddingOrderAndFiltersOnlyConfidentIrrelevance() async throws {
        let fixture = DecisionFixture(["newsletter":0.01,"uncertain":0.5,"answer":0.97])
        let ranker = MailDecisionReranker(client: fixture)
        let input = [hit("newsletter",score:0.99),hit("uncertain",score:0.8),hit("answer",score:0.7)]
        let result = try await ranker.rank(query: "requested facts", hits: input, settings: .init())
        XCTAssertEqual(result.hits.map(\.id), ["answer","uncertain"])
        XCTAssertEqual(result.hits.first?.score,0.7); XCTAssertEqual(result.hits.first?.snippet,"retrieved passage")
        XCTAssertEqual(result.hits.first?.decisionRelevance,0.97); XCTAssertEqual(result.filtered,1)
        XCTAssertEqual(result.source,"nimble"); XCTAssertNil(result.failure)
        XCTAssertEqual(result.hits.first?.message.text,"full original text")
    }
    func testSortOnlyKeepsAllAndTiesPreserveEmbeddingOrder() async throws {
        let ranker = MailDecisionReranker(client: DecisionFixture(["a":0.5,"b":0.5,"c":0.01]))
        var settings=RetrievalDecisionSettings();settings.filterIrrelevant=false
        let result=try await ranker.rank(query:"query",hits:[hit("a",score:0.9),hit("b",score:0.8),hit("c",score:0.7)],settings:settings)
        XCTAssertEqual(result.hits.map(\.id),["a","b","c"]);XCTAssertEqual(result.filtered,0)
    }
    func testPartialFailureReturnsAllOriginalCandidatesAndFailureIsCached() async throws {
        let fixture=DecisionFixture(["a":0.01],failAt:2)
        let actual=MailDecisionReranker(client:fixture),input=[hit("a",score:0.9),hit("b",score:0.8)]
        let first=try await actual.rank(query:"query",hits:input,settings:.init())
        XCTAssertEqual(first.hits.map(\.id),input.map(\.id));XCTAssertTrue(first.hits.allSatisfy { $0.decisionRelevance == nil })
        XCTAssertNotNil(first.failure);XCTAssertNil(first.source);XCTAssertEqual(first.filtered,0)
        _=try await actual.rank(query:"query",hits:input,settings:.init());let calls=await fixture.requests;XCTAssertEqual(calls,2)
    }
    func testCacheIncludesPassageAndModelAndReappliesFilterPolicy() async throws {
        let fixture=DecisionFixture(["a":0.05]),ranker=MailDecisionReranker(client:fixture);let input=[hit("a",score:0.9)]
        _=try await ranker.rank(query:"query",hits:input,settings:.init());var settings=RetrievalDecisionSettings();settings.filterIrrelevant=false
        let visible=try await ranker.rank(query:"query",hits:input,settings:settings);XCTAssertEqual(visible.hits.count,1)
        var calls=await fixture.requests;XCTAssertEqual(calls,1)
        var changed=input;changed[0].snippet="changed passage";_=try await ranker.rank(query:"query",hits:changed,settings:settings)
        settings.model="fixture-alternate";_=try await ranker.rank(query:"query",hits:changed,settings:settings)
        calls=await fixture.requests;XCTAssertEqual(calls,3)
    }
    func testDisabledAndOversizedInputsNeverInvokeModel() async throws {
        let fixture=DecisionFixture([:]),ranker=MailDecisionReranker(client:fixture);var settings=RetrievalDecisionSettings();settings.enabled=false
        let input=[hit("a",score:0.9)];let disabled=try await ranker.rank(query:"query",hits:input,settings:settings);XCTAssertEqual(disabled.hits.count,1)
        settings.enabled=true;let capped=try await ranker.rank(query:"query",hits:Array(repeating:input[0],count:41),settings:settings);XCTAssertNotNil(capped.failure)
        let calls=await fixture.requests;XCTAssertEqual(calls,0)
    }
    func testInvalidProbabilityIsNotAllowedToFilterMail() async throws {
        let ranker=MailDecisionReranker(client:DecisionFixture(["a":Double.nan]))
        let result=try await ranker.rank(query:"query",hits:[hit("a",score:0.8)],settings:.init())
        XCTAssertEqual(result.hits.count,1);XCTAssertNotNil(result.failure)
    }
    func testCandidateBoundsUseMatchedPassageRatherThanBodyOpening() {
        var value=hit("a",score:1);value.snippet=String(repeating:"合同",count:2000)
        let candidate=MailDecisionCandidate(query:"交付确认",hit:value)
        XCTAssertEqual(candidate.passage.count,1600);XCTAssertFalse(candidate.passage.contains("full original"))
    }
    func testOlderAgentSettingsDecodeAndDefaultToLocalNimble() throws {
        let json=try JSONEncoder().encode(AgentSettings());let decoded=try JSONDecoder().decode(AgentSettings.self,from:json)
        XCTAssertNil(decoded.retrievalDecision);let config=decoded.retrievalDecision ?? RetrievalDecisionSettings()
        XCTAssertTrue(config.enabled);XCTAssertEqual(config.baseURL,"http://127.0.0.1:11434");XCTAssertEqual(config.model,"nimble")
        let partial=try JSONDecoder().decode(RetrievalDecisionSettings.self,from:Data("{\"model\":\"nimble\"}".utf8));XCTAssertTrue(partial.enabled)
    }
}
