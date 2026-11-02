import AppKit
import SwiftUI

struct MarkdownOriginalSourceView: View {
    let source: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(L10n.t("完整原文")).font(Theme.heading); Spacer(); ChatReplyCopyButton(text: source, label: "复制原文"); Button(L10n.t("关闭")) { dismiss() }.buttonStyle(CompactButtonStyle()) }.padding(16)
            Divider().overlay(Theme.rule)
            ReadOnlySourceText(source: source)
        }.frame(minWidth: 500, idealWidth: 760, minHeight: 500, idealHeight: 680).background(Theme.sheet)
    }
}
private struct ReadOnlySourceText: NSViewRepresentable {
    let source: String
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 500)); text.isEditable = false; text.isSelectable = true; text.isRichText = false
        text.font = Theme.editorFont; text.textColor = NSColor(Theme.ink); text.backgroundColor = NSColor(Theme.sheet)
        text.textContainerInset = NSSize(width: 20, height: 16); text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]; text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude); text.textContainer?.containerSize = NSSize(width: 700, height: CGFloat.greatestFiniteMagnitude); text.textContainer?.widthTracksTextView = true; text.layoutManager?.allowsNonContiguousLayout = true
        text.string = source; text.setAccessibilityLabel(L10n.t("完整原文")); scroll.documentView = text
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) { if let text = scroll.documentView as? NSTextView { if text.string != source { text.string = source }; text.textColor = NSColor(Theme.ink); text.backgroundColor = NSColor(Theme.sheet) } }
}
