import XCTest
import CoreGraphics
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import MorrowCore
@testable import MorrowApp

final class AttachmentPreviewTests: XCTestCase {
    @MainActor func testMailAttachmentAreaUsesLocalOriginalAndFetchesRemoteOnlyOnExplicitPreview() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reader-preview-" + UUID().uuidString)
        let model = AppModel(root: root); model.settings.enabled = false
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = try image(.png)
        let local = MailAttachment(name: "picture.PNG", mimeType: "application/octet-stream", data: bytes)
        XCTAssertTrue(ReaderAttachmentsView.supportsPreview(local))
        XCTAssertTrue(ReaderAttachmentsView.supportsPreview(.init(name: "scan.pdf", mimeType: "application/octet-stream", data: Data())))
        let resolved = try await model.resolvePreviewAttachment(local)
        XCTAssertEqual(resolved.data, bytes)
        guard case .image = try await AttachmentPreviewLoader.load(resolved) else { return XCTFail("Original image must be previewed") }
        var remote = MailAttachment(name: "remote.png", mimeType: "image/png", data: Data())
        remote.remoteReference = .init(accountID: "fixture", folder: "INBOX", uid: 42, validity: 7, section: "2", encoding: "BASE64", encodedBytes: bytes.count * 2)
        let fixture = PreviewFetchFixture(bytes: bytes)
        model.fetchPreviewAttachmentOverride = { _ in await fixture.fetch() }
        _ = try await AttachmentThumbnailCache.shared.image(remote)
        let untouched = await fixture.count(); XCTAssertEqual(untouched, 0)
        let fetched = try await model.resolvePreviewAttachment(remote)
        XCTAssertEqual(fetched.data, bytes); XCTAssertFalse(fetched.isRemoteOnly)
        let explicit = await fixture.count(); XCTAssertEqual(explicit, 1)
    }
    func testGridUsesSmallImageAndPDFPageThumbnails() throws {
        let inputs: [(Data, String, String)] = [(try image(.png), "image.png", "image/png"), (try image(.jpeg), "image.jpeg", "image/jpeg"), (try pdf(), "document.pdf", "application/pdf")]
        for (data, name, mime) in inputs {
            let thumbnail = try XCTUnwrap(AttachmentThumbnailCache.decode(.init(name: name, mimeType: mime, data: data), pixels: 256))
            XCTAssertLessThanOrEqual(thumbnail.image.width, 256); XCTAssertLessThanOrEqual(thumbnail.image.height, 256)
            XCTAssertLessThanOrEqual(thumbnail.cost, 256 * 256 * 4)
        }
    }
    func testGridCacheBoundsMemoryAndWorkerConcurrency() async throws {
        let cache = AttachmentThumbnailCache(maximumBytes: 256 * 256 * 4)
        let data = try image(.png)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                var attachment = MailAttachment(name: "image-\(i).png", mimeType: "image/png", data: data)
                attachment.contentRevision = "fixture-\(i)"
                let input = attachment
                group.addTask { _ = try await cache.image(input, pixels: 256) }
            }
            try await group.waitForAll()
        }
        XCTAssertLessThanOrEqual(cache.retainedBytes(), 256 * 256 * 4)
        XCTAssertLessThanOrEqual(cache.maximumObservedConcurrency(), 2)
    }
    func testQueuedGridThumbnailCancelsWhenItsViewDisappears() async throws {
        let queue = OperationQueue(); queue.isSuspended = true
        let cache = AttachmentThumbnailCache(queue: queue)
        let attachment = MailAttachment(name: "image.png", mimeType: "image/png", data: try image(.png))
        let task = Task { try await cache.image(attachment) }
        while queue.operationCount == 0 { await Task.yield() }
        task.cancel()
        do { _ = try await task.value; XCTFail("Queued thumbnail did not cancel") }
        catch is CancellationError { }
        catch { XCTFail("Unexpected thumbnail cancellation error") }
        queue.isSuspended = false
        XCTAssertEqual(cache.retainedBytes(), 0)
    }
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
private actor PreviewFetchFixture {
    let bytes: Data
    var requests = 0
    init(bytes: Data) { self.bytes = bytes }
    func fetch() -> Data { requests += 1; return bytes }
    func count() -> Int { requests }
}
