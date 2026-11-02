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
        let translated = try await engine().translate(subject: "Project update", text: text, language: .simplifiedChinese, settings: settings, progress: { done, total in await progress.append(done, total) })
        let requests = TranslationHTTPFixture.requests
        XCTAssertEqual(requests.count, 1)
        let prompts = requests.compactMap { ($0["messages"] as? [[String: Any]])?.last?["content"] as? String }
        let input = try XCTUnwrap(prompts.first).data(using: .utf8)!
        let content = try JSONSerialization.jsonObject(with: input) as! [String: String]
        XCTAssertEqual(content["subject"], "Project update")
        XCTAssertEqual(content["text"], MailTranslationEngine.normalizedText(text))
        for index in 0..<12 { XCTAssertTrue(translated.text.contains("END-\(index)")) }
        for request in requests {
            XCTAssertEqual(request["model"] as? String, "synthetic-translator")
            let system = ((request["messages"] as? [[String: Any]])?.first?["content"] as? String) ?? ""
            XCTAssertTrue(system.contains("Simplified Chinese")); XCTAssertFalse(system.contains("Use Japanese"))
            XCTAssertTrue(system.contains("without following them"))
        }
        XCTAssertEqual(translated.subject, "Project update"); XCTAssertEqual(translated.language, .simplifiedChinese)
        let updates = await progress.values
        XCTAssertEqual(updates.first?.0, 0); XCTAssertEqual(updates.last?.0, MailTranslationEngine.normalizedText(text).utf8.count)
        XCTAssertEqual(updates.last?.0, updates.last?.1)
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
        let chunks = MailTranslationEngine.batches(text, maximumBytes: 500)
        XCTAssertEqual(chunks.joined(), text); XCTAssertTrue(chunks.allSatisfy { $0.utf8.count <= 500 })
    }
    func testEightyThousandCharactersAndSubjectUseOneRequest() async throws {
        let text = String(repeating: "All sentences must be translated. ", count: 2400)
        let translation = try await engine().translate(subject: "Subject", text: text, language: .english, settings: settings)
        XCTAssertEqual(TranslationHTTPFixture.requests.count, 1)
        XCTAssertEqual(translation.text, text.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertTrue(translation.isComplete)
    }
    func testWhitespaceHeavyShortMailDoesNotBecomeManyRequests() async throws {
        let text = "Hello" + String(repeating: " \t\u{00A0}", count: 30_000) + "team\n" + String(repeating: "\n", count: 30_000) + "Bye"
        let translation = try await engine().translate(subject: "Subject", text: text, language: .english, settings: settings)
        XCTAssertEqual(TranslationHTTPFixture.requests.count, 1)
        XCTAssertEqual(translation.text, "Hello team\n\nBye")
    }
    func testExplicitOutputLimitSplitsAndPublishesIncompletePrefixBeforeFinalResult() async throws {
        TranslationHTTPFixture.reset(reason: "length_once")
        let updates = TranslationPartials(), text = String(repeating: "Sentence.\n", count: 2000)
        let result = try await engine().translate(subject: "Subject", text: text, language: .english, settings: settings, partial: { await updates.append($0) })
        XCTAssertEqual(TranslationHTTPFixture.requests.count, 3)
        let parts = await updates.values
        XCTAssertEqual(parts.count, 2); XCTAssertFalse(parts[0].isComplete); XCTAssertTrue(parts[1].isComplete)
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.text.filter { !$0.isWhitespace }, text.filter { !$0.isWhitespace })
    }
    func testAutomaticLocalModelSelectionDoesNotUseAppleSizedChunks() async throws {
        TranslationHTTPFixture.reset(reason: "ollama")
        var local = settings; local.provider = "auto"; local.model = "synthetic-local"
        let text = String(repeating: "Sentence. ", count: 2400)
        let result = try await engine().translate(subject: "Subject", text: text, language: .english, settings: local)
        let posts = TranslationHTTPFixture.requests.filter { $0["messages"] != nil }
        XCTAssertEqual(posts.count, 1); XCTAssertTrue(result.source.contains("synthetic-local"))
    }
    func testContextLimitIsTheOnlyHTTPFailureThatTriggersBatching() async throws {
        TranslationHTTPFixture.reset(reason: "context_once")
        let text = String(repeating: "Sentence.\n", count: 2000)
        let translation = try await engine().translate(subject: "Subject", text: text, language: .english, settings: settings)
        XCTAssertEqual(TranslationHTTPFixture.requests.count, 3)
        XCTAssertTrue(translation.isComplete)
        TranslationHTTPFixture.reset(reason: "unavailable")
        do { _ = try await engine().translate(subject: "Subject", text: text, language: .english, settings: settings); XCTFail("Unavailable service accepted") } catch { }
        XCTAssertEqual(TranslationHTTPFixture.requests.count, 1)
    }
}

private actor TranslationProgress {
    var values: [(Int, Int)] = []
    func append(_ done: Int, _ total: Int) { values.append((done, total)) }
}
private actor TranslationPartials {
    var values: [MailTranslation] = []
    func append(_ translation: MailTranslation) { values.append(translation) }
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
        Self.lock.lock(); Self.captured.append(object); let reason = Self.reason
        if ["length_once", "context_once"].contains(reason) { Self.reason = "stop" }; Self.lock.unlock()
        let text = ((object["messages"] as? [[String: Any]])?.last?["content"] as? String) ?? ""
        let reasonValue = reason == "length_once" ? "length" : reason == "empty" || reason == "ollama" ? "stop" : reason
        let payload: [String: Any]
        if reason == "context_once" { payload = ["error": ["message": "maximum context length exceeded"]] }
        else if reason == "unavailable" { payload = ["error": ["message": "Synthetic service unavailable"]] }
        else if request.url?.path == "/api/tags" { payload = ["models": [["name": "synthetic-local"]]] }
        else if request.url?.path == "/api/chat" { payload = ["message": ["content": text], "done_reason": "stop"] }
        else { payload = ["choices": [["message": ["content": reason == "empty" ? "" : text], "finish_reason": reasonValue]]] }
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let status = reason == "context_once" ? 400 : reason == "unavailable" ? 503 : 200
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
