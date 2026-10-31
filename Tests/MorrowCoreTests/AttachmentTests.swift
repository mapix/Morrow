import XCTest
import CoreGraphics
import CoreText
import AppKit
import MLX
@testable import MorrowCore

final class AttachmentTests: XCTestCase {
    func testLiveAgreementUsesConstrainedFieldsForActualIntent() async throws {
        guard ProcessInfo.processInfo.environment["MORROW_LIVE_AGENT"] == "1" else { throw XCTSkip("Enabled for live inference") }
        var settings = AgentSettings(); settings.provider = "ollama"; settings.model = "qwen3.8:27b-mlx"
        let agreement = try await PartnerEngine().proposeAgreement("持续关注合同对比相关邮件，整理条款变化和需要核实的事项。完成条件是客户确认最终条款。只准备简报与回复草稿，不发送邮件、不签署、不代表我作同意或拒绝决定。", mails: [], settings: settings)
        XCTAssertFalse(agreement.goal.isEmpty); XCTAssertFalse(agreement.doneWhen.isEmpty); XCTAssertFalse(agreement.scope.isEmpty); XCTAssertFalse(agreement.boundaries.isEmpty); XCTAssertFalse(agreement.steps.isEmpty); XCTAssertTrue((1...168).contains(agreement.intervalHours))
    }
    func testLiveVectorRetrievalFindsOfficeAttachmentContent() async throws {
        guard ProcessInfo.processInfo.environment["MORROW_LIVE_EMBEDDINGS"] == "1", let metal = ProcessInfo.processInfo.environment["MORROW_TEST_METALLIB"] else { throw XCTSkip("Enabled for the live model gate") }
        GPU.metallib = URL(fileURLWithPath: metal)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let store = try MailStore(root: root); let engine = EmbeddingIndex()
        try await engine.load(directory: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Morrow/models/embeddinggemma-2").path)
        let data = try zip(["word/document.xml": "<w:document xmlns:w=\"urn:word\"><w:body><w:p><w:r><w:t>补充合同的违约金金额为12000元，请在审核时核对付款条款。</w:t></w:r></w:p></w:body></w:document>"])
        var mail = MailMessage(accountID: "test", from: .init(email: "sender@example.com"), subject: "资料", text: "见附件。")
        mail.attachments = [.init(name: "terms.docx", mimeType: "application/octet-stream", data: data)]; mail = try await store.upsert(mail)
        let other = try await store.upsert(MailMessage(accountID: "test", from: .init(email: "other@example.com"), subject: "周末", text: "周末在公园徒步，记得带水。"))
        _ = try await engine.index(mail, store: store, attachments: true); _ = try await engine.index(other, store: store, attachments: true)
        let hits = try await engine.search("合同违约金与付款条款", store: store)
        XCTAssertEqual(hits.first?.id, mail.id); XCTAssertTrue(hits.first?.snippet.contains("12000") ?? false)
    }
    func testLiveLongMailAnalysisReadsCriticalFooter() async throws {
        guard ProcessInfo.processInfo.environment["MORROW_LIVE_AGENT"] == "1" else { throw XCTSkip("Enabled for live inference") }
        var settings = AgentSettings(); settings.provider = "ollama"; settings.model = "qwen3.8:27b-mlx"
        let mail = MailMessage(accountID: "test", from: .init(email: "sender@example.com"), subject: "项目背景", text: String(repeating: "此段是项目背景记录，不包含待办请求。\n", count: 800) + "\n最终要求：请审核补充发票并回复，最新总额是7800元，以本段为准。")
        let analysis = try await PartnerEngine().analyze(mail, settings: settings)
        XCTAssertTrue(analysis.needsReply); XCTAssertNotNil(analysis.action)
        XCTAssertTrue((analysis.summary + analysis.reasoning + (analysis.action ?? "")).contains("发票"))
    }
    private func zip(_ files: [String: String]) throws -> Data {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, text) in files { let url = folder.appendingPathComponent(name); try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true); try Data(text.utf8).write(to: url) }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); process.currentDirectoryURL = folder; process.arguments = ["-q", "-r", "fixture.zip"] + files.keys.sorted(); try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        return try Data(contentsOf: folder.appendingPathComponent("fixture.zip"))
    }
    func testOfficeWordAndSpreadsheetActualZipExtraction() throws {
        let document = try zip(["word/document.xml": "<w:document xmlns:w=\"urn:word\"><w:body><w:p><w:r><w:t>合同审核与发票</w:t></w:r></w:p><w:p><w:r><w:t>请在周五确认 &amp; 回复</w:t></w:r></w:p></w:body></w:document>"])
        let text = AttachmentTextExtractor.read(document, name: "contract.docx", mime: "application/vnd.openxmlformats-officedocument.wordprocessingml.document")
        XCTAssertNil(text.failure); XCTAssertTrue(text.text.contains("合同审核与发票")); XCTAssertTrue(text.text.contains("确认 & 回复"))
        let sheet = try zip(["xl/sharedStrings.xml": "<sst><si><t>客户</t></si><si><t>金额</t></si><si><t>Example Company</t></si></sst>", "xl/worksheets/sheet1.xml": "<worksheet><sheetData><row r=\"1\"><c r=\"A1\" t=\"s\"><v>0</v></c><c r=\"C1\" t=\"s\"><v>1</v></c></row><row r=\"2\"><c r=\"A2\" t=\"s\"><v>2</v></c><c r=\"C2\"><v>4200</v></c></row></sheetData></worksheet>"])
        let table = AttachmentTextExtractor.read(sheet, name: "cost.xlsx", mime: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
        XCTAssertNil(table.failure); XCTAssertTrue(table.text.contains("客户\t\t金额")); XCTAssertTrue(table.text.contains("Example Company\t\t4200"))
    }
    func testZipExpansionIsBounded() throws {
        let data = try zip(["word/document.xml": "<document>" + String(repeating: "a", count: 9 * 1024 * 1024) + "</document>"])
        let result = AttachmentTextExtractor.read(data, name: "oversize.docx", mime: "application/octet-stream")
        XCTAssertNotNil(result.failure); XCTAssertTrue(result.text.isEmpty)
    }
    private func textImage() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1200, height: 400, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1200, height: 400))
        let font = CTFontCreateWithName("Helvetica" as CFString, 58, nil)
        for (i, text) in ["Invoice 4200", "Please confirm the review"].enumerated() {
            let string = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)])
            context.textPosition = CGPoint(x: 40, y: 270 - i * 100); CTLineDraw(CTLineCreateWithAttributedString(string), context)
        }; return try XCTUnwrap(context.makeImage())
    }
    func testRealVisionOCRForImageAndScannedPDF() throws {
        let image = try textImage(); let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        let text = AttachmentTextExtractor.read(png, name: "invoice.png", mime: "image/png")
        XCTAssertNil(text.failure); XCTAssertTrue(text.text.lowercased().contains("invoice")); XCTAssertTrue(text.text.contains("4200"))
        let output = NSMutableData(); let consumer = try XCTUnwrap(CGDataConsumer(data: output)); var box = CGRect(x: 0, y: 0, width: 600, height: 200)
        let pdf = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil)); pdf.beginPDFPage(nil); pdf.draw(image, in: box); pdf.endPDFPage(); pdf.closePDF()
        let scanned = AttachmentTextExtractor.read(output as Data, name: "scan.pdf", mime: "application/pdf")
        XCTAssertNil(scanned.failure); XCTAssertTrue(scanned.source.contains("OCR")); XCTAssertTrue(scanned.text.contains("4200"))
    }
    func testAttachmentEvidenceIsCachedAndIncludesLateContent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let store = try MailStore(root: root)
        var mail = MailMessage(accountID: "test", from: .init(email: "sender@example.com"), subject: "Contract", text: String(repeating: "context ", count: 2000) + "critical footer")
        mail.attachments = [.init(name: "notes.txt", mimeType: "text/plain", data: Data("Please review invoice 4200".utf8))]
        mail = try await store.upsert(mail)
        let evidence = try await MailEvidence.forAnalysis(mail, store: store)
        XCTAssertTrue(evidence.text.contains("critical footer")); XCTAssertTrue(evidence.text.contains("invoice 4200"))
        struct Probe: Decodable { var fingerprint: String; var result: AttachmentText }
        let cached = try await store.object(Probe.self, kind: "attachment-text", id: mail.attachments[0].id); XCTAssertNotNil(cached)
        try await store.deleteMessage(mail.id)
        let removed = try await store.object(Probe.self, kind: "attachment-text", id: mail.attachments[0].id); XCTAssertNil(removed)
    }
}
