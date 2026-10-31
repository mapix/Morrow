import XCTest
import Darwin
@testable import MorrowCore

final class MailRuleAndScopePerformanceTests: XCTestCase {
    func testRuleCompatibilityAndPreviewStopsAfterTwoNonemptyLines() {
        let cases: [(String, String, String, MailCategory, Int, Bool)] = [
            ("Team", "\n\nfirst\nsecond\nthird", "peer@example.invalid", .work, 0, false),
            ("INVOICE", "Please confirm receipt today", "peer@example.invalid", .finance, 2, true),
            ("Newsletter", "Please reply\nunsubscribe", "peer@example.invalid", .newsletter, 0, false),
            ("Security Alert", "Please confirm verification code", "no-reply@example.invalid", .notification, 0, false),
            ("Itinerary", "Can you confirm the hotel?", "peer@example.invalid", .travel, 1, true)
        ]
        for (subject, text, sender, category, priority, reply) in cases {
            let result = PartnerEngine.baseline(MailMessage(accountID: "fixture", from: .init(email: sender), subject: subject, text: text))
            XCTAssertEqual(result.category, category); XCTAssertEqual(result.priority, priority); XCTAssertEqual(result.needsReply, reply)
            XCTAssertEqual(result.summary, String(text.components(separatedBy: .newlines).filter { !$0.isEmpty }.prefix(2).joined(separator: " ").prefix(140)))
        }
        for text in ["\n\r\nfirst\r\nsecond\rthird", "  \n\nsecond\nthird", String(repeating: "中", count: 10_000) + "\nlast"] {
            XCTAssertEqual(MailRuleScan.preview(text), String(text.components(separatedBy: .newlines).filter { !$0.isEmpty }.prefix(2).joined(separator: " ").prefix(140)))
        }
    }

    func testRuleKeywordsCrossBlockAndSubjectBodyBoundaries() {
        let text = String(repeating: "x", count: 4092) + "please confirm TODAY invoice" + String(repeating: "y", count: 100)
        let result = PartnerEngine.baseline(MailMessage(accountID: "fixture", from: .init(email: "peer@example.invalid"), subject: "", text: text))
        XCTAssertEqual(result.category, .finance); XCTAssertEqual(result.priority, 2); XCTAssertTrue(result.needsReply)
        let joined = PartnerEngine.baseline(MailMessage(accountID: "fixture", from: .init(email: "peer@example.invalid"), subject: "please", text: "reply"))
        XCTAssertTrue(joined.needsReply)
    }

    func testScopeVisitsAllInventoryBatchesAndFutureCriteriaCannotBeReplaced() async throws {
        let recorder = ScopeRecorder()
        let peer = try PerformanceLoopbackPeer { connection in
            guard let body = connection.readHTTPRequest(), let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let messages = object["messages"] as? [[String: Any]], let prompt = messages.last?["content"] as? String else { return }
            recorder.begin(bytes: body.count); defer { recorder.end() }; usleep(10_000)
            let answer: [String: Any]
            if prompt.contains("阶段：scope-constraints") {
                recorder.constraints()
                answer = ["resolved": true, "selection": "Only Contract subjects from legal@example.invalid", "subjectTerms": ["Contract"], "senderEmails": ["legal@example.invalid"]]
            } else {
                let rows = Self.inventory(prompt)
                recorder.rows(rows.compactMap { $0["id"] as? String })
                let ids = rows.filter { $0["subject"] as? String == "Contract" && $0["from"] as? String == "legal@example.invalid" }.compactMap { $0["id"] as? String }
                // Extra model fields must not alter the previously fixed future
                // criteria, even if the provider ignores the JSON schema.
                answer = ["sourceMailIDs": ids, "subjectTerms": ["*"], "senderEmails": []]
            }
            Self.reply(answer, connection: connection)
        }; defer { peer.stop() }
        var mails: [MailMessage] = []
        for index in 0..<1100 {
            var mail = MailMessage(accountID: "fixture", from: .init(email: index.isMultiple(of: 3) ? "legal@example.invalid" : "other@example.invalid"), subject: index.isMultiple(of: 2) ? "Contract" : "Other", text: "")
            mail.id = "scope-\(index)"; mails.append(mail)
        }
        var settings = AgentSettings(); settings.provider = "openai"; settings.openAIURL = peer.url.absoluteString + "/v1"; settings.openAIModel = "synthetic-model"
        let scope = try await PartnerEngine().resolveScope("仅 legal@example.invalid 发来的 Contract 邮件及后续同主题来信", mails: mails, settings: settings)
        XCTAssertEqual(recorder.conditionCalls, 1); XCTAssertEqual(recorder.visited, Set(mails.map(\.id)))
        XCTAssertEqual(scope.subjectTerms, ["Contract"]); XCTAssertEqual(scope.senderEmails, ["legal@example.invalid"])
        XCTAssertEqual(Set(scope.sourceMailIDs), Set(mails.filter { $0.subject == "Contract" && $0.from.email == "legal@example.invalid" }.map(\.id)))
        XCTAssertLessThanOrEqual(recorder.peak, 2); XCTAssertLessThanOrEqual(recorder.maximumBytes, AIInputBounds.textBytes + 4096)
        XCTAssertTrue(scope.contains(MailMessage(accountID: "fixture", from: .init(email: "legal@example.invalid"), subject: "Contract update", text: "")))
        XCTAssertFalse(scope.contains(MailMessage(accountID: "fixture", from: .init(email: "other@example.invalid"), subject: "Contract update", text: "")))
        XCTAssertFalse(scope.contains(mails[2]))
    }

