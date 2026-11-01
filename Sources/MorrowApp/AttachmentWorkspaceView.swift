import SwiftUI
import MorrowCore

enum AttachmentBrowserMode: String, CaseIterable, Identifiable {
    case list, grid
    var id: String { rawValue }
    var title: String {
        switch self {
        case .list: return AttachmentPreviewWords.text("列表", "List", "リスト")
        case .grid: return AttachmentPreviewWords.text("预览", "Previews", "プレビュー")
        }
    }
    var symbol: String { self == .list ? "list.bullet" : "square.grid.2x2" }
}

struct AttachmentWorkspaceView: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    @EnvironmentObject var model: AppModel
    @AppStorage("MorrowAttachmentDisplayMode") private var displayMode = AttachmentBrowserMode.list.rawValue
    @State private var previewRecord: MailAttachmentRecord?
    @State private var selecting = false
    private var mode: AttachmentBrowserMode { AttachmentBrowserMode(rawValue: displayMode) ?? .list }

    var body: some View {
        let entries = model.filteredAttachments
        let query = model.attachmentQuery
        let selected = model.selectedAttachmentIDs
        let compact = model.compactLayout
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.t("附件")).font(Theme.title)
                Text("\(entries.count)").font(Theme.label).monospacedDigit().foregroundStyle(Theme.muted)
                Spacer()
                Picker(AttachmentPreviewWords.text("显示方式", "View mode", "表示方式"), selection: $displayMode) {
                    ForEach(AttachmentBrowserMode.allCases) { mode in Label(mode.title, systemImage: mode.symbol).tag(mode.rawValue) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 170).accessibilityIdentifier("attachment.view-mode")
                Button(selecting ? AttachmentPreviewWords.text("完成选择", "Done", "選択完了") : L10n.t("选择")) { selecting.toggle() }
                    .buttonStyle(QuietButtonStyle()).accessibilityIdentifier("attachment.selection-mode")
            }
            HStack {
                TextField(L10n.t("搜索文件名、邮件主题或发件人"), text: $model.attachmentQuery).textFieldStyle(PaperFieldStyle())
                Picker(L10n.t("类型"), selection: $model.attachmentKind) {
                    ForEach(["全部", "文档", "表格", "图片", "音频", "视频", "压缩包", "其他"], id: \.self) { kind in Text(L10n.t(kind)).tag(kind) }
                }.frame(width: 130)
            }
            if selecting && !selected.isEmpty {
                HStack {
                    Text(L10n.format("已选{0}个", "\(selected.count)")).font(Theme.label).foregroundStyle(Theme.secondary)
                    Button(L10n.t("取消选择")) { model.selectedAttachmentIDs = [] }.buttonStyle(.plain).font(Theme.label)
                    Spacer()
                    Button(L10n.t("保存所选")) { model.saveSelectedAttachments() }.buttonStyle(CompactButtonStyle())
                    Button(L10n.t("分析所选")) { model.analyzeSelectedAttachments() }.buttonStyle(CompactButtonStyle()).disabled(model.partnerBusy)
                }
            }
            if entries.isEmpty {
                EmptyRegion(icon: "paperclip", title: L10n.t("这里汇集邮件的附件"), detail: query.isEmpty ? L10n.t("带附件的邮件同步或导入后，会自动出现在这里。") : L10n.t("换一个文件名或类型再试。"), action: nil)
            } else if mode == .list {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(entries) { entry in
                            HStack(alignment: .top, spacing: 14) {
                                if selecting { selectionButton(entry, selected: selected.contains(entry.id)) }
                                Image(systemName: AttachmentFileSymbol.symbol(entry)).font(Theme.heading).foregroundStyle(Theme.muted).frame(width: 32, height: 44).accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 9) {
                                    Button(displayName(entry)) { previewRecord = entry }.buttonStyle(.plain).font(Theme.body.weight(.medium)).frame(minHeight: 30).accessibilityIdentifier("attachment.open-preview")
                                    HStack(spacing: 12) {
                                        Text(L10n.t(entry.kind)); Text(entry.attachment.size); Text(entry.mail.from.display).lineLimit(1)
                                        Spacer(); Text(entry.mail.date.uiFormatted(date: .abbreviated, time: .omitted))
                                    }.font(Theme.label).foregroundStyle(Theme.muted)
                                    Button(entry.mail.subject) { model.revealMail(entry.mail) }.buttonStyle(.plain).font(Theme.label).foregroundStyle(Theme.accent2).lineLimit(2)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                actions(entry)
                            }.padding(.vertical, compact ? 10 : 16).background(selecting && selected.contains(entry.id) ? Theme.selected.opacity(0.5) : Theme.clear)
                            Rectangle().fill(Theme.rule).frame(height: 1)
                        }
                    }
                }.accessibilityIdentifier("attachment.list")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 16)], alignment: .leading, spacing: 16) {
                        ForEach(entries) { entry in
                            VStack(alignment: .leading, spacing: 8) {
                                ZStack(alignment: .topLeading) {
                                    Button { previewRecord = entry } label: {
                                        VStack(alignment: .leading, spacing: 10) {
                                            AttachmentGridThumbnail(entry: entry).frame(height: 138).frame(maxWidth: .infinity).background(Theme.sheet, in: RoundedRectangle(cornerRadius: Theme.radius))
                                            Text(displayName(entry)).font(Theme.label.weight(.medium)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                            HStack { Text(entry.mail.from.display).lineLimit(1); Spacer(minLength: 4); Text(entry.attachment.size).fixedSize() }.font(Theme.small).foregroundStyle(Theme.muted)
                                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Theme.sheet, in: RoundedRectangle(cornerRadius: Theme.radius))
                                            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(selecting && selected.contains(entry.id) ? Theme.accent2 : Theme.rule, lineWidth: selecting && selected.contains(entry.id) ? 2 : 1))
                                    }.buttonStyle(.plain).accessibilityLabel(AttachmentPreviewWords.text("预览附件：", "Preview attachment: ", "添付ファイルをプレビュー：") + displayName(entry)).accessibilityIdentifier("attachment.open-preview")
                                    if selecting { selectionButton(entry, selected: selected.contains(entry.id)).background(Theme.sheet, in: RoundedRectangle(cornerRadius: Theme.radius)).padding(6) }
                                }
                                HStack { Button(L10n.t("来源邮件")) { model.revealMail(entry.mail) }.buttonStyle(.plain).font(Theme.small).foregroundStyle(Theme.accent2); Spacer(); actions(entry) }.padding(.horizontal, 4)
                            }
                        }
                    }.padding(.vertical, 2)
                }.accessibilityIdentifier("attachment.grid")
            }
        }.padding(28).background(Theme.paper)
            .onAppear { if !selecting { model.selectedAttachmentIDs = [] } }
            .onChange(of: selecting) { if !selecting { model.selectedAttachmentIDs = [] } }
            .sheet(item: $previewRecord) { entry in
                AttachmentPreviewView(attachment: entry.attachment, onAnalyze: { analyze(entry) }).environmentObject(model)
            }
    }
    private func displayName(_ entry: MailAttachmentRecord) -> String { entry.attachment.name.isEmpty ? AttachmentPreviewWords.text("未命名附件", "Unnamed attachment", "名前のない添付ファイル") : entry.attachment.name }
    private func selectionButton(_ entry: MailAttachmentRecord, selected: Bool) -> some View {
        Button {
            if !selected && model.selectedAttachmentIDs.count >= 8 { model.error = L10n.t("一次分析最多选择8个附件。") }
            else { model.selectAttachment(entry.id, additive: true) }
        } label: { Image(systemName: selected ? "checkmark.square.fill" : "square").font(Theme.actionIcon).frame(width: 36, height: 36) }
            .buttonStyle(.plain).accessibilityLabel(L10n.t("选择附件：") + displayName(entry)).accessibilityIdentifier("attachment.select")
    }
    private func actions(_ entry: MailAttachmentRecord) -> some View {
        Menu {
            Button(L10n.t("打开附件")) { previewRecord = entry }
            Button(L10n.t("保存附件…")) { Task { await model.attachment(entry.attachment, save: true) } }
            Button(L10n.t("查看提取文字")) { Task { await model.previewText(entry.attachment) } }
            Button(L10n.t("让伙伴分析")) { analyze(entry) }
        } label: { Image(systemName: "ellipsis").frame(width: 32, height: 32) }.menuStyle(.borderlessButton).frame(width: 32)
    }
    private func analyze(_ entry: MailAttachmentRecord) {
        previewRecord = nil
        finishFocusedChatComposition()
        model.chatPinnedContext = WorkspaceContext(page: "attachments", label: displayName(entry), mailIDs: [entry.mail.id], attachmentIDs: [entry.id])
        model.chatExpanded = true
        model.chatInput = AttachmentPreviewWords.text("分析当前附件，列出关键事实、需要核对的事项，并引用此附件的来源。", "Analyze this attachment, list key facts and items to verify, and cite this attachment's source.", "この添付ファイルを分析し、重要な事実と確認事項を挙げ、このファイルの出典を引用してください。")
        model.beginSidebarChat()
    }
}

