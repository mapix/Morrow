import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import MorrowApp

final class MaterialThumbnailTests: XCTestCase {
    private func png() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1024, height: 512, bitsPerComponent: 8, bytesPerRow: 4096,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1024, height: 512))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
    func testThumbnailIsDecodedAtDisplayResolutionInsteadOfOriginalPixels() throws {
        let thumbnail = try XCTUnwrap(MaterialThumbnailCache.decode(png(), maximumPixels: 64))
        XCTAssertLessThanOrEqual(thumbnail.image.width, 64)
        XCTAssertLessThanOrEqual(thumbnail.image.height, 64)
        XCTAssertLessThanOrEqual(thumbnail.cost, 64 * 64 * 4)
    }
    func testThumbnailCacheIsBoundedAndDoesNotReadOutsideWorkspaceAssets() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("thumbnail-assets-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = root.appendingPathComponent("chat-assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try png().write(to: assets.appendingPathComponent("synthetic.png"))
        let cache = MaterialThumbnailCache(maximumBytes: 16_384)
        for size in [32, 64, 128, 256] { _ = try await cache.image(path: "chat-assets/synthetic.png", workspace: root, maximumPixels: size) }
        let retained = await cache.retainedBytes(); XCTAssertLessThanOrEqual(retained, 16_384)
        let outside = try await cache.image(path: "../outside.png", workspace: root, maximumPixels: 64)
        XCTAssertNil(outside)
    }
}
