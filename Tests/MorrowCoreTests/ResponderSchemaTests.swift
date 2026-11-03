import XCTest
@testable import MorrowCore

final class ResponderSchemaTests: XCTestCase {
    private func engine() -> PartnerEngine {
        let network = URLSessionConfiguration.ephemeral; network.protocolClasses = [StrictResponderProvider.self]
        return PartnerEngine(ai: AIEngine(httpConfiguration: network))
    }
    private func settings() -> AgentSettings {
        var value = AgentSettings(); value.provider = "openai"; value.openAIURL = "https://strict-responder-fixture.invalid/v1"; value.openAIModel = "fixture"; return value
    }
    func testPlanningRequestPassesStrictProviderSchemaValidationAndNullableFieldsDecode() async throws {
        var rule = MailResponder(); rule.response = "Draft a short reply to the synthetic description."
        var mail = MailMessage(accountID: "synthetic-account", from: .init(email: "source@example.invalid"), subject: "Synthetic test", text: "A blue circle on white."); mail.id = "synthetic-source"
        let result = try await engine().responderPlan(rule: rule, mail: mail, history: [PartnerChat(role: "tool", text: "Read the synthetic description.")], settings: settings(), fixedBody: nil)
        XCTAssertEqual(result.answer, "Strict schema accepted")
        XCTAssertEqual(result.operations?.first?.type, "draft")
        XCTAssertNil(result.operations?.first?.accountID); XCTAssertNil(result.operations?.first?.recipient)
    }
    func testVerificationRequestPassesStrictProviderSchemaValidation() async throws {
        var rule = MailResponder(); rule.response = "Reply using the synthetic evidence."
        let result = try await engine().verifyResponder(body: "Thank you for the description.", rule: rule, history: [PartnerChat(role: "tool", text: "Read the description.")], settings: settings())
        XCTAssertTrue(result.approved)
    }
    func testSharedPlanningAndWorkSchemasAndResponsesEnvelopePassSameContract() throws {
        for schema in [PartnerPlanProtocol.schema, WorkAgreement.schema] {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: schema) as? [String: Any])
            XCTAssertNil(StrictResponderProvider.schemaError(object))
            let request = try ChatGPTPlanClient.payload(model: "fixture", system: "Synthetic task", prompt: "Synthetic description", json: true, schema: schema, images: [])
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request) as? [String: Any])
            let format = try XCTUnwrap((body["text"] as? [String: Any])?["format"] as? [String: Any])
            XCTAssertEqual(format["strict"] as? Bool, true)
            XCTAssertNil(StrictResponderProvider.schemaError(try XCTUnwrap(format["schema"] as? [String: Any])))
        }
    }
}

private final class StrictResponderProvider: URLProtocol, @unchecked Sendable {
    static func schemaError(_ schema: [String: Any], path: String = "$schema") -> String? {
        if let properties = schema["properties"] as? [String: Any] {
            guard let required = schema["required"] as? [String], Set(required) == Set(properties.keys), schema["additionalProperties"] as? Bool == false else { return "Invalid strict object schema at " + path + ": required must include every property" }
            for (key, value) in properties { if let child = value as? [String: Any], let error = schemaError(child, path: path + ".properties." + key) { return error } }
        }
        if let items = schema["items"] as? [String: Any], let error = schemaError(items, path: path + ".items") { return error }
        for key in ["anyOf", "oneOf", "allOf"] {
            for (index, child) in (schema[key] as? [[String: Any]] ?? []).enumerated() { if let error = schemaError(child, path: path + "." + key + "[\(index)]") { return error } }
        }
        return nil
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "strict-responder-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var bytes = request.httpBody ?? Data()
        if bytes.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096)
            while true { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; bytes.append(contentsOf: buffer.prefix(n)) }
        }
        let body = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] ?? [:]
        let messages = body["messages"] as? [[String: Any]] ?? [], system = messages.first?["content"] as? String ?? ""
        let name = system.contains("执行用户已设定的邮件响应器") ? "plan" : "verify"
        if let folder = ProcessInfo.processInfo.environment["MORROW_SCHEMA_PAYLOAD_EXPORT"] {
            let directory = URL(fileURLWithPath: folder); try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? bytes.write(to: directory.appendingPathComponent(name + ".json"), options: .atomic)
        }
        let format = (body["response_format"] as? [String: Any])?["json_schema"] as? [String: Any] ?? [:]
        let error = (format["schema"] as? [String: Any]).flatMap { Self.schemaError($0) } ?? (format["schema"] == nil ? "Missing strict schema" : nil)
        let output: [String: Any]; let status: Int
        if let error { status = 400; output = ["error": ["message": error, "type": "invalid_request_error", "code": "invalid_json_schema"]] }
        else {
            status = 200
            let reply: [String: Any] = name == "plan" ? ["answer": "Strict schema accepted", "messageIDs": ["synthetic-source"], "operations": [["type": "draft", "messageID": "synthetic-source", "text": "Thank you for the description.", "recipient": NSNull(), "accountID": NSNull()]]] : ["approved": true, "issues": []]
            let content = String(decoding: try! JSONSerialization.data(withJSONObject: reply), as: UTF8.self)
            output = ["choices": [["message": ["content": content]]]]
        }
        let data = try! JSONSerialization.data(withJSONObject: output)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
