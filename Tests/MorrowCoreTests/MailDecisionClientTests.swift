import Foundation
import XCTest
@testable import MorrowCore

private final class DecisionHTTPFixture: URLProtocol {
    static let lock = NSLock()
    static var body = Data()
    static var status = 200
    static var captured: URLRequest?
    static var capturedBody = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var input = request.httpBody ?? Data()
        if input.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; input.append(contentsOf: buffer.prefix(count)) }
        }
        Self.lock.lock(); Self.captured = request; Self.capturedBody = input; let data = Self.body, code = Self.status; Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": String(data.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static func capture() -> (URLRequest?, Data) { lock.lock(); defer { lock.unlock() }; return (captured, capturedBody) }
}

final class MailDecisionClientTests: XCTestCase {
    private func client(body: String, status: Int = 200) -> OllamaMailDecisionClient {
        DecisionHTTPFixture.lock.lock(); DecisionHTTPFixture.body = Data(body.utf8); DecisionHTTPFixture.status = status; DecisionHTTPFixture.captured = nil; DecisionHTTPFixture.lock.unlock()
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [DecisionHTTPFixture.self]
        return OllamaMailDecisionClient(configuration: configuration)
    }
    private var candidate: MailDecisionCandidate {
        var mail = MailMessage(accountID: "fixture", from: .init(email: "sender@example.invalid"), subject: "contract", text: "body opening should not replace matched evidence"); mail.raw = Data("private MIME bytes".utf8)
        return .init(query: "acceptance deadline", hit: .init(message: mail, score: 0.8, method: "semantic", snippet: "Buyer has seven business days to inspect delivery."))
    }
    func testNativeSystemOneNoulRequestUsesOnlyBoundedEvidenceAndDefaultNimble() async throws {
        let value = try await client(body: "{\"model\":\"nimble\",\"answers\":{\"relevance\":{\"type\":\"noul\",\"noul\":0.96}}}").relevance(candidate, settings: .init())
        XCTAssertEqual(value, 0.96)
        let (request, input) = DecisionHTTPFixture.capture()
        XCTAssertEqual(request?.url?.path, "/v1/systemone"); XCTAssertEqual(request?.httpMethod, "POST")
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: input) as? [String: Any])
        XCTAssertEqual(payload["model"] as? String, "nimble"); XCTAssertEqual(payload["keep_alive"] as? String, "1m")
        let state = try XCTUnwrap(payload["state"] as? [String: Any]), mail = try XCTUnwrap(state["mail"] as? [String: Any])
        XCTAssertEqual(mail["passage"] as? String, candidate.passage); XCTAssertNil(mail["raw"]); XCTAssertNil(mail["html"])
        XCTAssertFalse(String(decoding: input, as: UTF8.self).contains("private MIME bytes")); XCTAssertLessThan(input.count, 32768)
        let question = try XCTUnwrap((payload["questions"] as? [String: [String: Any]])?["relevance"])
        XCTAssertEqual(question["type"] as? String, "noul"); XCTAssertNotNil(question["criteria"])
    }
    func testUnsupportedModelAndWrongAnswerSchemaAreFailures() async throws {
        for (body, code) in [("{\"error\":\"synthetic model not installed\"}",400), ("{\"answers\":{\"foreign\":{\"type\":\"noul\",\"noul\":0.9}}}",200), ("{\"answers\":{\"relevance\":{\"type\":\"choice\",\"noul\":0.9}}}",200)] {
            do { _ = try await client(body: body, status: code).relevance(candidate, settings: .init()); XCTFail("Invalid answer must be rejected") } catch { XCTAssertFalse(error is CancellationError) }
        }
    }
    func testMetadataOnlyFiltersDoNotUseDecisionInference() async throws {
        let mail = MailMessage(accountID: "fixture", from: .init(email: "sender@example.invalid"), subject: "mail", text: "fixture")
        let result = try await MailDecisionReranker(client: client(body: "invalid")).rank(query: "is:unread after:2026-01-01", hits: [.init(message: mail, score: 1, method: "conditions")], settings: .init())
        XCTAssertEqual(result.hits.count,1); XCTAssertNotNil(result.skippedReason); XCTAssertNil(result.failure)
    }
    func testDisabledInvalidServiceCanBeSavedWithoutRequiringAConnection() throws {
        var config=RetrievalDecisionSettings();config.enabled=false;config.baseURL="unfinished address";config.model=""
        XCTAssertNoThrow(try config.validated())
    }
}
