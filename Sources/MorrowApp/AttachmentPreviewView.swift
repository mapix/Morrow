import AppKit
import SwiftUI
import PDFKit
import ImageIO
import MorrowCore

enum AttachmentPreviewFailure: Error, LocalizedError {
    case empty, tooLarge, unavailable, unsupported, damagedPDF, lockedPDF, imageTooLarge
    var errorDescription: String? {
        switch self {
        case .empty: return AttachmentPreviewWords.text("附件没有可预览的内容。", "The attachment has no previewable content.", "添付ファイルにプレビューできる内容がありません。")
        case .tooLarge: return AttachmentPreviewWords.text("附件超过 64 MB 预览限制，请保存后用对应应用打开。", "This attachment exceeds the 64 MB preview limit. Save it and open it in its application.", "添付ファイルは64 MBのプレビュー制限を超えています。保存して対応するアプリで開いてください。")
        case .unavailable: return AttachmentPreviewWords.text("附件文件在本机不可用，请重新同步邮件后重试。", "The attachment is unavailable locally. Sync the message and try again.", "添付ファイルがこの端末にありません。メールを同期して再試行してください。")
        case .unsupported: return AttachmentPreviewWords.text("此格式暂无原件预览。可以保存文件，或查看提取文字。", "An original preview is unavailable for this format. Save the file or view its extracted text.", "この形式は原本をプレビューできません。保存するか、抽出したテキストを表示してください。")
        case .damagedPDF: return AttachmentPreviewWords.text("PDF 无法读取，文件可能已损坏。", "The PDF could not be read and may be damaged.", "PDFを読み取れません。ファイルが破損している可能性があります。")
        case .lockedPDF: return AttachmentPreviewWords.text("PDF 已加密，请保存后在系统预览中解锁。", "The PDF is encrypted. Save it and unlock it in Preview.", "PDFは暗号化されています。保存してプレビューアプリでロックを解除してください。")
        case .imageTooLarge: return AttachmentPreviewWords.text("图片分辨率超过预览限制，请保存后用对应应用打开。", "The image resolution exceeds the preview limit. Save it and open it in its application.", "画像の解像度はプレビュー制限を超えています。保存して対応するアプリで開いてください。")
        }
    }
}

enum AttachmentPreviewWords {
    static func text(_ chinese: String, _ english: String, _ japanese: String) -> String {
        L10n.languageCode == "zh-Hans" ? chinese : L10n.languageCode == "ja" ? japanese : english
    }
}

/// A prepared object is handed off once from the decode worker to the UI.
/// PDFDocument and CGImage are never mutated by the worker after this handoff.
enum PreparedAttachmentPreview: @unchecked Sendable {
    case pdf(PDFDocument)
    case image(CGImage, width: Int, height: Int)
}

enum AttachmentPreviewLoader {
    static let maximumBytes = 64 * 1024 * 1024
    static let maximumImagePixels = 64_000_000
    static let maximumDecodeDimension = 4096

