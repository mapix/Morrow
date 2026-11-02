import XCTest
import MorrowCore
@testable import MorrowApp

final class MailReferenceListTests: XCTestCase {
    func test863ReferencesRemainAccessibleAcrossBoundedPages() {
        let ids = (0..<863).map { "source-\($0)" }
        let pages = MailReferencePages(ids: ids + [ids[0], ids[862]])
        XCTAssertEqual(pages.count, 863); XCTAssertEqual(pages.pageCount, 18)
        var visited: [String] = []
        for page in 0..<pages.pageCount {
            let visible = pages.visibleIDs(page, expanded: true)
            XCTAssertLessThanOrEqual(visible.count, 50)
            visited.append(contentsOf: visible)
        }
        XCTAssertEqual(visited, ids)
        XCTAssertEqual(pages.visibleIDs(17, expanded: true).count, 13)
    }
    func testCollapsedReferencesExposeNoRowsAndPageEdgesAreSafe() {
        let pages = MailReferencePages(ids: (0..<863).map(String.init))
        XCTAssertTrue(pages.visibleIDs(0, expanded: false).isEmpty)
        XCTAssertEqual(pages.visibleIDs(-100, expanded: true), pages.visibleIDs(0, expanded: true))
        XCTAssertEqual(pages.visibleIDs(Int.max, expanded: true), pages.visibleIDs(17, expanded: true))
        let empty = MailReferencePages(ids: [])
        XCTAssertEqual(empty.pageCount, 0); XCTAssertTrue(empty.visibleIDs(0, expanded: true).isEmpty)
        XCTAssertEqual(MailReferencePages(ids: pages.ids, pageSize: 100_000).pageSize, 50)
    }
    @MainActor func testReferenceMetadataLookupUsesTheMailboxIndexAt80000Messages() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(root: root); model.settings.enabled = false
        model.mails = (0..<80_000).map { index in
            var mail = MailMessage(accountID: "fixture", from: .init(email: "peer@example.invalid"), subject: "Synthetic \(index)", text: "")
            mail.id = "mail-\(index)"; mail.messageID = "<\(index)@example.invalid>"; return mail
        }
        let ids = (0..<863).map { "mail-\($0 * 90)" }
        let pages = MailReferencePages(ids: ids)
        let started = ContinuousClock.now
        let references = pages.visibleIDs(17, expanded: true).compactMap(model.mailByID)
        XCTAssertLessThan(started.duration(to: .now), .milliseconds(500))
        XCTAssertEqual(references.map(\.id), Array(ids.suffix(13)))
        XCTAssertNil(model.mailByID("unavailable-reference"))
    }
}
