import XCTest
import MorrowCore
@testable import MorrowApp

@MainActor final class ReaderTranslationTests: XCTestCase {
    private func source(_ id: String = "first", version: String = "v1", text: String = "Original body", html: String = "") throws -> ReaderBodySource {
        var mail = MailMessage(accountID: "synthetic", from: .init(email: "sender@example.invalid"), subject: "Subject", text: text)
        mail.id = id; mail.contentRevision = version; mail.html = html
        return try ReaderBodySource(mail)
    }
    private func settle(_ predicate: () -> Bool) async {
        for _ in 0..<200 { if predicate() { return }; try? await Task.sleep(for: .milliseconds(5)) }
        XCTFail("Translation state did not settle")
    }
    func testToggleReusesResultAndBodyRevisionRetranslates() async throws {
        let model = ReaderTranslationModel(), count = ReaderTranslationCounter()
        let operation: @Sendable (String, String, MailTranslationLanguage, @escaping @Sendable (Int, Int) async -> Void) async throws -> MailTranslation = { subject, text, language, progress in
            await count.increment(); await progress(1, 1)
            return .init(subject: subject, text: text, language: language, source: "fixture")
        }
        model.translate(try source(), subject: "Subject", using: operation)
        await settle { model.result != nil }
        XCTAssertTrue(model.matches(id: "first", version: "v1", subject: "Subject"))
        XCTAssertFalse(model.matches(id: "first", version: "v2", subject: "Subject"))
        XCTAssertFalse(model.matches(id: "second", version: "v1", subject: "Subject"))
        model.showsTranslation = false
        model.translate(try source(), subject: "Subject", using: operation)
        XCTAssertTrue(model.showsTranslation)
        let firstCount = await count.value; XCTAssertEqual(firstCount, 1)
        model.translate(try source(version: "v2", text: "Changed body"), subject: "Subject", using: operation)
        await settle { model.result?.text == "Changed body" }
        let secondCount = await count.value; XCTAssertEqual(secondCount, 2)
        XCTAssertEqual(model.completed, 1)
    }
    func testSwitchingMessageRejectsLateResponseAndProgress() async throws {
        let model = ReaderTranslationModel(), pending = ReaderTranslationPending()
        model.translate(try source(), subject: "Subject") { subject, text, language, progress in
            await pending.wait(); await progress(9, 9)
            return .init(subject: subject, text: "Obsolete translation", language: language, source: "fixture")
        }
        await settle { model.isTranslating }
        await pending.waitUntilStarted()
        model.translate(try source("second"), subject: "New subject") { subject, text, language, progress in
            await progress(1, 1)
            return .init(subject: subject, text: "Current translation", language: language, source: "fixture")
        }
        await settle { model.result != nil }
        await pending.resume()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(model.result?.text, "Current translation"); XCTAssertEqual(model.completed, 1)
    }
    func testCancelDiscardsResponseAndFailureCanRetryWithHTMLOnlyBody() async throws {
        let model = ReaderTranslationModel(), pending = ReaderTranslationPending()
        model.translate(try source(), subject: "Subject") { subject, text, language, progress in
            await pending.wait(); return .init(subject: subject, text: text, language: language, source: "fixture")
        }
        await pending.waitUntilStarted(); model.reset(); await pending.resume()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(model.result); XCTAssertFalse(model.isVisible)
        let html = try source(text: "", html: "<style>hidden</style><p>Hello &amp; welcome</p><script>hidden()</script>")
        model.translate(html, subject: "Subject") { _, _, _, _ in throw MailTranslationError.incomplete }
        await settle { model.error != nil }
        XCTAssertFalse(model.showsTranslation)
        model.language = .japanese
        model.translate(html, subject: "Subject") { subject, text, language, progress in
            XCTAssertEqual(text, "Hello & welcome"); XCTAssertEqual(language, .japanese)
            return .init(subject: subject, text: "こんにちは", language: language, source: "fixture")
        }
        await settle { model.result != nil }
        XCTAssertNil(model.error); XCTAssertTrue(model.showsTranslation)
    }
}
private actor ReaderTranslationCounter { var value = 0; func increment() { value += 1 } }
private actor ReaderTranslationPending {
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func waitUntilStarted() async { while continuation == nil { await Task.yield() } }
    func resume() { continuation?.resume(); continuation = nil }
}