    func testScopeRejectsUnknownConditionsAndForeignBatchIDs() async throws {
        let unknownPeer = try PerformanceLoopbackPeer { connection in
            guard connection.readHTTPRequest() != nil else { return }
            Self.reply(["resolved": false, "selection": "", "subjectTerms": [], "senderEmails": []], connection: connection)
        }; defer { unknownPeer.stop() }
        var settings = AgentSettings(); settings.provider = "openai"; settings.openAIURL = unknownPeer.url.absoluteString + "/v1"; settings.openAIModel = "synthetic-model"
        do { _ = try await PartnerEngine().resolveScope("那件事相关邮件", mails: [], settings: settings); XCTFail("Unknown scope accepted") } catch { XCTAssertTrue(error.localizedDescription.contains("无法确定")) }
        let foreignPeer = try PerformanceLoopbackPeer { connection in
            guard let body = connection.readHTTPRequest(), let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let messages = object["messages"] as? [[String: Any]], let prompt = messages.last?["content"] as? String else { return }
            if prompt.contains("阶段：scope-constraints") { Self.reply(["resolved": true, "selection": "Contract", "subjectTerms": [], "senderEmails": []], connection: connection) }
            else { Self.reply(["sourceMailIDs": ["invented-ID"]], connection: connection) }
        }; defer { foreignPeer.stop() }
        settings.openAIURL = foreignPeer.url.absoluteString + "/v1"
        let mail = MailMessage(accountID: "fixture", from: .init(email: "legal@example.invalid"), subject: "Contract", text: "")
        do { _ = try await PartnerEngine().resolveScope("Contract邮件", mails: [mail], settings: settings); XCTFail("Foreign batch ID accepted") } catch { XCTAssertTrue(error.localizedDescription.contains("不存在")) }
    }

    func testScopeCancellationStopsPendingBatches() async throws {
        let accepted = expectation(description: "Scope selection pending"), recorder = ScopeRecorder()
        let peer = try PerformanceLoopbackPeer { connection in
            guard let body = connection.readHTTPRequest(), let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let messages = object["messages"] as? [[String: Any]], let prompt = messages.last?["content"] as? String else { return }
            if prompt.contains("阶段：scope-constraints") { Self.reply(["resolved": true, "selection": "Contract", "subjectTerms": [], "senderEmails": []], connection: connection) }
            else { if recorder.firstSelection() { accepted.fulfill() }; _ = connection.readLine() }
        }; defer { peer.stop() }
        var mails: [MailMessage] = []
        for index in 0..<1100 { var mail = MailMessage(accountID: "fixture", from: .init(email: "legal@example.invalid"), subject: "Contract", text: ""); mail.id = "scope-cancel-\(index)"; mails.append(mail) }
        var settings = AgentSettings(); settings.provider = "openai"; settings.openAIURL = peer.url.absoluteString + "/v1"; settings.openAIModel = "synthetic-model"
        let request = Task { try await PartnerEngine().resolveScope("Contract邮件", mails: mails, settings: settings) }
        await fulfillment(of: [accepted], timeout: 2); let start = ContinuousClock.now; request.cancel()
        do { _ = try await request.value; XCTFail("Cancelled scope returned partial coverage") } catch is CancellationError { }
        XCTAssertLessThan(start.duration(to: .now), .seconds(1)); XCTAssertLessThanOrEqual(recorder.selectionCalls, 2)
    }

    private static func inventory(_ prompt: String) -> [[String: Any]] {
        guard let start = prompt.range(of: "<mail-inventory>\n"), let end = prompt.range(of: "\n</mail-inventory>") else { return [] }
        return prompt[start.upperBound..<end.lowerBound].split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }
    private static func reply(_ answer: [String: Any], connection: PerformanceLoopbackConnection) {
        guard let text = try? JSONSerialization.data(withJSONObject: answer), let source = String(data: text, encoding: .utf8), let body = try? JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": source]]]]) else { return }
        _ = connection.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"); _ = connection.write(body)
    }
}

private final class ScopeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: Set<String> = []
    private var active = 0, maximum = 0, bytes = 0, conditions = 0, selections = 0
    var conditionCalls: Int { lock.lock(); defer { lock.unlock() }; return conditions }
    var visited: Set<String> { lock.lock(); defer { lock.unlock() }; return seen }
    var peak: Int { lock.lock(); defer { lock.unlock() }; return maximum }
    var maximumBytes: Int { lock.lock(); defer { lock.unlock() }; return bytes }
    var selectionCalls: Int { lock.lock(); defer { lock.unlock() }; return selections }
    func begin(bytes: Int) { lock.lock(); active += 1; maximum = max(maximum, active); self.bytes = max(self.bytes, bytes); lock.unlock() }
    func end() { lock.lock(); active -= 1; lock.unlock() }
    func constraints() { lock.lock(); conditions += 1; lock.unlock() }
    func rows(_ ids: [String]) { lock.lock(); seen.formUnion(ids); lock.unlock() }
    func firstSelection() -> Bool { lock.lock(); defer { lock.unlock() }; selections += 1; return selections == 1 }
}
