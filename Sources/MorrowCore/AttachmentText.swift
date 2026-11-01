import Foundation
import PDFKit
import Vision
import ImageIO
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

public struct AttachmentText: Codable, Sendable {
    public var text: String
    public var source: String
    public var truncated: Bool
    public var failure: String?
    public init(text: String, source: String, truncated: Bool = false, failure: String? = nil) { self.text = text; self.source = source; self.truncated = truncated; self.failure = failure }
}
private struct AttachmentTextCache: Codable { var fingerprint: String; var result: AttachmentText }

public actor AttachmentTextExtractor {
    public static let shared = AttachmentTextExtractor()
    public static let version = "attachment-text-v2"
    private var tasks: [String: Task<AttachmentText, Never>] = [:]
    public init() {}
    public func extract(_ attachment: MailAttachment, store: MailStore, bytes: Data? = nil, force: Bool = false) async throws -> AttachmentText {
        let data: Data
        if let bytes { data = bytes } else { data = try await store.attachmentData(attachment) }
        let fingerprint = Self.version + ":" + MailStore.hash(data) + ":" + attachment.name + ":" + attachment.mimeType
        if !force, let cache = try await store.object(AttachmentTextCache.self, kind: "attachment-text", id: attachment.id), cache.fingerprint == fingerprint { return cache.result }
        if let task = tasks[fingerprint] {
            let result = await task.value
            // A shared extraction may serve another attachment ID or store.
            // Every caller needs its own durable cache record.
            try await store.save(AttachmentTextCache(fingerprint: fingerprint, result: result), kind: "attachment-text", id: attachment.id)
            return result
        }
        let task = Task.detached(priority: .utility) { Self.read(data, name: attachment.name, mime: attachment.mimeType) }
        tasks[fingerprint] = task
        let result = await task.value; tasks[fingerprint] = nil
        try await store.save(AttachmentTextCache(fingerprint: fingerprint, result: result), kind: "attachment-text", id: attachment.id)
        return result
    }
    public static func read(_ data: Data, name: String, mime: String) -> AttachmentText {
        guard data.count <= 32 * 1024 * 1024 else { return .init(text: "", source: "未提取", failure: "附件超过32 MB，请拆分后提取文字。") }
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        do {
            if mime == "application/pdf" || ext == "pdf" { return try pdf(data) }
            if mime.hasPrefix("image/") || ["png", "jpg", "jpeg", "tiff", "heic", "webp"].contains(ext) {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                      let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                      width.doubleValue > 0, height.doubleValue > 0, width.doubleValue * height.doubleValue <= 64_000_000 else {
                    throw MailError.message("图片像素超过64 MP或格式无效，已停止文字提取。")
                }
                let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 2048, kCGImageSourceShouldCacheImmediately: true]
                guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw MailError.message("图片无法在文字提取预算内解码。") }
                let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.recognitionLanguages = ["zh-Hans", "en-US"]; request.usesLanguageCorrection = true
                try VNImageRequestHandler(cgImage: image).perform([request])
                let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                return bounded(text, source: "本机 OCR")
            }
            if ["docx", "xlsx", "pptx", "odt", "ods", "odp"].contains(ext) { return try office(data, ext: ext) }
            if ext == "rtf", let attributed = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) { return bounded(attributed.string, source: "RTF") }
            if mime.hasPrefix("text/") || ["txt", "md", "csv", "tsv", "json", "xml", "ics", "log"].contains(ext) { return bounded(MIMEParser.decode(data, charset: "utf-8"), source: "文本") }
            return .init(text: "", source: "未提取", failure: "此附件格式暂无文字提取器，可保存或用对应应用打开。")
        } catch { return .init(text: "", source: "未提取", failure: error.localizedDescription) }
    }
    private static func bounded(_ text: String, source: String, truncated: Bool = false) -> AttachmentText {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(text: String(trimmed.prefix(100000)), source: source, truncated: truncated || trimmed.count > 100000, failure: trimmed.isEmpty ? "未找到可提取文字。" : nil)
    }
    private static func pdf(_ data: Data) throws -> AttachmentText {
        guard let document = PDFDocument(data: data), !document.isLocked else { throw MailError.message("PDF无法读取或已加密，请先解锁文件。") }
        var parts: [String] = []; var scanned = 0; var skipped = false
        for i in 0..<min(document.pageCount, 100) {
            guard let page = document.page(at: i) else { continue }
            var text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if text.count < 5 {
                if scanned >= 5 { skipped = true; continue }
                scanned += 1
                let image = page.thumbnail(of: CGSize(width: 1600, height: 2000), for: .mediaBox)
                #if canImport(AppKit)
                let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
                #else
                let bitmap = image.cgImage
                #endif
                if let cgImage = bitmap {
                    let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.recognitionLanguages = ["zh-Hans", "en-US"]; request.usesLanguageCorrection = true
                    try VNImageRequestHandler(cgImage: cgImage).perform([request])
                    text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                }
            }
            if !text.isEmpty { parts.append("第\(i + 1)页\n" + text) }
        }
        return bounded(parts.joined(separator: "\n\n"), source: scanned > 0 ? "PDF 与本机 OCR" : "PDF 文字", truncated: document.pageCount > 100 || skipped)
    }
    private static func office(_ data: Data, ext: String) throws -> AttachmentText {
        #if os(iOS)
        let archive = try OfficeZIP.entries(data)
        let names = archive.map(\.name)
        #else
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MorrowExtract-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("document.zip"); try data.write(to: file); try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let names = String(decoding: try unzip(file, arguments: ["-Z1"], maxBytes: 2 * 1024 * 1024), as: UTF8.self).components(separatedBy: .newlines)
        #endif
        let paths: [String]
        switch ext {
        case "docx": paths = names.filter { ["word/document.xml", "word/footnotes.xml", "word/endnotes.xml"].contains($0) || (($0.hasPrefix("word/header") || $0.hasPrefix("word/footer")) && $0.hasSuffix(".xml")) }
        case "xlsx": paths = names.filter { $0 == "xl/sharedStrings.xml" || ($0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml")) }.sorted()
        case "pptx": paths = names.filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") && !$0.contains("/_rels/") }.sorted { naturalOrder($0) < naturalOrder($1) }
        default: paths = names.filter { $0 == "content.xml" }
        }
        guard !paths.isEmpty else { throw MailError.message("文件没有可识别的Office正文，或文档已加密。") }
        var texts: [String] = []; var sharedStrings: [String] = []; var totalCharacters = 0; var cut = paths.count > 100
        for path in paths.prefix(100) {
            #if os(iOS)
            guard let entry = archive.first(where: { $0.name == path }) else { continue }
            let xml = try OfficeZIP.read(entry, data: data, maxBytes: 8 * 1024 * 1024)
            #else
            let xml = try unzip(file, arguments: ["-p"], entry: path, maxBytes: 8 * 1024 * 1024)
            #endif
            if ext == "xlsx" {
                let reader = SpreadsheetXML(sharedStrings: sharedStrings, collectingStrings: path == "xl/sharedStrings.xml")
                let parser = XMLParser(data: xml); parser.shouldResolveExternalEntities = false; parser.delegate = reader
                guard parser.parse() else { throw MailError.message("电子表格正文XML无法解析。") }
                if path == "xl/sharedStrings.xml" { sharedStrings = reader.strings } else { texts.append(path + "\n" + reader.rows.joined(separator: "\n")) }
            } else {
                var value = String(decoding: xml, as: UTF8.self)
                for marker in ["</w:p>", "</a:p>", "</text:p>", "</text:h>"] { value = value.replacingOccurrences(of: marker, with: "\n") }
                value = value.replacingOccurrences(of: "</w:tc>", with: "\t").replacingOccurrences(of: "<text:tab/>", with: "\t")
                texts.append(MIMEParser.plainText(value))
            }
            totalCharacters = texts.reduce(0) { $0 + $1.count }
            if totalCharacters >= 100000 { cut = true; break }
        }
        return bounded(texts.joined(separator: "\n\n"), source: ext.uppercased() + " 文字", truncated: cut)
    }
    private static func naturalOrder(_ path: String) -> Int { Int(path.filter(\.isNumber)) ?? 0 }
    #if os(macOS)
    private static func unzip(_ file: URL, arguments: [String], entry: String? = nil, maxBytes: Int) throws -> Data {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = arguments + [file.path] + (entry.map { [$0] } ?? [])
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }; DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeout); defer { timeout.cancel() }
        var output = Data()
        while let chunk = try pipe.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty {
            output.append(chunk)
            if output.count > maxBytes { process.terminate(); process.waitUntilExit(); throw MailError.message("文档展开内容超过提取限制，请拆分文件。") }
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw MailError.message("Office文档无法展开或提取超时。") }; return output
    }
    #endif
}