private enum AttachmentFileSymbol {
    static func symbol(_ entry: MailAttachmentRecord) -> String {
        if entry.attachment.mimeType == "application/pdf" || entry.attachment.name.lowercased().hasSuffix(".pdf") { return "doc.richtext" }
        switch entry.kind {
        case "图片": return "photo"
        case "音频": return "waveform"
        case "视频": return "film"
        case "表格": return "tablecells"
        case "压缩包": return "archivebox"
        default: return "doc"
        }
    }
}

private struct AttachmentGridThumbnail: View {
    let entry: MailAttachmentRecord
    @State private var thumbnail: AttachmentThumbnail?
    private var requestID: String { entry.attachment.id + ":" + (entry.attachment.contentRevision ?? "") + ":" + (entry.attachment.storedPath ?? "") }
    var body: some View {
        Group {
            if let thumbnail { Image(decorative: thumbnail.image, scale: 1).resizable().interpolation(.high).scaledToFit().padding(8) }
            else { Image(systemName: AttachmentFileSymbol.symbol(entry)).font(.system(size: 40, weight: .light)).foregroundStyle(Theme.muted) }
        }.task(id: requestID) {
            thumbnail = nil
            let value = try? await AttachmentThumbnailCache.shared.image(entry.attachment, pixels: 384)
            guard !Task.isCancelled else { return }; thumbnail = value
        }.onDisappear { thumbnail = nil }
    }
}
