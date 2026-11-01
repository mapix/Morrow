import SwiftUI
import MorrowCore

struct DraftBodyPreview: View {
    let draft: ComposeDraft
    @State private var document: ReaderDocument?
    @State private var failure: String?
    private var input: ReaderDocumentInput {
        ReaderDocumentInput(mailID: "draft-preview:" + draft.id, body: draft.htmlBody?.isEmpty == false ? draft.htmlBody! : draft.body,
            usesHTML: draft.htmlBody?.isEmpty == false, allowsRemoteImages: true, themeCSS: Theme.htmlTokens,
            emptyMessage: L10n.t("草稿正文为空。"), attachments: draft.attachments.filter { $0.contentID != nil })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t("发送前预览 · 尚未发送")).font(Theme.label).foregroundStyle(Theme.muted)
            Group {
                if let document { SecureHTMLView(document: document, failure: $failure) }
                else if let failure { Text(failure).font(Theme.body).foregroundStyle(Theme.error) }
                else { ProgressView(L10n.t("正在准备正文预览…")) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.accessibilityIdentifier("draft.body-preview")
            .task(id: input) {
                document = nil; failure = nil
                do { let rendered = try await ReaderDocumentCache.shared.prepare(input); guard !Task.isCancelled else { return }; document = rendered }
                catch { if !Task.isCancelled { failure = error.localizedDescription } }
            }.onDisappear { document = nil }
    }
}
