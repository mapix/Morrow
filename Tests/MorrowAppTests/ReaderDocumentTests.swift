import XCTest
import MorrowCore
@testable import MorrowApp

final class ReaderDocumentTests: XCTestCase {
    private func input(_ body: String, html: Bool = true) -> ReaderDocumentInput {
        .init(mailID: "synthetic-reader", body: body, usesHTML: html, allowsRemoteImages: false,
              themeCSS: ":root{--paper:#fff;--ink:#111;--rule:#ddd;}", emptyMessage: "Empty", attachments: [])
    }
    func testOriginalHeadAndSenderLayoutSurviveWithoutNestedDocument() throws {
        let source = "<!doctype html><html><head><style>.invoice{color:blue}</style><meta charset=\"gbk\"></head><body><table class=\"invoice\"><tr><td>中文 delivery</td></tr></table><img src=\"https://example.invalid/tracker.png\"><script>ignored()</script></body></html>"
        let document = try ReaderHTMLDocument.prepare(input(source))
        XCTAssertEqual(document.content.components(separatedBy: "<html>").count - 1, 1)
        XCTAssertTrue(document.content.contains(".invoice{color:blue}"))
        XCTAssertTrue(document.content.contains("中文 delivery"))
        XCTAssertTrue(document.content.contains("script-src 'none'"))
        XCTAssertTrue(document.content.contains("connect-src 'none'"))
        XCTAssertTrue(document.content.contains("img-src data: morrow-cid:;"))
        XCTAssertFalse(document.allowsRemoteImages)
        XCTAssertTrue(document.hasRemoteImages)
        let security = try XCTUnwrap(document.content.range(of: "Content-Security-Policy"))
        let originalStyle = try XCTUnwrap(document.content.range(of: ".invoice{color:blue}"))
        XCTAssertLessThan(security.lowerBound, originalStyle.lowerBound)
    }
    func testPlainTextIsEscapedAndInlineImagesUseDeclaredAssetsOnly() throws {
        let plain = try ReaderHTMLDocument.prepare(input("<script>never execute</script>\nline two & value", html: false))
        XCTAssertTrue(plain.content.contains("&lt;script&gt;never execute&lt;/script&gt;"))
        XCTAssertTrue(plain.content.contains("white-space:pre-wrap"))
        var rich = input("<img src=\"cid:KNOWN%40example.invalid\"><img src=\"cid:unknown\">")
        rich.attachments = [MailAttachment(name: "logo.png", mimeType: "image/png", data: Data([1, 2, 3]), contentID: "<known@example.invalid>")]
        let document = try ReaderHTMLDocument.prepare(rich)
        XCTAssertTrue(document.content.contains("morrow-cid://" + document.host))
        XCTAssertTrue(document.content.contains("cid:unknown"))
        XCTAssertEqual(document.assets.count, 1)
        XCTAssertFalse(document.content.contains("base64,"))
        rich.allowsRemoteImages = true
        let enabled = try ReaderHTMLDocument.prepare(rich)
        XCTAssertTrue(enabled.content.contains("img-src data: morrow-cid: https: http:;"))
        XCTAssertTrue(enabled.content.contains("script-src 'none'"))
    }
    func testPreparedDocumentsAreReusedAndCacheIsBounded() async throws {
        let cache = ReaderDocumentCache(maximumEntries: 2, maximumBytes: 8_000)
        let original = input("<p>Original</p>")
        let first = try await cache.prepare(original)
        let repeated = try await cache.prepare(original)
        XCTAssertEqual(first.id, repeated.id)
        let count = await cache.preparationCount
        XCTAssertEqual(count, 1)
        let second = try await cache.prepare(input("<p>Changed</p>"))
        XCTAssertNotEqual(first.id, second.id)
        for index in 0..<8 { _ = try await cache.prepare(input("<p>Item \(index)</p>")) }
        let retained = await cache.retainedBytes()
        XCTAssertLessThanOrEqual(retained, 8_000)
    }
    func testBlockedRemoteImagesCollapseSourceDimensionsAndPreserveSurroundings() throws {
        let remote = "<img width=\"640\" height=\"1200\" style=\"height:1200px;width:640px\" src=\"https://example.invalid/news.jpg\" alt=\"News &amp; &quot;quoted&quot; &lt;script&gt;\">"
        let source = "<table class=\"newsletter\"><tr><td><a href=\"https://example.invalid/story\">" + remote + "</a><p>Actual newsletter text</p></td></tr></table>"
        var request = input(source); request.blockedImageLabel = "External image blocked"
        let blocked = try ReaderHTMLDocument.prepare(request)
        XCTAssertTrue(blocked.hasRemoteImages)
        XCTAssertTrue(blocked.content.contains("class=\"morrow-blocked-image\" role=\"img\""))
        XCTAssertTrue(blocked.content.contains("External image blocked · News &amp; &quot;quoted&quot; &lt;script&gt;"))
        XCTAssertFalse(blocked.content.contains("height:1200px"))
        XCTAssertFalse(blocked.content.contains("height=\"1200\""))
        XCTAssertTrue(blocked.content.contains("<table class=\"newsletter\">"))
        XCTAssertTrue(blocked.content.contains("<a href=\"https://example.invalid/story\">"))
        XCTAssertTrue(blocked.content.contains("Actual newsletter text"))
        request.allowsRemoteImages = true
        let enabled = try ReaderHTMLDocument.prepare(request)
        XCTAssertTrue(enabled.content.contains(remote))
        XCTAssertFalse(enabled.content.contains("class=\"morrow-blocked-image\""))
    }
    func testProtocolRelativeAndRemoteSrcsetAreBlockedButLocalImagesAndCommentsStay() throws {
        let source = "<img src='//example.invalid/large.jpg' height='900'><img src='data:image/png;base64,AA==' srcset='//example.invalid/2x.png 2x, https://example.invalid/1x.png 1x' height='700'><img src='data:image/png;base64,AA==' alt='Local'><img src='cid:unknown' alt='Inline'><!-- <img src='https://example.invalid/comment.png' height='999'> -->"
        let blocked = try ReaderHTMLDocument.prepare(input(source))
        XCTAssertEqual(blocked.content.components(separatedBy: "class=\"morrow-blocked-image\"").count - 1, 2)
        XCTAssertFalse(blocked.content.contains("height='900'"))
        XCTAssertFalse(blocked.content.contains("height='700'"))
        XCTAssertTrue(blocked.content.contains("<img src='data:image/png;base64,AA==' alt='Local'>"))
        XCTAssertTrue(blocked.content.contains("<img src='cid:unknown' alt='Inline'>"))
        XCTAssertTrue(blocked.content.contains("<!-- <img src='https://example.invalid/comment.png' height='999'> -->"))
    }
}
