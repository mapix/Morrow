import Foundation
import CoreGraphics
import ImageIO
import MorrowCore

struct AttachmentThumbnail: @unchecked Sendable {
    let image: CGImage
    var cost: Int { image.bytesPerRow * image.height }
}

/// Small display thumbnails only. Originals never enter this cache, and no
/// preview files are copied to disk. Operation cancellation covers queued work.
final class AttachmentThumbnailCache: @unchecked Sendable {
    static let shared = AttachmentThumbnailCache()
    static let maximumFileBytes = 64 * 1024 * 1024
    static let maximumPixels = 384
    private final class Box { let value: AttachmentThumbnail; init(_ value: AttachmentThumbnail) { self.value = value } }
    private let cache = NSCache<NSString, Box>()
    private let queue: OperationQueue
    private let lock = NSLock()
    private let budget: Int
    private var order: [String] = []
    private var costs: [String: Int] = [:]
    private var retained = 0
    private var active = 0
    private var peakActive = 0

    init(maximumBytes: Int = 32 * 1024 * 1024, queue: OperationQueue = OperationQueue()) {
        budget = max(0, maximumBytes); self.queue = queue
        cache.totalCostLimit = budget; cache.countLimit = 256
        queue.maxConcurrentOperationCount = 2; queue.qualityOfService = .utility
    }
    func image(_ attachment: MailAttachment, pixels: Int = 256) async throws -> AttachmentThumbnail? {
        try Task.checkCancellation()
        let pixels = min(Self.maximumPixels, max(1, pixels))
        let key = Self.key(attachment, pixels: pixels)
        if let value = cached(key) { return value }
        let gate = ThumbnailRequest()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard gate.install(continuation) else { return }
                let operation = BlockOperation()
                operation.addExecutionBlock { [weak self, weak operation] in
                    guard let self, let operation, !operation.isCancelled else { gate.finish(.failure(CancellationError())); return }
                    self.enter(); defer { self.leave() }
                    do {
                        let value = try Self.decode(attachment, pixels: pixels)
                        guard !operation.isCancelled else { throw CancellationError() }
                        if let value { self.store(value, key: key) }
                        gate.finish(.success(value))
                    } catch { gate.finish(.failure(error)) }
                }
                gate.attach(operation)
                queue.addOperation(operation)
            }
        } onCancel: { gate.cancel() }
    }
    private static func key(_ attachment: MailAttachment, pixels: Int) -> String {
        let revision = attachment.contentRevision ?? (attachment.data.isEmpty ? "" : MailStore.hash(attachment.data))
        let fileStamp = attachment.storedPath.flatMap { try? URL(fileURLWithPath: $0).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) }
        return [attachment.id, revision, attachment.storedPath ?? "", String(fileStamp?.fileSize ?? attachment.data.count), String(describing: fileStamp?.contentModificationDate), attachment.mimeType, attachment.name, String(pixels)].joined(separator: ":")
    }
    private func cached(_ key: String) -> AttachmentThumbnail? {
        lock.lock(); defer { lock.unlock() }
        guard let box = cache.object(forKey: key as NSString) else {
            if let cost = costs.removeValue(forKey: key) { retained -= cost; order.removeAll { $0 == key } }
            return nil
        }
        order.removeAll { $0 == key }; order.append(key); return box.value
    }
    private func store(_ value: AttachmentThumbnail, key: String) {
        lock.lock(); defer { lock.unlock() }
        guard value.cost <= budget else { return }
        if let old = costs.removeValue(forKey: key) { retained -= old; order.removeAll { $0 == key } }
        while !order.isEmpty && (retained + value.cost > budget || order.count >= 256) {
            let oldest = order.removeFirst(); retained -= costs.removeValue(forKey: oldest) ?? 0; cache.removeObject(forKey: oldest as NSString)
        }
        costs[key] = value.cost; retained += value.cost; order.append(key)
        cache.setObject(Box(value), forKey: key as NSString, cost: value.cost)
    }
    private func enter() { lock.lock(); active += 1; peakActive = max(peakActive, active); lock.unlock() }
    private func leave() { lock.lock(); active -= 1; lock.unlock() }
    func retainedBytes() -> Int { lock.lock(); defer { lock.unlock() }; return retained }
    func maximumObservedConcurrency() -> Int { lock.lock(); defer { lock.unlock() }; return peakActive }

    static func decode(_ attachment: MailAttachment, pixels: Int) throws -> AttachmentThumbnail? {
        guard max(attachment.byteCount, attachment.data.count) <= maximumFileBytes else { return nil }
        let limit = min(maximumPixels, max(1, pixels))
        let url: URL?
        let bytes: Data?
        if !attachment.data.isEmpty { bytes = attachment.data; url = nil }
        else if let path = attachment.storedPath {
            let file = URL(fileURLWithPath: path)
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let size = values.fileSize, size <= maximumFileBytes else { return nil }
            url = file; bytes = nil
        } else { return nil }
        let prefix: Data
        if let bytes { prefix = Data(bytes.prefix(5)) }
        else if let url { let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }; prefix = try file.read(upToCount: 5) ?? Data() }
        else { return nil }
        let ext = URL(fileURLWithPath: attachment.name).pathExtension.lowercased()
        if attachment.mimeType.lowercased() == "application/pdf" || ext == "pdf" || prefix == Data("%PDF-".utf8) {
            let document: CGPDFDocument?
            if let url { document = CGPDFDocument(url as CFURL) }
            else if let bytes, let provider = CGDataProvider(data: bytes as CFData) { document = CGPDFDocument(provider) }
            else { return nil }
            guard let document, document.isUnlocked, let page = document.page(at: 1) else { return nil }
            let box = page.getBoxRect(.mediaBox)
            guard box.width > 0, box.height > 0, box.width.isFinite, box.height.isFinite else { return nil }
            let scale = CGFloat(limit) / max(box.width, box.height)
            let width = max(1, Int((box.width * scale).rounded())), height = max(1, Int((box.height * scale).rounded()))
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            let target = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(target)
            context.concatenate(page.getDrawingTransform(.mediaBox, rect: target, rotate: 0, preserveAspectRatio: true)); context.drawPDFPage(page)
            return context.makeImage().map { AttachmentThumbnail(image: $0) }
        }
        let source: CGImageSource?
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        if let url { source = CGImageSourceCreateWithURL(url as CFURL, options) }
        else if let bytes { source = CGImageSourceCreateWithData(bytes as CFData, options) }
        else { return nil }
        guard let source,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue * height.doubleValue <= 64_000_000 else { return nil }
        let thumbnailOptions: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: limit, kCGImageSourceShouldCacheImmediately: true]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary).map { AttachmentThumbnail(image: $0) }
    }
}

private final class ThumbnailRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<AttachmentThumbnail?, Error>?
    private var result: Result<AttachmentThumbnail?, Error>?
    private weak var operation: Operation?
    func install(_ value: CheckedContinuation<AttachmentThumbnail?, Error>) -> Bool {
        lock.lock(); if let result { lock.unlock(); value.resume(with: result); return false }
        continuation = value; lock.unlock(); return true
    }
    func attach(_ value: Operation) { lock.lock(); operation = value; let completed = result != nil; lock.unlock(); if completed { value.cancel() } }
    func cancel() { lock.lock(); let work = operation; lock.unlock(); work?.cancel(); finish(.failure(CancellationError())) }
    func finish(_ value: Result<AttachmentThumbnail?, Error>) {
        lock.lock(); guard result == nil else { lock.unlock(); return }; result = value
        let caller = continuation; continuation = nil; lock.unlock(); caller?.resume(with: value)
    }
}
