import XCTest
import CoreGraphics
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import MorrowCore
@testable import MorrowApp

final class AttachmentPreviewTests: XCTestCase {
    private func image(_ type: UTType) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 512, height: 256, bitsPerComponent: 8, bytesPerRow: 512 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 512, height: 256))
        let image = try XCTUnwrap(context.makeImage()), data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
    private func pdf() throws -> Data {
        let data = NSMutableData(), consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        var media = CGRect(x: 0, y: 0, width: 300, height: 400)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &media, nil))
        context.beginPDFPage(nil); context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 20, y: 20, width: 120, height: 120)); context.endPDFPage(); context.closePDF()
        return data as Data
    }
    func testPDFOriginalPreviewDoesNotDependOnExtractedText() throws {
        let content = try AttachmentPreviewLoader.decode(pdf(), name: "scan.pdf", mime: "application/pdf")
        guard case .pdf(let document) = content else { return XCTFail("Expected a native PDF") }
        XCTAssertEqual(document.pageCount, 1)
        XCTAssertTrue((document.string ?? "").isEmpty, "Synthetic scan contains graphics, not OCR text")
    }
    func testPNGAndJPEGDecodeTheirOriginalPixelsWithoutOCR() throws {
        for type in [UTType.png, .jpeg] {
            let content = try AttachmentPreviewLoader.decode(image(type), name: "extensionless", mime: "application/octet-stream")
            guard case .image(let bitmap, let width, let height) = content else { return XCTFail("Expected original image") }
            XCTAssertEqual(width, 512); XCTAssertEqual(height, 256)
            XCTAssertLessThanOrEqual(bitmap.width, AttachmentPreviewLoader.maximumDecodeDimension)
            XCTAssertLessThanOrEqual(bitmap.height, AttachmentPreviewLoader.maximumDecodeDimension)
        }
    }
    func testStoredExtensionlessFileAndInlineBytesBothLoadWithoutCopies() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("attachment-preview-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let data = try image(.png), file = root.appendingPathComponent("cached-id")
        try data.write(to: file)
        var stored = MailAttachment(name: "photo.png", mimeType: "image/png", data: Data()); stored.storedPath = file.path
        guard case .image = try await AttachmentPreviewLoader.load(stored) else { return XCTFail("Expected stored image") }
        guard case .image = try await AttachmentPreviewLoader.load(.init(name: "photo.png", mimeType: "image/png", data: data)) else { return XCTFail("Expected inline image") }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["cached-id"])
    }
    func testCorruptOrUnavailableContentFailsInsteadOfLeavingLoadingState() async throws {
        XCTAssertThrowsError(try AttachmentPreviewLoader.decode(Data(), name: "empty.png", mime: "image/png"))
        XCTAssertThrowsError(try AttachmentPreviewLoader.decode(Data("not PDF".utf8), name: "bad.pdf", mime: "application/pdf"))
        XCTAssertThrowsError(try AttachmentPreviewLoader.decode(Data("not an image".utf8), name: "bad.jpg", mime: "image/jpeg"))
        var oversized = MailAttachment(name: "large.pdf", mimeType: "application/pdf", data: Data())
        oversized.byteCount = AttachmentPreviewLoader.maximumBytes + 1; oversized.storedPath = "/does-not-exist"
        do { _ = try await AttachmentPreviewLoader.load(oversized); XCTFail("Expected size rejection") }
        catch AttachmentPreviewFailure.tooLarge { }
        catch { XCTFail("Expected a precise size failure") }
    }
}
