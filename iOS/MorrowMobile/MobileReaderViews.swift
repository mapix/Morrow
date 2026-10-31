import SwiftUI
import UIKit
import WebKit
import MorrowCore

struct MobileReader: View {
    @EnvironmentObject var model: MobileModel
    let mailID: String
    @State private var analyzing = false
    @State private var plainText = false
    @State private var remoteImages = false
    @State private var details = false
    @State private var source: ReaderBodySource?
    @State private var selection = ReaderBodySelection()
    @State private var document: ReaderDocument?
    @State private var failed = false
    @AppStorage("SmailMobileTheme") private var theme = "coral"
    private var mail: MailMessage? { model.mail(id: mailID) }
    private var request: ReaderBodyRequest { .init(id: mailID, version: mail?.bodyVersion ?? "missing") }
    private struct Preparation: Equatable { var id: String; var version: String; var ready: Bool; var plain: Bool; var remote: Bool; var theme: String }
    private var preparation: Preparation { .init(id: mailID, version: source?.version ?? request.version, ready: source != nil, plain: plainText, remote: remoteImages, theme: theme) }
    var body: some View {
        VStack(spacing: 0) {
            if let mail {
                VStack(alignment: .leading, spacing: 10) {
                    Text(mail.subject).font(.title2).fontWeight(.semibold).lineLimit(3).accessibilityIdentifier("mail.subject")
                    HStack {
                        Text(mail.from.display).font(.headline).lineLimit(1)
                        Spacer()
                        Text(MobileL10n.text(mail.isRead ? "已读" : "未读")).font(.caption).fontWeight(.semibold)
                        Button { details = true } label: { Image(systemName: "info.circle") }.accessibilityLabel(MobileL10n.text("邮件详情"))
                    }
                    if source?.html.isEmpty == false {
                        Picker(MobileL10n.text("正文显示方式"), selection: $plainText) {
                            Text(MobileL10n.text("原始排版")).tag(false); Text(MobileL10n.text("纯文本")).tag(true)
                        }.pickerStyle(.segmented)
                    }
                }.padding(18)
            }
            Divider()
            Group {
                if let document { MobileSecureHTMLView(document: document, failed: $failed) }
                else if failed { Text(MobileL10n.text("正文暂时无法显示，请稍后重试。")).font(.callout).padding() }
                else { ProgressView() }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if document?.hasRemoteImages == true && !plainText {
                HStack {
                    Text(MobileL10n.text(remoteImages ? "外部图片已启用，脚本仍被阻止。" : "外部图片已阻止")).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(MobileL10n.text(remoteImages ? "阻止外部图片" : "加载外部图片")) { remoteImages.toggle() }.font(.caption)
                }.padding(.horizontal, 18).padding(.vertical, 8)
            }
            Divider()
            if let mail {
                HStack {
                    Button(MobileL10n.text("回复")) { Task { do { model.compose = try await model.reply(mail) } catch { model.error = error.localizedDescription } } }.buttonStyle(.borderedProminent).accessibilityIdentifier("mail.reply")
                    Button(MobileL10n.text(mail.isRead ? "标记未读" : "标记已读")) { Task { await model.mark(mail, read: !mail.isRead) } }.buttonStyle(.bordered)
                    Spacer()
                }.padding(16)
            }
        }.navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(MobileL10n.text("分析邮件")) { analyze() }.disabled(analyzing || mail == nil) } }
        .onAppear { if let mail { model.context = model.mailContext(mail) } }
        .task(id: request) {
            let current = request, ticket = selection.begin(request)
            if source?.id != current.id { source = nil; document = nil }
            do {
                let loaded = try await ReaderBodySource.load(id: current.id, store: model.store)
                guard !Task.isCancelled, selection.accepts(ticket) else { return }; source = loaded; failed = false
            } catch { if !Task.isCancelled, selection.accepts(ticket) { failed = true } }
        }
        .task(id: preparation) {
            guard let source else { return }
            let css = theme == "dark" ? ":root{--paper:#242f36;--ink:#e9f0f3;--muted:#a8b9c4;--rule:#43525d;}" : ":root{--paper:#fdfbf8;--ink:#1d1714;--muted:#625955;--rule:#d9d3cf;}"
            let input = ReaderDocumentInput(mailID: source.id, body: plainText || source.html.isEmpty ? source.text : source.html,
                usesHTML: !plainText && !source.html.isEmpty, allowsRemoteImages: remoteImages, themeCSS: css,
                emptyMessage: MobileL10n.text("此邮件没有可显示的纯文本正文。"), blockedImageLabel: MobileL10n.text("外部图片已阻止"), attachments: source.attachments)
            do { let prepared = try await ReaderDocumentCache.shared.prepare(input); guard !Task.isCancelled else { return }; document = prepared; failed = false }
            catch { if !Task.isCancelled { failed = true } }
        }
        .onDisappear { selection.cancel(); source = nil; document = nil }
        .sheet(isPresented: $details) { NavigationStack { List {
            if let mail {
                Section { Text(mail.from.email); Text(mail.to.map(\.email).joined(separator: ", ")) }
                if let analysis = mail.analysis { Section(MobileL10n.text("分析邮件")) { Text(analysis.summary); Text(analysis.reasoning).font(.caption).foregroundStyle(.secondary); Text(analysis.source).font(.caption2) } }
                Section(MobileL10n.text("附件")) { ForEach(mail.attachments) { attachment in NavigationLink { MobileAttachmentReader(attachment: attachment, mail: mail).environmentObject(model) } label: { Label(attachment.name, systemImage: "paperclip") } } }
            }
        }.navigationTitle(MobileL10n.text("邮件详情")).toolbar { ToolbarItem(placement: .confirmationAction) { Button(MobileL10n.text("关闭")) { details = false } } } } }
    }
    private func analyze() {
        analyzing = true
        Task {
            defer { analyzing = false }
            do {
                guard let full = try await model.store.message(mailID) else { return }
                let evidence = try await MailEvidence.forAnalysis(full, store: model.store)
                let analysis = try await model.partner.analyze(evidence, settings: model.settings)
                guard var latest = try await model.store.message(mailID) else { return }
                latest.analysis = analysis; _ = try await model.store.upsert(latest); await model.reload()
            } catch { model.error = error.localizedDescription }
        }
    }
}

