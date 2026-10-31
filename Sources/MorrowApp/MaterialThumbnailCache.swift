import Foundation
import CoreGraphics
import ImageIO
import MorrowCore

struct MaterialThumbnail: @unchecked Sendable {
    var image: CGImage
    var cost: Int { image.bytesPerRow * image.height }
}

actor MaterialThumbnailCache {
    static let shared = MaterialThumbnailCache()
    private struct Entry { var key: String; var value: MaterialThumbnail }
    private var entries: [Entry] = []
    private var retained = 0
    private let maximumBytes: Int
    init(maximumBytes: Int = 8 * 1024 * 1024) { self.maximumBytes = maximumBytes }
    func image(path: String, workspace: URL, maximumPixels: Int) throws -> MaterialThumbnail? {
        try Task.checkCancellation()
        let root = workspace.standardizedFileURL.resolvingSymlinksInPath()
        let proposed = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
        let url = proposed.standardizedFileURL.resolvingSymlinksInPath()
        guard ["chat-assets", "cloud-materials"].contains(where: { url.path.hasPrefix(root.appendingPathComponent($0).path + "/") }) else { return nil }
        let metadata = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard let size = metadata.fileSize, size <= 32 * 1024 * 1024 else { return nil }
        let key = url.path + ":" + String(size) + ":" + String(describing: metadata.contentModificationDate) + ":" + String(maximumPixels)
        if let index = entries.firstIndex(where: { $0.key == key }) { let entry = entries.remove(at: index); entries.append(entry); return entry.value }
        let bytes = try BoundedFileReader.read(url, maximumBytes: 32 * 1024 * 1024)
        guard let thumbnail = Self.decode(bytes, maximumPixels: maximumPixels) else { return nil }
        try Task.checkCancellation()
        if thumbnail.cost <= maximumBytes {
            while !entries.isEmpty && (retained + thumbnail.cost > maximumBytes || entries.count >= 32) { retained -= entries.removeFirst().value.cost }
            entries.append(Entry(key: key, value: thumbnail)); retained += thumbnail.cost
        }
        return thumbnail
    }
    static func decode(_ data: Data, maximumPixels: Int) -> MaterialThumbnail? {
        guard maximumPixels > 0,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue * height.doubleValue <= 64_000_000 else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                      kCGImageSourceThumbnailMaxPixelSize: maximumPixels, kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return MaterialThumbnail(image: image)
    }
    func retainedBytes() -> Int { retained }
}
