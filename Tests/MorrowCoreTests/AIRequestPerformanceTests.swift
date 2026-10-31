import XCTest
@testable import MorrowCore

final class AIRequestPerformanceTests: XCTestCase {
    func testCatalogSingleflightAndFailureCacheAvoidRepeatedProbes() async throws {
        let cache = AIModelCatalogCache(), counter = ProbeCounter()
        let models = try await withThrowingTaskGroup(of: [String].self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try await cache.models(endpoint: "https://fixture.example.invalid/models", credential: "synthetic") {
                        await counter.increment(); try await Task.sleep(for: .milliseconds(30)); return ["synthetic-model"]
                    }
                }
            }
            var values: [[String]] = []; for try await value in group { values.append(value) }; return values
        }
        XCTAssertEqual(models.count, 20); XCTAssertTrue(models.allSatisfy { $0 == ["synthetic-model"] })
        let count = await counter.value; XCTAssertEqual(count, 1)
        let failures = ProbeCounter()
        for _ in 0..<2 {
            do {
                _ = try await cache.models(endpoint: "https://unavailable.example.invalid/models", credential: "synthetic") {
                    await failures.increment(); throw MailError.message("synthetic unavailable")
                }
                XCTFail("Unavailable catalog succeeded")
            } catch { }
        }
        let failureCount = await failures.value; XCTAssertEqual(failureCount, 1)
    }

    func testCancelledCatalogWaiterDoesNotCancelSharedProbe() async throws {
        let cache = AIModelCatalogCache(), counter = ProbeCounter()
        let first = Task {
            try await cache.models(endpoint: "https://shared.example.invalid/models", credential: "synthetic") {
                await counter.increment(); try await Task.sleep(for: .milliseconds(100)); return ["shared-model"]
            }
        }
        for _ in 0..<100 { if await counter.value == 1 { break }; try await Task.sleep(for: .milliseconds(2)) }
        let second = Task { try await cache.models(endpoint: "https://shared.example.invalid/models", credential: "synthetic") { XCTFail("Second probe started"); return [] } }
        first.cancel()
        do { _ = try await first.value; XCTFail("Cancelled catalog waiter succeeded") } catch is CancellationError { }
        let models = try await second.value; XCTAssertEqual(models, ["shared-model"])
        let count = await counter.value; XCTAssertEqual(count, 1)
    }

    func testInputAndSSECumulativeByteLimits() throws {
        XCTAssertThrowsError(try AIInputBounds.validate(system: "", prompt: String(repeating: "中", count: 100_000), images: [], maxTokens: 100))
        XCTAssertThrowsError(try AIInputBounds.validate(system: "", prompt: "", images: [], maxTokens: 20_000))
        XCTAssertThrowsError(try AIInputBounds.validate(system: "", prompt: "", images: Array(repeating: Data([1]), count: 9), maxTokens: 100))
        var output = ChatGPTResponseStream(maximumOutputBytes: 8)
        let delta = #"data: {"type":"response.output_text.delta","delta":"中文"}"#
        _ = try output.feed(line: delta); _ = try output.feed(line: "")
        _ = try output.feed(line: delta); XCTAssertThrowsError(try output.feed(line: ""))
        var event = ChatGPTResponseStream(maximumEventBytes: 16)
        _ = try event.feed(line: "data: 12345678"); XCTAssertThrowsError(try event.feed(line: "data: 12345678"))
        var heartbeat = ChatGPTSSEBytes(maximumStreamBytes: 64)
        XCTAssertThrowsError(try String(repeating: ": ping\n\n", count: 20).utf8.forEach { _ = try heartbeat.feed($0) })
        var completed = ChatGPTResponseStream(maximumOutputBytes: 8)
        _ = try completed.feed(line: #"data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"long final text"}]}]}}"#)
        XCTAssertThrowsError(try completed.feed(line: ""))
    }

    func testStoreReportProcessesEveryIDAcrossBatchesWithoutHugeRequest() async throws {
        let recorder = PromptRecorder()
        let peer = try PerformanceLoopbackPeer { connection in
            guard let body = connection.readHTTPRequest(), let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let messages = object["messages"] as? [[String: Any]] else { return }
            recorder.append(messages.compactMap { $0["content"] as? String }.joined(separator: "\n"), bytes: body.count)
            let response = Data(#"{"choices":[{"message":{"content":"synthetic bounded summary"}}]}"#.utf8)
            _ = connection.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(response.count)\r\nConnection: close\r\n\r\n"); _ = connection.write(response)
        }; defer { peer.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("morrow-small-evidence-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MailStore(root: directory)
        var ids: [String] = []
        for index in 0..<19 {
            var mail = MailMessage(accountID: "synthetic", from: MailAddress(email: "fixture@example.invalid"), subject: "Synthetic \(index)", text: String(repeating: "a", count: 1000) + "EVIDENCE-MARKER-\(index)-END" + String(repeating: "b", count: 1000))
            mail.id = "synthetic-\(index)"; ids.append(mail.id); _ = try await store.upsert(mail)
        }
        var settings = AgentSettings(); settings.provider = "openai"; settings.openAIURL = peer.url.absoluteString + "/v1"; settings.openAIModel = "synthetic-model"
        let result = try await PartnerEngine().report(instruction: "Summarize the actual evidence", mailIDs: ids + [ids[0]], store: store, settings: settings)
        XCTAssertEqual(result.text, "synthetic bounded summary")
        let prompts = recorder.prompts
        for index in 0..<19 { XCTAssertTrue(prompts.contains { $0.contains("EVIDENCE-MARKER-\(index)-END") }, "Source \(index) was never read by the model") }
        XCTAssertTrue(prompts.last?.contains("全部19封") == true)
        XCTAssertLessThanOrEqual(recorder.maximumBytes, AIInputBounds.textBytes + 4096)
        XCTAssertGreaterThan(prompts.count, 3)
    }

    func testMissingBodyAndPreviewAreNotReportedAsCompleteCoverage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("morrow-missing-evidence-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MailStore(root: directory), engine = PartnerEngine()
        var settings = AgentSettings(); settings.provider = "openai"; settings.openAIURL = "http://127.0.0.1:9/v1"
        do { _ = try await engine.report(instruction: "Summarize", mailIDs: ["absent"], store: store, settings: settings); XCTFail("Missing source accepted") } catch { XCTAssertTrue(error.localizedDescription.contains("未完成全部资料读取")) }
        var preview = MailMessage(accountID: "synthetic", from: MailAddress(email: "fixture@example.invalid"), subject: "Preview", text: "Incomplete preview")
        preview.contentAvailability = .preview
        do { _ = try await engine.draft(instruction: "Reply", mails: [preview], settings: settings); XCTFail("Preview treated as full body") } catch { XCTAssertTrue(error.localizedDescription.contains("摘要")) }
    }
}

private actor ProbeCounter {
    var value = 0
    func increment() { value += 1 }
}
private final class PromptRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    private var bytes = 0
    var prompts: [String] { lock.lock(); defer { lock.unlock() }; return values }
    var maximumBytes: Int { lock.lock(); defer { lock.unlock() }; return bytes }
    func append(_ value: String, bytes: Int) { lock.lock(); values.append(value); self.bytes = max(self.bytes, bytes); lock.unlock() }
}
