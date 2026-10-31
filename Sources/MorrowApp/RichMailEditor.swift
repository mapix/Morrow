import SwiftUI
import AppKit

@MainActor final class RichTextActions: ObservableObject {
    weak var view: NSTextView?
    var flush: (() -> Void)?
    func toggle(_ trait: NSFontTraitMask) {
        guard let view else { return }; let selection = view.selectedRange()
        let current = selection.length > 0 ? (view.textStorage?.attribute(.font, at: selection.location, effectiveRange: nil) as? NSFont ?? Theme.editorFont) : (view.typingAttributes[.font] as? NSFont ?? Theme.editorFont)
        let manager = NSFontManager.shared
        let font = manager.traits(of: current).contains(trait) ? manager.convert(current, toNotHaveTrait: trait) : manager.convert(current, toHaveTrait: trait)
        if selection.length > 0 { view.textStorage?.addAttribute(.font, value: font, range: selection) } else { view.typingAttributes[.font] = font }
        view.didChangeText(); view.window?.makeFirstResponder(view)
    }
    func underline() {
        guard let view else { return }; let selection = view.selectedRange()
        let current = selection.length > 0 ? (view.textStorage?.attribute(.underlineStyle, at: selection.location, effectiveRange: nil) as? Int ?? 0) : (view.typingAttributes[.underlineStyle] as? Int ?? 0)
        if selection.length > 0 { view.textStorage?.addAttribute(.underlineStyle, value: current == 0 ? 1 : 0, range: selection) } else { view.typingAttributes[.underlineStyle] = current == 0 ? 1 : 0 }
        view.didChangeText(); view.window?.makeFirstResponder(view)
    }
    func link() {
        guard let view else { return }; let range = view.selectedRange(); let alert = NSAlert(); alert.messageText = L10n.t("添加链接"); alert.informativeText = L10n.t("填写 HTTPS、HTTP 或 mailto 地址。"); alert.addButton(withTitle: L10n.t("添加")); alert.addButton(withTitle: L10n.t("取消"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24)); field.placeholderString = "https://example.com"; alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn, let url = URL(string: field.stringValue), ["https", "http", "mailto"].contains(url.scheme ?? "") else { return }
        if range.length > 0 { view.textStorage?.addAttribute(.link, value: url, range: range) }
        else { view.insertText(NSAttributedString(string: field.stringValue, attributes: [.link: url, .font: Theme.editorFont]), replacementRange: range) }
        view.didChangeText(); view.window?.makeFirstResponder(view)
    }
}

struct RichMailEditor: NSViewRepresentable {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    @Binding var text: String
    @Binding var html: String?
    let actions: RichTextActions
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let view = CompositionMailTextView(frame: NSRect(x: 0, y: 0, width: 720, height: 300)); view.isRichText = true; view.importsGraphics = false; view.allowsUndo = true; view.isEditable = true; view.isSelectable = true; view.usesFontPanel = true; view.drawsBackground = true; view.backgroundColor = NSColor(Theme.documentPaper); view.font = Theme.editorFont; view.textColor = NSColor(Theme.documentInk); view.textContainerInset = NSSize(width: 8, height: 8); view.isVerticallyResizable = true; view.isHorizontallyResizable = false; view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true; view.textContainer?.containerSize = NSSize(width: 720, height: CGFloat.greatestFiniteMagnitude); view.delegate = context.coordinator; view.isAutomaticLinkDetectionEnabled = true; view.setAccessibilityLabel(L10n.t("邮件正文，支持格式化"))
        view.committedEdit = { [weak coordinator = context.coordinator] in coordinator?.publish($0) }
        scroll.documentView = view; actions.view = view; actions.flush = { [weak coordinator = context.coordinator] in coordinator?.finishAndExport() }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView else { return }
        // Keep the input method's marked range and attributed text intact.
        // Formatting/theme work is deferred until the composition is committed.
        guard !view.hasMarkedText() else { return }
        context.coordinator.updating = true
        defer { context.coordinator.updating = false }
        let staleEcho = ChatEditorSynchronization.isPendingModelEcho(model: text, native: view.string, publishedNative: context.coordinator.publishedNativeText, previousModel: context.coordinator.lastModelText)
        let changedText = !staleEcho && view.string != text
        if changedText {
            let originalText = view.string, originalSelection = view.selectedRange()
            if let html, let data = html.data(using: .utf8), let attributed = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html], documentAttributes: nil) { view.textStorage?.setAttributedString(attributed) }
            else { view.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [.font: Theme.editorFont, .foregroundColor: NSColor(Theme.documentInk)])) }
            view.setSelectedRange(ChatEditorSynchronization.selection(originalSelection, replacing: originalText, with: view.string))
        }
        if !staleEcho { context.coordinator.lastModelText = text; if text == context.coordinator.publishedNativeText { context.coordinator.publishedNativeText = nil } }
        view.backgroundColor = NSColor(Theme.documentPaper)
        view.insertionPointColor = NSColor(Theme.documentInk)
        // Formatting, selections, and unsaved text survive an appearance change.
        // The app's toolbar does not author custom text colors; display colors
        // are separate from the recipient-facing colors produced below.
        if changedText || context.coordinator.displayTheme != Theme.current {
            context.coordinator.displayTheme = Theme.current
            view.textColor = NSColor(Theme.documentInk)
            view.typingAttributes[.foregroundColor] = NSColor(Theme.documentInk)
            if let storage = view.textStorage { storage.addAttribute(.foregroundColor, value: NSColor(Theme.documentInk), range: NSRange(location: 0, length: storage.length)) }
        }
        view.setAccessibilityLabel(L10n.t("邮件正文，支持格式化"))
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichMailEditor
        var updating = false
        var exportWork: DispatchWorkItem?
        var displayTheme: MorrowTheme?
        var lastModelText = ""
        var publishedNativeText: String?
        init(_ parent: RichMailEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }; publish(view)
        }
        func publish(_ view: NSTextView) {
            guard !updating, !view.hasMarkedText() else { exportWork?.cancel(); return }
            publishedNativeText = view.string; if parent.text != view.string { parent.text = view.string }; exportWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.exportHTML() }; exportWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
        func finishAndExport() {
            guard let view = parent.actions.view else { return }
            if view.hasMarkedText() {
                if let window = view.window, window.firstResponder === view { window.makeFirstResponder(nil) }
                if view.hasMarkedText() { view.unmarkText(); view.inputContext?.discardMarkedText() }
                publish(view)
            }
            exportHTML()
        }
        func exportHTML() {
            exportWork?.cancel()
            guard let view = parent.actions.view, !view.hasMarkedText(), let storage = view.textStorage else { return }
            let outgoing = NSMutableAttributedString(attributedString: storage)
            outgoing.addAttribute(.foregroundColor, value: NSColor(Theme.documentExportInk), range: NSRange(location: 0, length: outgoing.length))
            guard let data = try? outgoing.data(from: NSRange(location: 0, length: outgoing.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.html]) else { return }
            parent.html = String(data: data, encoding: .utf8)
        }
    }
}

private final class CompositionMailTextView: NSTextView {
    var committedEdit: ((NSTextView) -> Void)?
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        super.insertText(insertString, replacementRange: replacementRange)
        if !hasMarkedText() { committedEdit?(self) }
    }
    override func unmarkText() { super.unmarkText(); committedEdit?(self) }
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned, !hasMarkedText() { committedEdit?(self) }
        return resigned
    }
}
