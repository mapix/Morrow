import Foundation
import XCTest
@testable import MorrowCore

final class PartnerPlanTests: XCTestCase {
    private var valid: String { #"{"answer":"Searching","messageIDs":[],"operations":[{"type":"search","text":"after:2026-01-01 游戏变现"}],"openUI":null}"# }
    private func engine(_ replies: [(String, String?)], status: Int = 200, ollama: Bool = false) -> (PartnerEngine, AgentSettings) {
        PlanHTTPFixture.configure(replies: replies, status: status, ollama: ollama)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [PlanHTTPFixture.self]
        var settings = AgentSettings(); settings.provider = ollama ? "ollama" : "openai"; settings.openAIURL = "https://plan-fixture.invalid/v1"; settings.openAIModel = "fixture"
        return (PartnerEngine(ai: AIEngine(httpConfiguration: config)), settings)
    }
    private func plan(_ engine: PartnerEngine, _ settings: AgentSettings, mails: [MailMessage] = []) async throws -> PartnerPlan {
        try await engine.plan(instruction: "查找今年的游戏变现邮件", history: [], mails: mails, accounts: [], delegations: [], settings: settings)
    }
    func testStrictSchemaSeparatesOpenUIFromOperationsForBothTransports() async throws {
        for local in [false, true] {
            let (engine, settings) = engine([(valid, "stop")], ollama: local)
            let result = try await plan(engine, settings); XCTAssertEqual(result.operations?.first?.type, "search")
            let body = try XCTUnwrap(PlanHTTPFixture.requests.last)
            let schema: [String: Any]
            if local { schema = try XCTUnwrap(body["format"] as? [String: Any]); XCTAssertEqual(body["think"] as? Bool, false) }
            else {
                let format = try XCTUnwrap(body["response_format"] as? [String: Any]), wrapper = try XCTUnwrap(format["json_schema"] as? [String: Any])
                XCTAssertEqual(wrapper["strict"] as? Bool, true); schema = try XCTUnwrap(wrapper["schema"] as? [String: Any])
            }
            XCTAssertEqual(Set(schema["required"] as? [String] ?? []), ["answer", "messageIDs", "operations", "openUI"])
        }
    }
    func testMalformedMarkupGetsOneRepairBeforeAnyOperationIsReturned() async throws {
        let (engine, settings) = engine([("root = Steps(\"计划\", [\"搜索\"])", "stop"), (valid, "stop")])
        let result = try await plan(engine, settings); XCTAssertEqual(result.operations?.first?.type, "search")
        XCTAssertEqual(PlanHTTPFixture.requests.count, 2)
        let second = try XCTUnwrap(PlanHTTPFixture.requests.last)
        XCTAssertEqual(second["max_completion_tokens"] as? Int, 4500)
        let messages = try XCTUnwrap(second["messages"] as? [[String: Any]])
        XCTAssertTrue(messages.compactMap { $0["content"] as? String }.joined().contains("上一轮响应格式不完整"))
    }
    func testTruncatedPlanIsNotAcceptedEvenIfPartialJSONIsValid() async throws {
        let (engine, settings) = engine([(valid, "length"), (valid, "stop")])
        _ = try await plan(engine, settings); XCTAssertEqual(PlanHTTPFixture.requests.count, 2)
    }
    func testEmptyAndMissingOperationsAreRepaired() async throws {
        for bad in ["", #"{"answer":"Done","messageIDs":[]}"#] {
            let (engine, settings) = engine([(bad, "stop"), (valid, "stop")])
            _ = try await plan(engine, settings); XCTAssertEqual(PlanHTTPFixture.requests.count, 2)
        }
    }
    func testPersistentMalformedOutputStopsAfterTwoCallsWithModelSource() async throws {
        let (engine, settings) = engine([("not JSON", "stop"), ("not JSON", "stop")])
        do { _ = try await plan(engine, settings); XCTFail("Malformed output was accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("自动修复")); XCTAssertTrue(error.localizedDescription.contains("兼容服务 / fixture")) }
        XCTAssertEqual(PlanHTTPFixture.requests.count, 2)
    }
    func testUnknownTargetsAndServiceErrorsAreNotRepairedIntoPermissions() async throws {
        let foreign = #"{"answer":"Done","messageIDs":[],"operations":[{"type":"markRead","messageID":"foreign"}]}"#
        let (engine, settings) = engine([(foreign, "stop")])
        do { _ = try await plan(engine, settings); XCTFail("Foreign target was accepted") } catch { XCTAssertTrue(error.localizedDescription.contains("无法核验")) }
        XCTAssertEqual(PlanHTTPFixture.requests.count, 1)
        let (failed, config) = self.engine([("", nil)], status: 503)
        do { _ = try await plan(failed, config); XCTFail("Service failure was accepted") } catch {}
        XCTAssertEqual(PlanHTTPFixture.requests.count, 1)
    }
    func testCancelledPlanNeverStartsAnAutomaticRepair() async throws {
        let (engine, settings) = engine([("not JSON", "stop"), (valid, "stop")])
        let request = Task { try await plan(engine, settings) }; request.cancel()
        do { _ = try await request.value; XCTFail("Cancelled request succeeded") } catch is CancellationError {}
        XCTAssertEqual(PlanHTTPFixture.requests.count, 0)
    }
    func testThinkingIsNotExecutableAndObjectExtractionRespectsStrings() throws {
        let wrapped = "<think>{\"operations\":[{\"type\":\"trash\"}]}</think>\n```json\n" + valid + "\n```"
        let parsed = try PartnerPlanProtocol.decode(.init(text: wrapped, source: "fixture")); XCTAssertEqual(parsed.operations?.first?.type, "search")
        XCTAssertThrowsError(try PartnerPlanProtocol.decode(.init(text: valid + valid, source: "fixture")))
        XCTAssertThrowsError(try PartnerPlanProtocol.decode(.init(text: "", source: "fixture", reasoningOnly: true)))
        let quoted = #"{"answer":"literal } { and escaped \"quote\"","operations":[],"messageIDs":[]}"#
        XCTAssertEqual(try PartnerPlanProtocol.decode(.init(text: quoted, source: "fixture")).operations?.count, 0)
        let tags = #"{"answer":"quote <think>mail text</think>","operations":[],"messageIDs":[]}"#
        XCTAssertEqual(try PartnerPlanProtocol.decode(.init(text: tags, source: "fixture")).answer, "quote <think>mail text</think>")
    }
    func testLiveLocalPlannerProducesSearchBeforeAnalysis() async throws {
        guard ProcessInfo.processInfo.environment["MORROW_LIVE_PLANNER"] == "1" else { throw XCTSkip("Opt-in local model test with synthetic evidence") }
        PlanHTTPFixture.configure(live: true)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [PlanHTTPFixture.self]
        let engine = PartnerEngine(ai: AIEngine(httpConfiguration: config))
        var settings = AgentSettings(); settings.provider = "auto"; settings.model = "qwen3.8:27b-mlx"
        do {
            let plan = try await engine.plan(instruction: "分析一下我的邮件箱，找出所有今年以来收到的和游戏变现相关的邮件，全部整理出来。", history: [], mails: [], accounts: [], delegations: [], settings: settings)
            print("LOCAL_PLAN: operations=\(plan.operations?.map(\.type) ?? [])")
            XCTAssertTrue(plan.operations?.contains { $0.type == "search" } == true)
        } catch {
            print("LOCAL_PLAN_FAILURE: \(error.localizedDescription)")
            throw error
        }
    }
}

private final class PlanHTTPFixture: URLProtocol {
    private static let lock = NSLock()
    private static var live = false
    private static var replies: [(String, String?)] = []
    private static var status = 200
    private static var ollama = false
    private static var captured: [[String: Any]] = []
    private var forwardingTask: URLSessionDataTask?
    static var requests: [[String: Any]] { lock.withLock { captured } }
    static func configure(live: Bool = false, replies: [(String, String?)] = [], status: Int = 200, ollama: Bool = false) {
        lock.withLock { Self.live = live; Self.replies = replies; Self.status = status; Self.ollama = ollama; captured = [] }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var forwarded = request
        if forwarded.httpBody == nil, let stream = forwarded.httpBodyStream {
            stream.open(); defer { stream.close() }; var bytes = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while true { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; bytes.append(contentsOf: buffer.prefix(count)) }
            forwarded.httpBodyStream = nil; forwarded.httpBody = bytes
        }
        if let bytes = forwarded.httpBody, let body = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] { Self.lock.withLock { Self.captured.append(body) } }
        if !Self.lock.withLock({ Self.live }) {
            let (reply, status, ollama) = Self.lock.withLock { () -> ((String, String?), Int, Bool) in
                let next = Self.replies.isEmpty ? ("invalid exhausted fixture", nil) : Self.replies.removeFirst()
                return (next, Self.status, Self.ollama)
            }
            var body: [String: Any]
            if status != 200 { body = ["error": ["message": "Synthetic service unavailable"]] }
            else if ollama { body = ["message": ["content": reply.0], "done_reason": reply.1 ?? "stop"] }
            else { body = ["choices": [["message": ["content": reply.0], "finish_reason": reply.1 ?? "stop"]]] }
            let data = try! JSONSerialization.data(withJSONObject: body)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self); return
        }
        forwardingTask = URLSession.shared.dataTask(with: forwarded) { [weak self] data, response, error in
            guard let self else { return }
            if let error { self.client?.urlProtocol(self, didFailWithError: error); return }
            guard let data, let response else { return }
            if let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let message = reply["message"] as? [String: Any] {
                let content = message["content"] as? String ?? "", thinking = message["thinking"] as? String ?? ""
                print("LOCAL_MODEL_REPLY: reason=\(reply["done_reason"] ?? "unknown"); generated=\(reply["eval_count"] ?? 0); content_bytes=\(content.utf8.count); thinking_bytes=\(thinking.utf8.count); prefix=\(String(content.prefix(240)))")
            }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data); self.client?.urlProtocolDidFinishLoading(self)
        }; forwardingTask?.resume()
    }
    override func stopLoading() { forwardingTask?.cancel() }
}
