import XCTest
@testable import MorrowCore

private final class MediaHTTPFixture: URLProtocol {
    static var body = Data(), status = 200, requests: [(URLRequest, Data)] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var input = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096)
            while true { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; input.append(contentsOf: buffer.prefix(count)) }
        }
        Self.requests.append((request, input))
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: ["x-litellm-response-cost": "0.02"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
final class GatewayMediaTests: XCTestCase {
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aXioAAAAASUVORK5CYII=")!
    private func client(body: Data, status: Int = 200) throws -> GatewayMediaClient {
        MediaHTTPFixture.body = body; MediaHTTPFixture.status = status; MediaHTTPFixture.requests = []
        let network = URLSessionConfiguration.ephemeral; network.protocolClasses = [MediaHTTPFixture.self]
        return GatewayMediaClient(configuration: try GatewayMediaConfiguration.load(), apiKey: "synthetic-test-key", network: network)
    }
    func testAllowlistDistinguishesGenerationAndUnderstanding() throws {
        let config = try GatewayMediaConfiguration.load()
        XCTAssertEqual(config.defaultImageModel, "gpt-image-2.5-flare")
        XCTAssertNoThrow(try config.require("gemini-omni-flash", capability: "video_understanding"))
        XCTAssertThrowsError(try config.require("gemini-omni-flash", capability: "video_generation"))
        XCTAssertThrowsError(try config.require("sora-2", capability: "video_generation"))
        XCTAssertThrowsError(try config.require("invented-model", capability: "image_generation"))
    }
    func testImageRequestSingleOutputCostAndImageValidation() async throws {
        let body = try JSONSerialization.data(withJSONObject: ["data": [["b64_json": png.base64EncodedString()]]])
        let output = try await client(body: body).generateImage(model: "gpt-image-2.5-flare", prompt: "synthetic", quality: "low", idempotencyKey: "request-1")
        XCTAssertEqual(output.mimeType, "image/png"); XCTAssertEqual(output.costUSD, 0.02)
        let (request, data) = try XCTUnwrap(MediaHTTPFixture.requests.first)
        XCTAssertEqual(request.url?.path, "/v1/images/generations"); XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), "request-1")
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(payload["n"] as? Int, 1); XCTAssertEqual(payload["quality"] as? String, "low")
        let malformed = try client(body: body)
        do { _ = try await malformed.generateImage(model: "gpt-image-2.5-flare", prompt: "synthetic", images: [Data("bad".utf8)], idempotencyKey: "bad"); XCTFail() } catch {}
        XCTAssertTrue(MediaHTTPFixture.requests.isEmpty)
    }
    func testVideoMultipartStatusContentAndUnderstandingContract() async throws {
        let c = try client(body: Data(#"{"id":"video_test-1","status":"queued"}"#.utf8))
        let job = try await c.createVideo(model: "veo-3.1-fast-generate-preview", prompt: "synthetic", reference: png, idempotencyKey: "video-once")
        XCTAssertEqual(job.object["id"]?.text, "video_test-1"); XCTAssertEqual(job.object["costUSD"]?.text, "0.02")
        let (request, data) = try XCTUnwrap(MediaHTTPFixture.requests.first), form = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(request.url?.path, "/v1/videos")
        XCTAssertTrue(form.contains("name=\"seconds\"\r\n\r\n4")); XCTAssertTrue(form.contains("Content-Type: image/png"))
        _ = try await c.videoStatus("video_test-1")
        XCTAssertEqual(MediaHTTPFixture.requests.last?.0.url?.path, "/v1/videos/video_test-1")
        _ = try await c.videoStatus("video_encoded==")
        XCTAssertEqual(MediaHTTPFixture.requests.last?.0.url?.path, "/v1/videos/video_encoded==")
        MediaHTTPFixture.body = Data([0, 0, 0, 20]) + Data("ftypisom00000".utf8)
        _ = try await c.videoContent("video_test-1")
        XCTAssertEqual(MediaHTTPFixture.requests.last?.0.url?.path, "/v1/videos/video_test-1/content")
        MediaHTTPFixture.body = Data(#"{"status":"completed","steps":[{"type":"model_output","content":[{"type":"text","text":"a blue square"}]}]}"#.utf8)
        let result = try await c.analyzeVideo(model: "gemini-omni-flash", prompt: "describe", data: Data([1,2]))
        XCTAssertEqual(result.text, "a blue square")
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: MediaHTTPFixture.requests.last!.1) as? [String: Any])
        let steps = payload["input"] as! [[String: Any]], parts = steps[0]["content"] as! [[String: Any]]
        XCTAssertEqual(MediaHTTPFixture.requests.last?.0.url?.path, "/v1beta/interactions")
        XCTAssertEqual(MediaHTTPFixture.requests.last?.0.value(forHTTPHeaderField: "Api-Revision"), "2026-05-20")
        XCTAssertEqual(payload["store"] as? Bool, false)
        XCTAssertEqual(parts[1]["type"] as? String, "video")
        XCTAssertEqual(parts[1]["data"] as? String, "AQI=")
        XCTAssertEqual(parts[1]["mime_type"] as? String, "video/mp4")
    }
    func testErrorsRedactCredentialAndDoNotRetry() async throws {
        let c = try client(body: Data(#"{"error":{"message":"synthetic-test-key upstream failed"}}"#.utf8), status: 503)
        do { _ = try await c.generateImage(model: "gpt-image-2.5-flare", prompt: "synthetic", idempotencyKey: "once"); XCTFail() }
        catch { XCTAssertFalse(error.localizedDescription.contains("synthetic-test-key")) }
        XCTAssertEqual(MediaHTTPFixture.requests.count, 1)
    }
}
