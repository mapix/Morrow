import XCTest
@testable import MorrowCore

final class AgentTraceTests: XCTestCase {
    private func event(_ string: String) throws -> OpenUIJSON { try JSONDecoder().decode(OpenUIJSON.self, from: Data(string.utf8)) }
    func testPlanAndActualExecutionStaySeparateAndTimingSurvivesStorage() throws {
        var trace = AgentExecutionTrace()
        trace.consume(try event(#"{"type":"plan","steps":[{"id":"search","title":"Find source mail","status":"in_progress"},{"id":"draft","title":"Prepare reply","status":"pending"}]}"#))
        trace.consume(try event(#"{"type":"phase","stage":"model","step":1,"startedAt":100000}"#))
        trace.consume(try event(#"{"type":"model_timing","step":1,"elapsedMs":3500,"queueMs":500,"requestMs":3000,"promptMs":1000,"generationMs":1800,"model":"fixture","outputTokens":30}"#))
        trace.consume(try event(#"{"type":"phase","stage":"tool_start","name":"search_mail","id":"call-1","startedAt":104000}"#))
        trace.consume(try event(#"{"type":"phase","stage":"tool_error","name":"search_mail","id":"call-1","elapsedMs":900}"#))
        XCTAssertEqual(trace.plan.last?.status, "pending")
        XCTAssertEqual(trace.tools.first?.status, "failed")
        XCTAssertEqual(trace.models.first?.queueSeconds, 0.5)
        XCTAssertEqual(trace.models.first?.generationSeconds, 1.8)
        var chat = PartnerChat(role: "partner", text: "Incomplete"); chat.executionTrace = trace
        let restored = try JSONDecoder().decode(PartnerChat.self, from: JSONEncoder().encode(chat))
        XCTAssertEqual(restored.executionTrace?.tools.first?.seconds, 0.9)
    }
    func testOllamaDurationMetadataIsRealProviderTiming() throws {
        var stream = AgentModelStream(compatible: false)
        _ = try stream.feed(#"{"message":{"content":"Done"},"done":true,"done_reason":"stop","prompt_eval_duration":500000000,"eval_duration":1200000000,"eval_count":20,"prompt_eval_count":30}"#)
        let result = try stream.result(model: "fixture")
        XCTAssertEqual(result.timing?.object["generationMs"], .number(1200))
        XCTAssertEqual(result.timing?.object["outputTokens"], .number(20))
    }
}
