import SwiftUI
import AppKit

enum ChatReplyClipboard {
    static func content(_ source: String, markdown: Bool = false) -> String {
        // Retain the complete source if it exceeds the display parser's bound.
        guard !markdown, source.count <= 131072 else { return source }
        let plain = WorkMarkdownDocument(source).plainText
        return plain.isEmpty ? source : plain
    }
    @MainActor static func copy(_ source: String, markdown: Bool = false) {
        let value = content(source, markdown: markdown)
        guard !value.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

struct ChatReplyCopyButton: View {
    let text: String
    var label = "复制回复"
    @State private var copied = false
    var body: some View {
        Button {
            ChatReplyClipboard.copy(text); copied = true
        } label: {
            Label(L10n.t(copied ? "已复制" : label), systemImage: copied ? "checkmark" : "doc.on.doc")
        }.buttonStyle(CompactButtonStyle()).accessibilityIdentifier("chat.copy-reply")
            .contextMenu { Button(L10n.t("复制 Markdown")) { ChatReplyClipboard.copy(text, markdown: true); copied = true } }
            .task(id: copied) { if copied { do { try await Task.sleep(for: .seconds(2)); copied = false } catch {} } }
    }
}
