import XCTest
@testable import MorrowCore
final class ModelEndpointTests: XCTestCase {
    func testCompatibleAPIUsesConfiguredBaseModelAndJSONSchema() async throws {
        guard let port = ProcessInfo.processInfo.environment["MORROW_MODEL_TEST_PORT"] else { throw XCTSkip("Start isolated model-api-fixture") }
        var settings = AgentSettings(); settings.provider = "openai"; settings.openAIURL = "http://127.0.0.1:" + port + "/v1"; settings.openAIModel = "fixture-model"; settings.strictJSON = true
        let engine = AIEngine(); let models = try await engine.configuredModels(settings:settings, apiKey:"fixture-ephemeral"); XCTAssertEqual(models,["fixture-model"])
        let schema = Data(#"{"type":"object","properties":{"text":{"type":"string"}},"required":["text"],"additionalProperties":false}"#.utf8)
        let result = try await engine.complete(system:"只返回JSON",prompt:"测试",settings:settings,json:true,schema:schema,maxTokens:64,apiKey:"fixture-ephemeral")
        XCTAssertEqual(result.text,"连接成功")
    }
}
