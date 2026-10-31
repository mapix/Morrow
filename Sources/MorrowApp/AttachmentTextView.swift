import SwiftUI
import MorrowCore

struct AttachmentTextView: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var model: AppModel
    var inline = false
    let preview: AttachmentTextPreview
    @State private var document: ReaderDocument?
    @State private var displayFailure: String?
    private struct Preparation: Equatable { var id: String; var text: String; var theme: String }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { VStack(alignment: .leading, spacing: 8) { Text(preview.name).font(Theme.heading); Text(preview.result.source).font(Theme.label).foregroundStyle(Theme.muted) }; Spacer(); Button { close() } label: { Image(systemName: "xmark") }.buttonStyle(IconButtonStyle()).help(L10n.t("关闭提取文字")) }
            if preview.result.truncated { Text(L10n.t("本次文字提取达到长度或页数限制，以下不覆盖完整附件。")).font(Theme.label).foregroundStyle(Theme.error) }
            if let failure = preview.result.failure { Text(failure).font(Theme.body).foregroundStyle(Theme.muted) }
            Group {
                if let document { SecureHTMLView(document: document, failure: $displayFailure) }
                else { ProgressView() }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.sheet)
                .task(id: Preparation(id: preview.id, text: preview.result.text, theme: Theme.current.rawValue)) {
                    let input = ReaderDocumentInput(mailID: "attachment-preview:" + preview.id, body: preview.result.text, usesHTML: false, allowsRemoteImages: false, themeCSS: Theme.htmlTokens, emptyMessage: "", attachments: [])
                    let prepared = try? await ReaderDocumentCache.shared.prepare(input)
                    guard !Task.isCancelled else { return }; document = prepared
                }.onDisappear { document = nil }
            Button(L10n.t("关闭")) { close() }.buttonStyle(QuietButtonStyle())
        }.padding(28).frame(width: inline ? nil : 760, height: inline ? nil : 700).background(Theme.paper)
    }
    private func close() { if inline { model.attachmentTextPreview = nil } else { dismiss() } }
}