    static func load(_ attachment: MailAttachment) async throws -> PreparedAttachmentPreview {
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let data: Data
            guard max(attachment.byteCount, attachment.data.count) <= maximumBytes else { throw AttachmentPreviewFailure.tooLarge }
            if !attachment.data.isEmpty { data = attachment.data }
            else if let path = attachment.storedPath {
                let url = URL(fileURLWithPath: path)
                guard FileManager.default.fileExists(atPath: url.path) else { throw AttachmentPreviewFailure.unavailable }
                if let length = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, length > maximumBytes { throw AttachmentPreviewFailure.tooLarge }
                do { data = try BoundedFileReader.read(url, maximumBytes: maximumBytes) }
                catch { throw AttachmentPreviewFailure.unavailable }
            } else { throw AttachmentPreviewFailure.empty }
            try Task.checkCancellation()
            return try decode(data, name: attachment.name, mime: attachment.mimeType)
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    static func decode(_ data: Data, name: String, mime: String) throws -> PreparedAttachmentPreview {
        guard !data.isEmpty else { throw AttachmentPreviewFailure.empty }
        guard data.count <= maximumBytes else { throw AttachmentPreviewFailure.tooLarge }
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        if mime.lowercased() == "application/pdf" || ext == "pdf" || data.starts(with: Data("%PDF-".utf8)) {
            guard let document = PDFDocument(data: data) else { throw AttachmentPreviewFailure.damagedPDF }
            guard !document.isLocked else { throw AttachmentPreviewFailure.lockedPDF }
            guard document.pageCount > 0 else { throw AttachmentPreviewFailure.damagedPDF }
            return .pdf(document)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { throw AttachmentPreviewFailure.unsupported }
        guard width.doubleValue > 0, height.doubleValue > 0,
              width.doubleValue * height.doubleValue <= Double(maximumImagePixels) else { throw AttachmentPreviewFailure.imageTooLarge }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                      kCGImageSourceCreateThumbnailWithTransform: true,
                                      kCGImageSourceThumbnailMaxPixelSize: maximumDecodeDimension,
                                      kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw AttachmentPreviewFailure.unsupported }
        return .image(image, width: width.intValue, height: height.intValue)
    }
}

struct AttachmentPreviewView: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let attachment: MailAttachment
    @State private var content: PreparedAttachmentPreview?
    @State private var failure: String?
    @State private var loading = true
    @State private var imageZoom: CGFloat = 1
    @State private var pdfZoom = 0
    @State private var pdfFit = 0
    private var displayName: String { attachment.name.isEmpty ? AttachmentPreviewWords.text("未命名附件", "Unnamed attachment", "名前のない添付ファイル") : attachment.name }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(displayName).font(Theme.heading).lineLimit(1).help(displayName)
                    Text(details).font(Theme.label).foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 12)
                Button { zoom(-1) } label: { Image(systemName: "minus.magnifyingglass") }.buttonStyle(IconButtonStyle()).help(AttachmentPreviewWords.text("缩小", "Zoom out", "縮小")).disabled(content == nil)
                Button { zoom(1) } label: { Image(systemName: "plus.magnifyingglass") }.buttonStyle(IconButtonStyle()).help(AttachmentPreviewWords.text("放大", "Zoom in", "拡大")).disabled(content == nil)
                Button(AttachmentPreviewWords.text("适合窗口", "Fit", "ウィンドウに合わせる")) { imageZoom = 1; pdfFit += 1 }.buttonStyle(QuietButtonStyle()).disabled(content == nil)
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(IconButtonStyle()).help(L10n.t("关闭"))
            }.padding(20)
            Divider().overlay(Theme.rule)
            ZStack {
                Theme.sheet
                if loading { ProgressView(AttachmentPreviewWords.text("正在加载原件…", "Loading original…", "原本を読み込み中…")).font(Theme.label) }
                else if let failure { Text(failure).font(Theme.body).foregroundStyle(Theme.secondary).multilineTextAlignment(.center).padding(32) }
                else if let content {
                    switch content {
                    case .pdf(let document): NativeAttachmentPDFView(document: document, zoomCommand: pdfZoom, fitCommand: pdfFit).accessibilityIdentifier("attachment.preview.pdf")
                    case .image(let image, _, _): AttachmentImageCanvas(image: image, zoom: imageZoom).accessibilityIdentifier("attachment.preview.image")
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().overlay(Theme.rule)
            HStack {
                Button(L10n.t("查看提取文字")) { dismiss(); Task { await model.previewText(attachment) } }.buttonStyle(QuietButtonStyle())
                Button(L10n.t("让伙伴分析")) { dismiss(); model.analyzeSelectedAttachments() }.buttonStyle(QuietButtonStyle())
                Spacer()
                Button(L10n.t("保存附件…")) { Task { await model.attachment(attachment, save: true) } }.buttonStyle(CompactButtonStyle())
            }.padding(20)
        }.frame(minWidth: 700, idealWidth: 960, minHeight: 560, idealHeight: 760).background(Theme.paper)
            .accessibilityIdentifier("attachment.preview")
            .task(id: attachment.id + ":" + (attachment.contentRevision ?? "")) {
                loading = true; failure = nil; content = nil; imageZoom = 1
                do {
                    let result = try await AttachmentPreviewLoader.load(attachment)
                    guard !Task.isCancelled else { return }; content = result; loading = false
                } catch { if !Task.isCancelled { failure = error.localizedDescription; loading = false } }
            }.onDisappear { content = nil }
    }
    private var details: String {
        switch content {
        case .pdf(let document): return "PDF · " + AttachmentPreviewWords.text("\(document.pageCount) 页", "\(document.pageCount) pages", "\(document.pageCount) ページ") + " · " + attachment.size
        case .image(_, let width, let height): return "\(width) × \(height) · " + attachment.size
        case nil: return attachment.size
        }
    }
    private func zoom(_ direction: Int) {
        if case .pdf = content { pdfZoom += direction }
        else { imageZoom = min(4, max(0.25, imageZoom * (direction > 0 ? 1.25 : 0.8))) }
    }
}

private struct NativeAttachmentPDFView: NSViewRepresentable {
    let document: PDFDocument
    let zoomCommand: Int
    let fitCommand: Int
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePageContinuous; view.displayDirection = .vertical
        view.displaysPageBreaks = true; view.backgroundColor = NSColor(Theme.sheet)
        view.minScaleFactor = 0.1; view.maxScaleFactor = 8; view.document = document; view.autoScales = true
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document; view.autoScales = true }
        if context.coordinator.fit != fitCommand { view.autoScales = true; context.coordinator.fit = fitCommand }
        if context.coordinator.zoom != zoomCommand {
            if zoomCommand > context.coordinator.zoom { view.zoomIn(nil) } else { view.zoomOut(nil) }
            context.coordinator.zoom = zoomCommand
        }
    }
    static func dismantleNSView(_ view: PDFView, coordinator: Coordinator) { view.document = nil }
    final class Coordinator { var zoom = 0; var fit = 0 }
}

private struct AttachmentImageCanvas: View {
    let image: CGImage
    let zoom: CGFloat
    var body: some View {
        GeometryReader { geometry in
            let ratio = min(max(1, geometry.size.width - 32) / CGFloat(image.width), max(1, geometry.size.height - 32) / CGFloat(image.height))
            ScrollView([.horizontal, .vertical]) {
                Image(decorative: image, scale: 1).resizable().interpolation(.high)
                    .frame(width: CGFloat(image.width) * ratio * zoom, height: CGFloat(image.height) * ratio * zoom)
                    .padding(16).frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
            }
        }
    }
}
