import XCTest
import MorrowCore
@testable import MorrowApp

@MainActor final class MailReloadPerformanceTests: XCTestCase {
    func testUnchangedReloadAndHeaderBatchDoNotRepublishMailbox() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reload-equality-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(root: root); model.settings.enabled = false
        var mail = MailMessage(accountID: "fixture", from: .init(email: "sender@example.invalid"), subject: "Fixture", text: "Full evidence")
        mail.id = "one"; _ = try await model.store.upsert(mail)
        await model.reload(); let revision = model.mailRevision
        await model.reload(); XCTAssertEqual(model.mailRevision, revision)
        await model.reload(incoming: model.mails); XCTAssertEqual(model.mailRevision, revision)
        mail.isStarred = true; let updated = try await model.store.upsert(mail)
        await model.reload(incoming: [updated])
        XCTAssertGreaterThan(model.mailRevision, revision); XCTAssertEqual(model.mailByID(mail.id)?.isStarred, true)
        model.contactRefreshTask?.cancel()
    }
}
