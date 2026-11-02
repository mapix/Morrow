import SwiftUI
import UniformTypeIdentifiers
import MorrowCore

extension AppModel {
    /// Called only after the user expands an attachment. No model inference.
    func resolvePreviewAttachment(_ original: MailAttachment) async throws -> MailAttachment {
        guard max(original.byteCount, original.data.count) <= AttachmentPreviewLoader.maximumBytes else { throw AttachmentPreviewFailure.tooLarge }
        var attachment = original
        if original.isRemoteOnly, let reference = original.remoteReference {
            guard reference.encodedBytes > 0, reference.encodedBytes <= 96 * 1024 * 1024 else { throw AttachmentPreviewFailure.tooLarge }
            if let fetchPreviewAttachmentOverride { attachment.data = try await fetchPreviewAttachmentOverride(reference) }
            else {
                guard let account = accounts.first(where: { $0.id == reference.accountID && $0.enabled }) else { throw MailError.message("附件所属邮箱不可用。") }
                let secret = try await credentials.credential(account)
                attachment.data = try await transport.fetchRemoteAttachment(account, reference: reference, password: secret)
            }
        } else { attachment.data = try await store.attachmentData(original, maximumBytes: AttachmentPreviewLoader.maximumBytes) }
        guard attachment.data.count <= AttachmentPreviewLoader.maximumBytes else { throw AttachmentPreviewFailure.tooLarge }
        attachment.byteCount = attachment.data.count
        return attachment
    }
}

struct ReaderAttachmentsView: View {
    let attachments: [MailAttachment]
    @EnvironmentObject private var model: AppModel
    @State private var selectedID: String?
    static func supportsPreview(_ attachment: MailAttachment) -> Bool {
        let mime = attachment.mimeType.lowercased(), ext = URL(fileURLWithPath: attachment.name).pathExtension
        return mime == "application/pdf" || mime.hasPrefix("image/") || ext.lowercased() == "pdf" || UTType(filenameExtension: ext.lowercased())?.conforms(to: .image) == true
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L10n.t("附件") + " · \(attachments.count)", systemImage: "paperclip").font(Theme.label.weight(.medium))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(attachments) { attachment in
                        HStack(spacing: 10) {
                            ReaderAttachmentThumbnail(attachment: attachment).frame(width: 34, height: 34)
                            Button {
                                if Self.supportsPreview(attachment) { selectedID = selectedID == attachment.id ? nil : attachment.id }
                                else { Task { await model.attachment(attachment) } }
                            } label: { Text(attachment.name).font(Theme.label).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain).accessibilityIdentifier("mail.attachment.preview")
                            Text(attachment.size).font(Theme.small).foregroundStyle(Theme.muted)
                            if Self.supportsPreview(attachment) {
                                Button(L10n.t(selectedID == attachment.id ? "收起" : "预览")) { selectedID = selectedID == attachment.id ? nil : attachment.id }.buttonStyle(.link).font(Theme.label)
                            }
                            Menu {
                                Button(L10n.t("保存附件")) { Task { await model.attachment(attachment, save: true) } }
                                Button(L10n.t("查看提取文字")) { Task { await model.previewText(attachment) } }
                            } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28)
                        }.padding(.vertical, 2)
                        if selectedID == attachment.id { InlineMailAttachmentPreview(attachment: attachment) }
                    }
                }
            }
        }.padding(.horizontal, 20).padding(.vertical, 12)
            .frame(height: selectedID == nil ? min(CGFloat(attachments.count) * 46 + 42, 160) : 320)
            .background(Theme.paper).accessibilityIdentifier("mail.attachments")
    }
}

private struct ReaderAttachmentThumbnail: View {
    let attachment: MailAttachment
    @State private var image: AttachmentThumbnail?
    var body: some View {
        Group {
            if let image { Image(decorative: image.image, scale: 2).resizable().scaledToFit() }
            else { Image(systemName: attachment.mimeType == "application/pdf" ? "doc.richtext" : "paperclip").foregroundStyle(Theme.muted) }
        }.task(id: attachment.id + (attachment.contentRevision ?? "")) {
            guard !attachment.isRemoteOnly else { return }
            image = try? await AttachmentThumbnailCache.shared.image(attachment, pixels: 96)
        }.onDisappear { image = nil }
    }
}

private struct InlineMailAttachmentPreview: View {
    let attachment: MailAttachment
    @EnvironmentObject private var model: AppModel
    @State private var content: PreparedAttachmentPreview?
    @State private var resolved: MailAttachment?
    @State private var failure: String?
    @State private var loading = true
    @State private var enlarged = false
    @State private var zoom = 0
    @State private var fit = 0
    @State private var imageZoom: CGFloat = 1
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if loading { ProgressView(L10n.t(attachment.isRemoteOnly ? "正在获取附件…" : "正在准备预览…")).font(Theme.label).padding(12) }
            else if let failure { Text(failure).font(Theme.label).foregroundStyle(Theme.error).textSelection(.enabled) }
            else if let content {
                HStack(spacing: 14) {
                    Button { zoom -= 1; imageZoom = max(0.25, imageZoom / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                    Button { zoom += 1; imageZoom = min(4, imageZoom * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                    Button(L10n.t("适合窗口")) { fit += 1; imageZoom = 1 }
                    Spacer()
                    Button(L10n.t("放大预览")) { enlarged = true }
                }.buttonStyle(.plain).font(Theme.label)
                Group {
                    switch content {
                    case .pdf(let document): NativeAttachmentPDFView(document: document, zoomCommand: zoom, fitCommand: fit).accessibilityIdentifier("mail.attachment.pdf")
                    case .image(let image, _, _): AttachmentImageCanvas(image: image, zoom: imageZoom).accessibilityIdentifier("mail.attachment.image")
                    }
                }.frame(height: 220).background(Theme.sheet)
            }
        }.task(id: attachment.id + (attachment.contentRevision ?? "")) {
            loading = true; failure = nil
            do {
                let source = try await model.resolvePreviewAttachment(attachment)
                let preview = try await AttachmentPreviewLoader.load(source)
                guard !Task.isCancelled else { return }; resolved = source; content = preview; loading = false
            } catch { if !Task.isCancelled { failure = error.localizedDescription; loading = false } }
        }.onDisappear { content = nil; resolved = nil }
            .sheet(isPresented: $enlarged) { AttachmentPreviewView(attachment: resolved ?? attachment).environmentObject(model) }
    }
}