struct MobileAttachmentReader: View {
    @EnvironmentObject var model: MobileModel
    let attachment: MailAttachment
    let mail: MailMessage
    @State private var document: ReaderDocument?
    @State private var failed = false
    @State private var sharing = false
    @State private var preparingShare = false
    @State private var shareURL: URL?
    @State private var shareTask: Task<Void, Never>?
    @State private var viewAlive = true
    var body: some View {
        VStack(spacing: 0) {
            Text(attachment.name).font(.title2).fontWeight(.semibold).lineLimit(2).padding(18).accessibilityIdentifier("attachment.title")
            Group { if let document { MobileSecureHTMLView(document: document, failed: $failed) } else { ProgressView() } }.frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Button { prepareShare() } label: { Label(MobileL10n.text("保存"), systemImage: "square.and.arrow.up") }.disabled(preparingShare)
                Spacer()
                NavigationLink(MobileL10n.text("来源邮件"), value: MobileRoute.mail(mail.id))
            }.padding(18)
        }.onAppear { viewAlive = true; var scope = model.mailContext(mail); scope.page = "attachments"; scope.label = attachment.name; scope.attachmentIDs = [attachment.id]; model.context = scope }
        .task(id: attachment.id + ":" + (attachment.contentRevision ?? "legacy")) {
            do {
                let result = try await AttachmentTextExtractor.shared.extract(attachment, store: model.store)
                let input = ReaderDocumentInput(mailID: "attachment:" + attachment.id, body: result.text.isEmpty ? result.failure ?? "" : result.text,
                    usesHTML: false, allowsRemoteImages: false, themeCSS: ":root{--paper:#fdfbf8;--ink:#1d1714;--muted:#625955;--rule:#d9d3cf;}", emptyMessage: "", attachments: [])
                let prepared = try await ReaderDocumentCache.shared.prepare(input); guard !Task.isCancelled else { return }; document = prepared
            } catch { if !Task.isCancelled { model.error = error.localizedDescription } }
        }.onDisappear { document = nil; viewAlive = false; shareTask?.cancel(); if !sharing, let shareURL { try? FileManager.default.removeItem(at: shareURL.deletingLastPathComponent()); self.shareURL = nil } }
        .sheet(isPresented: $sharing, onDismiss: { if let shareURL { try? FileManager.default.removeItem(at: shareURL.deletingLastPathComponent()) }; shareURL = nil }) {
            if let shareURL { MobileAttachmentActivity(url: shareURL) }
        }
    }
    private func prepareShare() {
        preparingShare = true
        shareTask = Task {
            defer { preparingShare = false }
            do {
                let attachment = attachment
                let target = try await Task.detached(priority: .utility) { () throws -> URL in
                    try Task.checkCancellation()
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MorrowShare-" + UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    var finished = false
                    defer { if !finished { try? FileManager.default.removeItem(at: directory) } }
                    let filename = URL(fileURLWithPath: attachment.name).lastPathComponent
                    let target = directory.appendingPathComponent(["", ".", ".."].contains(filename) ? "attachment" : filename)
                    if let path = attachment.storedPath {
                        let size = try URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                        guard size <= 100 * 1024 * 1024 else { throw MailError.message("附件超过大小限制。") }
                        do { try FileManager.default.linkItem(at: URL(fileURLWithPath: path), to: target) }
                        catch { try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: target) }
                    } else { guard !attachment.data.isEmpty, attachment.data.count <= 100 * 1024 * 1024 else { throw MailError.message("附件文件暂不可用。") }; try attachment.data.write(to: target) }
                    finished = true
                    return target
                }.value
                guard !Task.isCancelled, viewAlive else { try? FileManager.default.removeItem(at: target.deletingLastPathComponent()); return }
                shareURL = target; sharing = true
            } catch { model.error = error.localizedDescription }
        }
    }
}

private struct MobileAttachmentActivity: UIViewControllerRepresentable {
    var url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
