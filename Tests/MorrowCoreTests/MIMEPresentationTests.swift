import XCTest
@testable import MorrowCore

final class MIMEPresentationTests: XCTestCase {
    func testAlternativeSelectsLastVersionAndKeepsCalendarOutOfBody() {
        let raw = """
        From: team@example.invalid
        Content-Type: multipart/alternative; boundary=choice

        --choice
        Content-Type: text/plain; charset=utf-8

        Older plain version
        --choice
        Content-Type: text/plain; charset=utf-8

        Current plain version
        --choice
        Content-Type: text/html; charset=utf-8

        <p>Older HTML version</p>
        --choice
        Content-Type: text/html; charset=utf-8

        <p>Current HTML version</p>
        --choice
        Content-Type: text/x-amp-html; charset=utf-8

        <amp-story>Unsupported alternate</amp-story>
        --choice
        Content-Type: text/calendar; charset=utf-8; method=REQUEST

        BEGIN:VCALENDAR
        VERSION:2.0
        END:VCALENDAR
        --choice--
        """
        let mail = MIMEParser.parse(Data(raw.utf8), accountID: "synthetic")
        XCTAssertEqual(mail.text, "Current plain version")
        XCTAssertEqual(mail.html, "<p>Current HTML version</p>")
        XCTAssertEqual(mail.attachments.count, 1)
        XCTAssertEqual(mail.attachments.first?.name, "邀请.ics")
        XCTAssertEqual(mail.attachments.first?.mimeType, "text/calendar")
    }

    func testBinaryAttachmentCRLFIsPreservedAndMissingClosingBoundaryRecoversBody() {
        let header = "Content-Type: multipart/mixed; boundary=b\r\n\r\n--b\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=data.bin\r\nContent-Transfer-Encoding: binary\r\n\r\n"
        let payload = Data([0, 13, 10, 255, 13, 10])
        var raw = Data(header.utf8); raw.append(payload)
        raw.append(Data("\r\n--b\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nRecovered body".utf8))
        let mail = MIMEParser.parse(raw, accountID: "synthetic")
        XCTAssertEqual(mail.attachments.first?.data, payload)
        XCTAssertEqual(mail.text, "Recovered body")
    }

    func testNamedInlineHTMLWithNonfirstRelatedRootRemainsBody() {
        let raw = """
        Content-Type: multipart/related; boundary=related; start="<body>"

        --related
        Content-Type: image/png; name=logo.png
        Content-ID: <logo>
        Content-Transfer-Encoding: base64

        AQID
        --related
        Content-Type: text/html; name=body.html; charset=utf-8
        Content-ID: <body>
        Content-Disposition: inline; filename=body.html

        <p>Message<img src="cid:logo"></p>
        --related--
        """
        let mail = MIMEParser.parse(Data(raw.utf8), accountID: "synthetic")
        XCTAssertTrue(mail.html.contains("cid:logo"))
        XCTAssertEqual(mail.attachments.count, 1)
        XCTAssertEqual(mail.attachments.first?.contentID, "logo")
        XCTAssertEqual(mail.attachments.first?.data, Data([1, 2, 3]))
    }

    func testRichAlternativeUsesOnlySelectedVersionsCIDFiles() {
        let raw = """
        Content-Type: multipart/alternative; boundary=choice

        --choice
        Content-Type: multipart/related; boundary=old

        --old
        Content-Type: text/html

        <p>Old<img src="cid:logo"></p>
        --old
        Content-Type: image/png; name=logo.png
        Content-ID: <logo>
        Content-Transfer-Encoding: base64

        AQID
        --old--
        --choice
        Content-Type: multipart/related; boundary=new

        --new
        Content-Type: text/html

        <p>Current<img src="cid:logo"></p>
        --new
        Content-Type: image/png; name=logo.png
        Content-ID: <logo>
        Content-Transfer-Encoding: base64

        BAUG
        --new--
        --choice--
        """
        let mail = MIMEParser.parse(Data(raw.utf8), accountID: "synthetic")
        XCTAssertTrue(mail.html.contains("Current")); XCTAssertFalse(mail.html.contains("Old"))
        XCTAssertEqual(mail.attachments.count, 1)
        XCTAssertEqual(mail.attachments.first?.data, Data([4, 5, 6]))
    }

    func testMixedNewlinesUseFirstHeaderTerminator() {
        let raw = "From: team@example.invalid\nContent-Type: text/plain; charset=utf-8\n\nFirst\n\nSecond\r\n\r\nThird"
        let mail = MIMEParser.parse(Data(raw.utf8), accountID: "synthetic")
        XCTAssertEqual(mail.text, "First\n\nSecond\n\nThird")
    }

    func testCRLFMultipartFramingDoesNotConsumeHeadersOrBase64Padding() {
        let raw = "Content-Type: multipart/mixed; boundary=b\r\n\r\n--b\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\nSGVsbG8=\r\n--b\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=one.bin\r\nContent-Transfer-Encoding: base64\r\n\r\n/w==\r\n--b--\r\n"
        let mail = MIMEParser.parse(Data(raw.utf8), accountID: "synthetic")
        XCTAssertEqual(mail.text, "Hello")
        XCTAssertEqual(mail.attachments.count, 1)
        XCTAssertEqual(mail.attachments.first?.mimeType, "application/octet-stream")
        XCTAssertEqual(mail.attachments.first?.data, Data([255]))
    }

    func testHTMLExtractionSkipsInvisibleCodeAndPreservesTextEntitiesAndColumns() {
        let html = "<html><head><title>Not body</title><style>body {color:red}</style></head><body><!-- hidden --><template>Hidden template</template><script>hidden()</script><h1>Résumé &mdash; &#X1F642;</h1><p><span data-test=\"a>b\">A &amp; B</span><br class=\"line\">Next</p><table><tr><td>One</td><td>Two</td></tr></table><p>&amp;lt;quoted&amp;gt;</p></body></html>"
        let text = MIMEParser.plainText(html)
        XCTAssertTrue(text.contains("Résumé — 🙂")); XCTAssertTrue(text.contains("A & B\nNext"))
        XCTAssertTrue(text.contains("One\tTwo")); XCTAssertTrue(text.contains("&lt;quoted&gt;"))
        XCTAssertFalse(text.contains("Not body")); XCTAssertFalse(text.contains("hidden")); XCTAssertFalse(text.contains("Hidden template")); XCTAssertFalse(text.contains("a>b"))
    }

    func testQuotedPrintableDecodesHexAndSoftBreaksWithoutChangingInvalidEscapes() {
        let decoded = MIMEParser.quotedPrintable(Data("=E4=BD=A0=E5=A5=BD=\r\n=F0=9F=99=82=\n=ZZ".utf8))
        XCTAssertEqual(String(decoding: decoded, as: UTF8.self), "你好🙂=ZZ")
    }
}
