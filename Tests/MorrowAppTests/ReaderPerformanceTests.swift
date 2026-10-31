import XCTest
import MorrowCore
@testable import MorrowApp

final class ReaderPerformanceTests: XCTestCase {
    func testReaderFetchesCompleteContentWhenListContainsOnlyPreview() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reader-content-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MailStore(root: root)
        var original = MailMessage(accountID: "synthetic", from: .init(email: "team@example.invalid"), subject: "Source", text: String(repeating: "完整原文 ", count: 3000))
        original.html = "<html><head><style>table{color:blue}</style></head><body><table><tr><td>Original source</td></tr></table></body></html>"
        try await store.upsert(original)
        var preview = original; preview.text = String(original.text.prefix(100)); preview.html = ""; preview.contentAvailability = .preview
        XCTAssertThrowsError(try ReaderBodySource(preview))
        let source = try await ReaderBodySource.load(id: preview.id, store: store)
        XCTAssertEqual(source.text, original.text)
        XCTAssertEqual(source.html, original.html)
        XCTAssertGreaterThan(source.text.count, preview.text.count)
    }
    func testRapidSelectionRejectsEarlierContentAfterAnotherMessageOrRetry() {
        var selection = ReaderBodySelection()
        let first = selection.begin(.init(id: "first", version: "v1"))
        let second = selection.begin(.init(id: "second", version: "v1"))
        XCTAssertFalse(selection.accepts(first)); XCTAssertTrue(selection.accepts(second))
        let retry = selection.begin(.init(id: "second", version: "v1", retry: 1))
        XCTAssertFalse(selection.accepts(second)); XCTAssertTrue(selection.accepts(retry))
        selection.cancel(); XCTAssertFalse(selection.accepts(retry))
    }
    func testHTMLExportAcknowledgementDoesNotSerializeUnchangedContentAgain() {
        var revision = RichTextExportRevision()
        revision.imported(hasHTML: true)
        XCTAssertFalse(revision.needsExport)
        revision.edited(); let firstEdit = revision.current
        XCTAssertTrue(revision.needsExport)
        revision.acknowledge(firstEdit)
        XCTAssertFalse(revision.needsExport)
        revision.edited(); revision.acknowledge(firstEdit)
        XCTAssertTrue(revision.needsExport, "An older export must not suppress a later edit")
        revision.acknowledge(revision.current)
        XCTAssertFalse(revision.needsExport)
        revision.imported(hasHTML: false)
        XCTAssertTrue(revision.needsExport, "Plain text entering rich mode still needs an initial HTML export")
    }
}