private final class SpreadsheetXML: NSObject, XMLParserDelegate {
    let sharedStrings: [String]; let collectingStrings: Bool
    var strings: [String] = []; var rows: [String] = []; private var current = ""; private var cellType = ""; private var cell = ""; private var row: [String] = []; private var reading = false; private var column = 0
    init(sharedStrings: [String], collectingStrings: Bool) { self.sharedStrings = sharedStrings; self.collectingStrings = collectingStrings }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if name == "si" { current = "" }; if name == "row" { row = [] }; if name == "c" { cellType = attributes["t"] ?? ""; cell = ""; column = attributes["r"].map { $0.prefix(while: \.isLetter).uppercased().unicodeScalars.reduce(0) { $0 * 26 + Int($1.value) - 64 } - 1 } ?? row.count }
        if name == "t" || name == "v" { reading = true }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if reading { if collectingStrings { current += string } else { cell += string } } }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "t" || name == "v" { reading = false }
        if name == "si" { strings.append(current) }
        if name == "c" { while row.count < min(16384, max(0, column)) { row.append("") }; if cellType == "s", let index = Int(cell), sharedStrings.indices.contains(index) { row.append(sharedStrings[index]) } else { row.append(cell) } }
        if name == "row" { rows.append(row.joined(separator: "\t")) }
    }
}
