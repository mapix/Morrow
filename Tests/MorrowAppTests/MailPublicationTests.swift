import XCTest
import Combine
import MorrowCore
@testable import MorrowApp

final class MailPublicationTests: XCTestCase {
    @MainActor func testReloadPublishesOneValidatedSnapshotForBulkMail() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mail-publish-" + UUID().uuidString)
        let model = AppModel(root: root)
        defer { model.navigate(.inbox); try? FileManager.default.removeItem(at: root) }
        model.settings.enabled = false
        for i in 0..<64 {
            var mail = MailMessage(accountID: "synthetic", from: .init(email: "team@example.invalid"), subject: "Review \(i)", text: "Please review the delivery documents.")
            mail.analysis = PartnerEngine.baseline(mail)
            try await model.store.upsert(mail)
        }
        var publications = 0
        let subscription = model.$mails.dropFirst().sink { _ in publications += 1 }
        await model.reload()
        withExtendedLifetime(subscription) {}
        XCTAssertEqual(model.mails.count, 64)
        XCTAssertTrue(model.mails.allSatisfy { $0.analysis != nil })
        XCTAssertEqual(publications, 1, "Bulk reload must not republish/copy the complete array once per message")
    }
}
