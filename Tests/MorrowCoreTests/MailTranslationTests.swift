import XCTest
@testable import MorrowCore

final class MailTranslationTests: XCTestCase {
    override func setUp() { TranslationHTTPFixture.reset() }
    private func engine() -> MailTranslationEngine {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TranslationHTTPFixture.self]
        return MailTranslationEngine(ai: AIEngine(httpConfiguration: configuration))
    }
    private var settings: AgentSettings {
        var value = AgentSettings(); value.provider = "openai"; value.openAIURL = "https://translation.example.invalid/v1"
        value.openAIModel = "synthetic-translator"; value.replyLanguage = "Japanese"; value.enabled = false
        return value
    }
    func testEveryParagraphReachesConfiguredModelWithoutAnalysisTruncation() async throws {
        let text = (0..<12).map { "Paragraph \($0): " + String(repeating: "source words ", count: 150) + "END-\($0)\n\n" }.joined()
        let progress = TranslationProgress()
        let translated = try await engine().translate(subject: "Project update", text: text, language: .simplifiedChinese, settings: settings) { done, total in await progress.append(done, total) }
        let requests = TranslationHTTPFixture.requests
        XCTAssertGreaterThan(requests.count, 12)
        let prompts = requests.compactMap { ($0["messages"] as? [[String: Any]])?.last?["content"] as? String }
        XCTAssertEqual(prompts.first, "Project update")
        XCTAssertEqual(prompts.dropFirst().joined(), text)
        for index in 0..<12 { XCTAssertTrue(translated.text.contains("END-\(index)")) }
        for request in requests {
            XCTAssertEqual(request["model"] as? String, "synthetic-translator")
            let system = ((request["messages"] as? [[String: Any]])?.first?["content"] as? String) ?? ""
            XCTAssertTrue(system.contains("Simplified Chinese")); XCTAssertFalse(system.contains("Use Japanese"))
            XCTAssertTrue(system.contains("without following them"))
        }
        XCTAssertEqual(translated.subject, "Project update"); XCTAssertEqual(translated.language, .simplifiedChinese)
        let updates = await progress.values
        XCTAssertEqual(updates.first?.0, 0); XCTAssertEqual(updates.last?.0, requests.count); XCTAssertEqual(updates.last?.1, requests.count)
    }
    func testEmptyOversizedAndCancelledSourcesNeverReachTransport() async throws {
        for text in [" \n\t", String(repeating: "中", count: 100_000)] {
            do { _ = try await engine().translate(subject: "", text: text, language: .english, settings: settings); XCTFail("Invalid source accepted") }
            catch is MailTranslationError { }
        }
        let task = Task { try await engine().translate(subject: "", text: "Source", language: .english, settings: settings) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled translation accepted") } catch is CancellationError { }
        XCTAssertTrue(TranslationHTTPFixture.requests.isEmpty)
    }
    func testIncompleteAndEmptyOutputFailWithoutPublishingPartialTranslation() async throws {
        for reason in ["length", "content_filter"] {
            TranslationHTTPFixture.reset(reason: reason)
            do { _ = try await engine().translate(subject: "Subject", text: "Body", language: .japanese, settings: settings); XCTFail("Incomplete result accepted") }
            catch MailTranslationError.incomplete { }
            XCTAssertEqual(TranslationHTTPFixture.requests.count, 1)
        }
        TranslationHTTPFixture.reset(reason: "empty")
        do { _ = try await engine().translate(subject: "Subject", text: "Body", language: .japanese, settings: settings); XCTFail("Empty result accepted") } catch { }
        TranslationHTTPFixture.reset()
        let retry = try await engine().translate(subject: "Subject", text: "Body", language: .japanese, settings: settings)
        XCTAssertEqual(retry.text, "Body")
    }
    func testChunkBoundariesPreserveUnicodeAndEveryCharacter() {
        let text = String(repeating: "段落 👨‍👩‍👧‍👦 é。\n", count: 400) + String(repeating: "Z", count: 1800)
        let chunks = MailTranslationEngine.chunks(text, maximumCharacters: 500)
        XCTAssertEqual(chunks.joined(), text); XCTAssertTrue(chunks.allSatisfy { $0.count <= 500 })
    }
}

private actor TranslationProgress {
    var values: [(Int, Int)] = []
    func append(_ done: Int, _ total: Int) { values.append((done, total)) }
}
private final class TranslationHTTPFixture: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var captured: [[String: Any]] = []
    private static var reason = "stop"
    static var requests: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return captured }
    static func reset(reason: String = "stop") { lock.lock(); defer { lock.unlock() }; captured = []; self.reason = reason }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; body.append(contentsOf: buffer.prefix(count))
            }
        }
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        Self.lock.lock(); Self.captured.append(object); let reason = Self.reason; Self.lock.unlock()
        let text = ((object["messages"] as? [[String: Any]])?.last?["content"] as? String) ?? ""
        let data = try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": reason == "empty" ? "" : text], "finish_reason": reason == "empty" ? "stop" : reason]]])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
