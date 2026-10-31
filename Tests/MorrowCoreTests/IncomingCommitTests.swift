import XCTest
@testable import MorrowCore

final class IncomingCommitTests: XCTestCase {
    private struct Job: Codable { var messageID: String; var phase = "queued" }
    private struct FailingJob: Encodable {
        struct Failure: Error {}
        func encode(to encoder: Encoder) throws { throw Failure() }
    }
    func testIncomingMessageAndProcessingJobShareOneCommit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("incoming-commit-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MailStore(root: root)
        let mail = MailMessage(accountID: "synthetic", from: .init(email: "team@example.invalid"), subject: "Synthetic incoming message", text: "Process this mail")
        let saved = try await store.commitIncoming(mail, object: Job(messageID: mail.id), kind: "mobile-processing-job", id: mail.id)
        XCTAssertEqual(saved.id, mail.id)
        let persisted = try await store.message(mail.id)
        let job = try await store.object(Job.self, kind: "mobile-processing-job", id: mail.id)
        XCTAssertNotNil(persisted); XCTAssertEqual(job?.messageID, saved.id)
        let another = MailMessage(accountID: "synthetic", from: .init(email: "team@example.invalid"), subject: "Failed job", text: "Must remain uncommitted")
        do { _ = try await store.commitIncoming(another, object: FailingJob(), kind: "mobile-processing-job", id: another.id); XCTFail("Expected encode failure") }
        catch is FailingJob.Failure {}
        let absentMail = try await store.message(another.id)
        let absentJob = try await store.object(Job.self, kind: "mobile-processing-job", id: another.id)
        XCTAssertNil(absentMail); XCTAssertNil(absentJob)
        let remaining = try await store.messages()
        XCTAssertEqual(remaining.count, 1)
    }
}
