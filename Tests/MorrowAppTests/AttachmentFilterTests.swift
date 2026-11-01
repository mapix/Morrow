import XCTest
import MorrowCore
@testable import MorrowApp

final class AttachmentFilterTests: XCTestCase {
    @MainActor func testFilterUpdatesForQueryKindAndMailChangesButNotSyncProgress() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = AppModel(root: root); defer { try? FileManager.default.removeItem(at: root) }
        var first = MailMessage(accountID: "fixture", from: .init(email: "sender@example.invalid"), subject: "invoice", text: "preview")
        first.attachments = [.init(name: "invoice.pdf", mimeType: "application/pdf", data: Data())]
        var second = first; second.id = "second"; second.subject = "photo"; second.attachments = [.init(name: "photo.jpg", mimeType: "image/jpeg", data: Data())]
        model.mails = [first, second]
        XCTAssertEqual(model.filteredAttachments.count, 2)
        model.attachmentQuery = "invoice"; XCTAssertEqual(model.filteredAttachments.map(\.attachment.name), ["invoice.pdf"])
        model.syncBusy = true; model.mailSyncProgress = .init(processed: 1, total: 2)
        XCTAssertEqual(model.filteredAttachments.map(\.attachment.name), ["invoice.pdf"])
        model.attachmentQuery = ""; model.attachmentKind = "图片"
        XCTAssertEqual(model.filteredAttachments.map(\.attachment.name), ["photo.jpg"])
        second.attachments = []; model.mails = [first, second]
        XCTAssertTrue(model.filteredAttachments.isEmpty)
    }
}
