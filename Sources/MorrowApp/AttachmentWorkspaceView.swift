import SwiftUI
import MorrowCore

struct AttachmentWorkspaceView: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    @EnvironmentObject var model: AppModel
    private var query: String { model.attachmentQuery }
    private var kind: String { model.attachmentKind }
    private var entries: [MailAttachmentRecord] { model.filteredAttachments }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) { Text(L10n.t("附件")).font(Theme.title); Text("\(entries.count)").font(Theme.label).monospacedDigit().foregroundStyle(Theme.muted); Spacer() }
            HStack { TextField(L10n.t("搜索文件名、邮件主题或发件人"), text: $model.attachmentQuery).textFieldStyle(PaperFieldStyle()); Picker(L10n.t("类型"), selection: $model.attachmentKind) { ForEach([L10n.t("全部"), L10n.t("文档"), L10n.t("表格"), L10n.t("图片"), L10n.t("音频"), L10n.t("视频"), L10n.t("压缩包"), L10n.t("其他")], id: \.self) { Text($0).tag($0) } }.frame(width: 130) }
            if !model.selectedAttachmentIDs.isEmpty { HStack { Text(L10n.format("已选{0}个", "\(model.selectedAttachmentIDs.count)")).font(Theme.label).foregroundStyle(Theme.secondary); Button(L10n.t("取消选择")) { model.selectedAttachmentIDs = [] }.buttonStyle(.plain).font(Theme.label); Spacer(); Button(L10n.t("保存所选")) { model.saveSelectedAttachments() }.buttonStyle(CompactButtonStyle()); Button(L10n.t("分析所选")) { model.analyzeSelectedAttachments() }.buttonStyle(CompactButtonStyle()).disabled(model.partnerBusy) } }
            if entries.isEmpty { EmptyRegion(icon: "paperclip", title: L10n.t("这里汇集邮件的附件"), detail: query.isEmpty ? L10n.t("带附件的邮件同步或导入后，会自动出现在这里。") : L10n.t("换一个文件名或类型再试。"), action: nil) }
            else {
                ScrollView { LazyVStack(alignment: .leading, spacing: 0) { ForEach(entries) { entry in
                    HStack(alignment: .top, spacing: 14) {
                        Button { if !model.selectedAttachmentIDs.contains(entry.id) && model.selectedAttachmentIDs.count >= 8 { model.error = L10n.t("一次分析最多选择8个附件。") } else { model.selectAttachment(entry.id, additive: true) } } label: { Image(systemName: model.selectedAttachmentIDs.contains(entry.id) ? "checkmark.square.fill" : "square").font(Theme.actionIcon).frame(width: 44, height: 44) }.buttonStyle(.plain).accessibilityLabel(L10n.t("选择附件：") + entry.attachment.name)
                        VStack(alignment: .leading, spacing: 9) {
                            Button(entry.attachment.name) { model.selectAttachment(entry.id); Task { await model.previewText(entry.attachment) } }.buttonStyle(.plain).font(Theme.body.weight(.medium)).frame(minHeight: 30)
                            HStack(spacing: 12) { Text(entry.kind); Text(entry.attachment.size); Text(entry.mail.from.display).lineLimit(1); Spacer(); Text(entry.mail.date.uiFormatted(date: .abbreviated, time: .omitted)) }.font(Theme.label).foregroundStyle(Theme.muted)
                            Button(entry.mail.subject) { model.revealMail(entry.mail) }.buttonStyle(.plain).font(Theme.label).foregroundStyle(Theme.accent2).lineLimit(2)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Menu { Button(L10n.t("打开附件")) { Task { await model.attachment(entry.attachment) } }; Button(L10n.t("保存附件…")) { Task { await model.attachment(entry.attachment, save: true) } }; Button(L10n.t("提取文字与预览")) { model.selectAttachment(entry.id); Task { await model.previewText(entry.attachment) } }; Button(L10n.t("让伙伴分析")) { model.selectAttachment(entry.id); model.analyzeSelectedAttachments() } } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.menuStyle(.borderlessButton).frame(width: 44)
                    }.padding(.vertical, model.compactLayout ? 10 : 16).background(model.selectedAttachmentIDs.contains(entry.id) ? Theme.selected.opacity(0.5) : Theme.clear)
                    Rectangle().fill(Theme.rule).frame(height: 1)
                } } }
            }
        }.padding(28).background(Theme.paper)
    }
}
