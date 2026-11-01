import SwiftUI
import MorrowCore
import AppKit
import UniformTypeIdentifiers
import CoreGraphics

@MainActor func finishFocusedChatComposition() { MediaTextView.finishFocusedComposition() }

struct SidebarChatView: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    @EnvironmentObject var model: AppModel
    @StateObject private var voice = NativeVoiceInput()
    @State private var voiceBase = ""
    @State private var voiceSessionID = ""
    @State private var historyLimit = 60
    private var context: WorkspaceContext { model.resolvedChatContext }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Menu {
                    ForEach(model.orderedChatSessions(archived: false).prefix(20)) { session in Button(session.title) { model.switchChatSession(session.id) } }
                    if model.orderedChatSessions(archived: false).count > 20 { Button(L10n.t("搜索全部对话")) { NotificationCenter.default.post(name: Notification.Name("MorrowSearchSessions"), object: nil) } }
                    Divider(); Button(L10n.t("新建对话")) { Task { _ = await model.createChatSession() } }
                } label: { HStack(spacing: 8) { Text(model.activeSession?.title ?? L10n.t("新对话")).font(Theme.body.weight(.semibold)).lineLimit(1); Image(systemName: "chevron.down").font(Theme.small) } }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.horizontal, 20).padding(.trailing, 44).frame(height: 58)
            if !model.briefs(in: model.activeSessionID).isEmpty { Button { model.openBriefs(sessionID: model.activeSessionID) } label: { Label(L10n.format("本会话简报（{0}）", String(model.briefs(in: model.activeSessionID).count)), systemImage: "doc.text") }.buttonStyle(CompactButtonStyle()).padding(.horizontal, 20).padding(.bottom, 10).accessibilityIdentifier("chat.session-briefs") }
            if let id = model.activeResponderID, let rule = model.responders.first(where: { $0.id == id }) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Button(L10n.t("响应器") + " · " + rule.title) { if let receipt = model.responderReceipts.first(where: { $0.responderID == id && $0.state == "preparing" }), let runID = receipt.runID, let run = model.agentRuns.first(where: { $0.id == runID }) { model.selectRun(run) } }.buttonStyle(.link)
                    Spacer()
                }.font(Theme.label).foregroundStyle(Theme.secondary).padding(.horizontal, 20).padding(.bottom, 10).help(model.responderStage).accessibilityIdentifier("responder.active")
            }
            ScrollViewReader { proxy in
                ScrollView { VStack(alignment: .leading, spacing: model.compactLayout ? 22 : 30) {
                    if model.visibleChat.count > historyLimit { Button(L10n.t("查看更早的消息")) { historyLimit += 40 }.buttonStyle(QuietButtonStyle()) }
                    if model.visibleChat.isEmpty { VStack(alignment: .leading, spacing: 12) {
                        Text(L10n.t("从这里一起处理。")).font(Theme.heading)
                        Button(L10n.t("总结当前内容")) { MediaTextView.finishFocusedComposition(); model.chatInput = L10n.t("总结当前内容，说明需要我处理的事项并引用依据。"); model.chatFocusNonce += 1 }.buttonStyle(.plain).foregroundStyle(Theme.accent2).font(Theme.body)
                        Button(L10n.t("找出待回复事项")) { MediaTextView.finishFocusedComposition(); model.chatInput = L10n.t("找出当前范围的待回复事项，列出下一步并引用邮件。"); model.chatFocusNonce += 1 }.buttonStyle(.plain).foregroundStyle(Theme.accent2).font(Theme.body)
                    }.padding(.vertical, 24) }
                    ForEach(Array(model.visibleChat.suffix(historyLimit))) { entry in ChatMessageView(entry: entry).id(entry.id) }
                    ForEach(model.openUIInteractions.filter { $0.chatID == nil && $0.completedAt == nil && ($0.sessionID ?? "legacy") == model.activeSessionID && ($0.runID == nil || $0.runID == context.runID) }) { interaction in NativeOpenUIView(interaction: interaction) }
                    if model.currentSessionBusy { VStack(alignment: .leading, spacing: 8) { if let trace = model.sdkLiveTrace { AgentProgressView(trace: trace, live: true) } else { HStack(spacing: 10) { ProgressView().controlSize(.small); Text(model.mailboxConnectionStatus ?? model.sidebarToolStatus ?? L10n.t("正在处理…")).font(Theme.label).foregroundStyle(Theme.secondary) } }; if !model.sdkStreamingText.isEmpty { Text(model.sdkStreamingText).font(Theme.body).foregroundStyle(Theme.secondary).lineLimit(7).textSelection(.enabled) }; if !model.sidebarEvidenceMailIDs.isEmpty { Text(L10n.format("本轮提供了 {0} 封邮件", "\(model.sidebarEvidenceMailIDs.count)")).font(Theme.small).foregroundStyle(Theme.secondary) } }.id("busy") }
                }.padding(.horizontal, 20).padding(.vertical, 8) }
                .onAppear { if let id = model.scrollChatID { revealChat(id, proxy: proxy) } else if let last = model.visibleChat.last { scrollChat(last.id, proxy: proxy) } }
                .onChange(of: model.visibleChat.count) { if let last = model.visibleChat.last { scrollChat(last.id, proxy: proxy) } }
                .onChange(of: model.activeSessionID) { historyLimit = 60; if let last = model.visibleChat.last { scrollChat(last.id, proxy: proxy) } }
                .onChange(of: model.currentSessionBusy) { if model.currentSessionBusy { scrollChat("busy", proxy: proxy) } }
                .onChange(of: model.scrollChatID) { if let id = model.scrollChatID { revealChat(id, proxy: proxy) } }
            }
            composer
                .onChange(of: model.chatInput) { model.scheduleSessionDraft() }
                .onChange(of: model.chatMaterials.map(\.id)) { model.scheduleSessionDraft() }
                .onChange(of: model.newChatWork) { model.scheduleSessionDraft() }
                .onChange(of: model.chatPinnedContext) { model.scheduleSessionDraft() }
                .onChange(of: model.activeSessionID) { voice.cancel() }
        }.background(Theme.sheet).onDisappear { voice.cancel() }
    }
    private func scrollChat(_ id: String, proxy: ScrollViewProxy, anchor: UnitPoint = .bottom) {
        // Scroll after the stack has finished the current layout transaction.
        Task { @MainActor in await Task.yield(); proxy.scrollTo(id, anchor: anchor) }
    }
    private func revealChat(_ id: String, proxy: ScrollViewProxy) {
        if let index = model.visibleChat.firstIndex(where: { $0.id == id }) { historyLimit = max(historyLimit, model.visibleChat.count - index) }
        scrollChat(id, proxy: proxy, anchor: .center)
    }
    private var scopeAnchor: some View {
        Menu {
            Button(model.chatPinnedContext == nil ? L10n.t("明确限定为当前内容") : L10n.t("恢复跟随界面提示")) { if model.chatPinnedContext == nil { model.pinCurrentChatScope() } else { model.chatPinnedContext = nil } }
            Button(L10n.t("仅使用本轮文件")) { model.newChatWork = false; model.chatPinnedContext = .init(page: "materials", label: L10n.t("本轮带入资料")) }
            Button(L10n.t("在全部邮箱中检索")) { model.newChatWork = false; model.chatPinnedContext = .init(page: "global", label: L10n.t("检索范围：全部邮箱")) }
            Divider(); Button(model.newChatWork ? L10n.t("返回普通对话") : L10n.t("形成新委托")) { model.newChatWork.toggle() }
        } label: {
            HStack(spacing: 7) { Image(systemName: model.chatPinnedContext == nil ? "link" : "pin.fill").foregroundStyle(Theme.accent2); Text(model.chatScopeLabel(context)).lineLimit(1); Spacer(minLength: 0); if model.newChatWork { Text(L10n.t("新委托")).foregroundStyle(Theme.accent2) }; Image(systemName: "chevron.down").font(Theme.small).foregroundStyle(Theme.muted) }.font(Theme.context).padding(.leading, 10).frame(minHeight: 28)
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 1).fill(Theme.accent2).frame(width: 2, height: 20) }
            .help(context.scopeMode == "hint" ? L10n.t("界面内容仅帮助理解指代，不限制任务或邮件检索。") : L10n.t("这是你明确限定的资料范围，可在菜单中恢复界面提示。")).accessibilityLabel((model.newChatWork ? L10n.t("新委托，") : "") + model.chatScopeLabel(context))
    }
    private var composer: some View {
        let sessionID = model.activeSessionID
        return VStack(alignment: .leading, spacing: 8) {
            scopeAnchor
            if !model.chatMaterials.isEmpty { ScrollView(.horizontal) { HStack(spacing: 12) { ForEach(model.chatMaterials) { material in HStack(spacing: 6) { ChatMaterialPreview(material: material, compact: true); Text(material.name).font(Theme.label).lineLimit(1); Button { model.chatMaterials.removeAll { $0.id == material.id } } label: { Image(systemName: "xmark").font(Theme.small) }.buttonStyle(.plain).frame(width: 24, height: 28).help(L10n.t("移除文件：") + material.name).accessibilityLabel(L10n.t("移除文件：") + material.name) }.frame(maxWidth: 210) } } }.frame(height: 48) }
            VStack(alignment: .leading, spacing: 4) {
                RichChatInput(text: Binding(get: { model.chatEditorInput(in: sessionID) }, set: { model.setChatEditorInput($0, in: sessionID) }), pasteMedia: model.pasteChatMaterials, submit: { if sessionID == model.activeSessionID && !voice.preparing && !voice.recording && !voice.finalizing { model.beginSidebarChat() } }, focusTrigger: model.chatFocusNonce, sessionID: sessionID, currentText: { model.chatEditorInput(in: sessionID) }, placeholder: model.newChatWork ? L10n.t("把这件事交给我…") : L10n.t("说说下一步，或带上文件…")).id(sessionID).frame(height: model.compactLayout ? 64 : 80).disabled(voice.preparing || voice.recording || voice.finalizing)
                    .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in let targetID = model.activeSessionID; for provider in providers { _ = provider.loadObject(ofClass: URL.self) { url, _ in if let url { Task { @MainActor in await model.addChatFile(url, sessionID: targetID) } } } }; return true }
                HStack(spacing: 12) {
                    Menu { Button(L10n.t("添加文件…")) { model.pickChatFiles() }; Button(L10n.t("截取Morrow窗口")) { model.captureWorkspace() }; Button(L10n.t("粘贴截图或文件")) { model.pasteChatMaterials() } } label: { Image(systemName: "plus").frame(width: 32, height: 32).contentShape(Rectangle()) }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 32).help(L10n.t("添加文件或截图")).accessibilityLabel(L10n.t("添加文件或截图"))
                    Button { if voice.recording { voice.stop() } else { MediaTextView.finishFocusedComposition(); voiceBase = model.chatInput; voiceSessionID = model.activeSessionID; Task { await voice.start() } } } label: { Image(systemName: voice.recording ? "stop.circle.fill" : "mic").foregroundStyle(voice.recording ? Theme.accent2 : Theme.secondary) }.buttonStyle(ToolbarIconButtonStyle()).frame(width: 32, height: 32).disabled(voice.preparing || voice.finalizing).help(voice.recording ? L10n.t("结束语音输入") : L10n.t("语音输入")).accessibilityLabel(voice.recording ? L10n.t("结束语音输入") : L10n.t("语音输入"))
                    Spacer()
                    Button { if model.currentSessionBusy, let task = model.sidebarTask { task.cancel() } else { MediaTextView.finishFocusedComposition(); voice.stop(); model.beginSidebarChat() } } label: { Image(systemName: model.currentSessionBusy ? "stop.fill" : "arrow.up") }.buttonStyle(ChatSendButtonStyle()).disabled(voice.recording || voice.preparing || voice.finalizing || (!model.currentSessionBusy && (model.sidebarTask != nil || model.partnerBusy || model.materialBusy || (model.chatInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.chatMaterials.isEmpty)))).help(model.currentSessionBusy ? L10n.t("停止处理") : L10n.t("发送（⌘Enter / Ctrl+Enter）")).accessibilityLabel(model.currentSessionBusy ? L10n.t("停止处理") : L10n.t("发送"))
                }.padding(.horizontal, 8).padding(.bottom, 8)
            }.background(Theme.sheet, in: RoundedRectangle(cornerRadius: Theme.radius)).overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.fieldEdge))
            Text(L10n.t("⌘Enter / Ctrl+Enter 发送 · Enter 换行")).font(Theme.small).foregroundStyle(Theme.muted)
            if model.sidebarTask != nil && !model.currentSessionBusy { Text(L10n.t("另一段对话正在处理；当前输入会保留。")).font(Theme.label).foregroundStyle(Theme.secondary) }
            if voice.finalizing { Text(L10n.t("正在完成转写…")).font(Theme.label).foregroundStyle(Theme.secondary) }
            if voice.preparing { Text(L10n.t("正在准备语音输入…")).font(Theme.label).foregroundStyle(Theme.secondary) }
            if voice.recording { HStack { Text(L10n.t("正在聆听")).font(Theme.label); ProgressView(value: Double(voice.level)).frame(width: 70) }.foregroundStyle(Theme.accent2) }
            if let error = voice.error { Text(error).font(Theme.label).foregroundStyle(Theme.error).textSelection(.enabled) }
        }.padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 18).onChange(of: voice.transcript) { guard voiceSessionID == model.activeSessionID else { return }; model.chatInput = voiceBase + (voiceBase.isEmpty ? "" : "\n") + voice.transcript }
    }
}

private struct ChatMessageView: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    let entry: PartnerChat
    @EnvironmentObject var model: AppModel
    @State private var showingDetails = false
    @State private var showingBudget = false
    private var sources: [MailMessage] { entry.messageIDs.compactMap(model.mailByID) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if entry.role == "user" {
                HStack(alignment: .top, spacing: 8) {
                    Spacer(minLength: 24)
                    Text(entry.text).font(Theme.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true).padding(12).background(Theme.sidebar, in: RoundedRectangle(cornerRadius: Theme.radius))
                    Button { showingDetails = true } label: { Image(systemName: "info.circle").font(Theme.label).foregroundStyle(Theme.muted) }.buttonStyle(ToolbarIconButtonStyle()).frame(width: 32, height: 32).help(L10n.t("查看提交时间与原范围")).accessibilityLabel(L10n.t("查看提交时间与原范围"))
                        .popover(isPresented: $showingDetails) { VStack(alignment: .leading, spacing: 8) { Text(entry.date.uiFormatted()).font(Theme.label); if let context = entry.context { Text(L10n.t(context.scopeMode == "hint" ? "界面提示：" : "提交范围：") + context.label).font(Theme.body) } }.padding(18).frame(maxWidth: 300) }
                }
            } else {
                if let id = entry.openUIID, let page = model.openUIInteractions.first(where: { $0.id == id && ($0.sessionID ?? "legacy") == (entry.sessionID ?? "legacy") }) { NativeOpenUIView(interaction: page) }
                if !entry.text.isEmpty {
                    WorkMarkdownContent(text: entry.text).help(L10n.t("回复于 ") + entry.date.uiFormatted()).accessibilityHint(Text(L10n.t("回复于 ") + entry.date.uiFormatted()))
                        .contextMenu { Button(L10n.t("复制回复")) { ChatReplyClipboard.copy(entry.text) }; Button(L10n.t("复制 Markdown")) { ChatReplyClipboard.copy(entry.text, markdown: true) } }
                    ChatReplyCopyButton(text: entry.text)
                }
                if let trace = entry.executionTrace { AgentProgressView(trace: trace) }
                if let ids = entry.artifactIDs { ForEach(ids, id: \.self) { id in if let artifact = model.agentArtifacts.first(where: { $0.id == id && $0.isBrief }) { Button { model.openBrief(artifact) } label: { HStack { Image(systemName: "doc.text"); VStack(alignment: .leading, spacing: 6) { Text(artifact.title).font(Theme.body.weight(.medium)).lineLimit(2); Text(L10n.t("查看这份简报")).font(Theme.label).foregroundStyle(Theme.secondary) }; Spacer(); Image(systemName: "arrow.up.right") }.padding(12) }.buttonStyle(ListRowButtonStyle()).accessibilityIdentifier("chat.open-brief") } } }
                if let continuation = entry.continuationPrompt ?? (entry.text.contains("Model turn budget reached") ? "继续刚才的任务，使用已保存的资料和进度。" : nil) {
                    HStack(spacing: 10) {
                        Button(L10n.t("继续这项任务")) { if let session = entry.sessionID { model.switchChatSession(session) }; model.chatInput = continuation; model.beginSidebarChat() }.buttonStyle(CompactButtonStyle()).disabled(model.partnerBusy).accessibilityIdentifier("agent.continue")
                        Button(L10n.t("调整运行预算")) { showingBudget = true }.buttonStyle(CompactButtonStyle()).accessibilityIdentifier("agent.adjust-budget")
                    }
                }
                if let ids = entry.draftIDs { ForEach(ids, id: \.self) { id in if let draft = model.drafts.first(where: { $0.id == id }) { Button { model.openDraft(draft) } label: { HStack { Image(systemName: "doc.text"); VStack(alignment: .leading) { Text(draft.subject.isEmpty ? L10n.t("无主题草稿") : draft.subject); Text(L10n.t("已保存到草稿箱 · 点击编辑与预览")).font(Theme.label).foregroundStyle(Theme.secondary) }; Spacer(); Image(systemName: "arrow.up.right") }.padding(12).background(Theme.sidebar, in: RoundedRectangle(cornerRadius: Theme.radius)) }.buttonStyle(.plain).accessibilityIdentifier("chat.open-draft") } } }
            }
            if let materials = entry.materials { ForEach(materials) { material in ChatMaterialPreview(material: material) } }
            if !sources.isEmpty { DisclosureGroup(L10n.format("依据邮件（{0}）", "\(sources.count)")) { ForEach(sources) { mail in Button { model.revealMail(mail) } label: { Label(mail.subject, systemImage: "envelope").font(Theme.label).lineLimit(2).padding(.vertical, 4) }.buttonStyle(ReferenceRowButtonStyle()) } }.font(Theme.label).foregroundStyle(Theme.secondary) }
            if let ids = entry.memoryIDs, !ids.isEmpty { Button(L10n.format("记忆依据（{0}）", "\(ids.count)")) { model.revealMemories(ids) }.buttonStyle(.plain).font(Theme.label).foregroundStyle(Theme.accent2) }
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .contain).accessibilityLabel(entry.role == "user" ? L10n.t("你的要求") : L10n.t("伙伴回复"))
            .sheet(isPresented: $showingBudget) { AgentBudgetSettingsSheet().environmentObject(model) }
    }
}

private struct RichChatInput: NSViewRepresentable {
    @Binding var text: String
    var pasteMedia: () -> Void
    var submit: () -> Void
    var focusTrigger: Int
    var sessionID: String = "legacy"
    var currentText: (() -> String)? = nil
    var placeholder: String = ""
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let editor = MediaTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 80))
        editor.isRichText = false; editor.importsGraphics = false; editor.allowsUndo = true
        editor.isEditable = enabled; editor.isSelectable = true; editor.drawsBackground = false
        editor.font = Theme.editorFont; editor.textColor = NSColor(Theme.ink); editor.insertionPointColor = NSColor(Theme.ink)
        editor.textContainerInset = NSSize(width: 10, height: 10)
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.lineFragmentPadding = 0
        editor.sessionID = sessionID; editor.mediaPaste = pasteMedia; editor.placeholder = placeholder
        editor.submitChat = submit
        editor.string = currentText?() ?? text
        editor.delegate = context.coordinator
        editor.committedEdit = { [weak coordinator = context.coordinator] view in coordinator?.publish(view) }
        if let selection = Coordinator.selections[sessionID] {
            let count = editor.string.utf16.count
            editor.setSelectedRange(NSRange(location: min(selection.location, count), length: min(selection.length, max(0, count - min(selection.location, count)))))
        } else { editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0)) }
        editor.setAccessibilityLabel(L10n.t("伙伴Chat输入框")); editor.setAccessibilityHelp(placeholder)
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        guard let editor = scroll.documentView as? MediaTextView, editor.sessionID == sessionID else { return }
        coordinator.parent = self
        editor.mediaPaste = pasteMedia; editor.placeholder = placeholder; editor.submitChat = submit
        if editor.isEditable != enabled { if !enabled { editor.finishComposition() }; editor.isEditable = enabled }
        if coordinator.displayTheme != Theme.current, !editor.hasMarkedText() {
            coordinator.displayTheme = Theme.current
            editor.textColor = NSColor(Theme.ink); editor.insertionPointColor = NSColor(Theme.ink)
            editor.placeholderColor = NSColor(Theme.muted)
        }
        if coordinator.language != L10n.languageCode {
            coordinator.language = L10n.languageCode
            editor.setAccessibilityLabel(L10n.t("伙伴Chat输入框")); editor.setAccessibilityHelp(placeholder)
        }
        // Read the owning session directly. SwiftUI's Binding may still carry a
        // value from a render started before the most recent native edit.
        let authoritative = currentText?() ?? text
        if let replacement = ChatEditorSynchronization.replacement(model: authoritative, native: editor.string, hasMarkedText: editor.hasMarkedText()) {
            let selection = ChatEditorSynchronization.selection(editor.selectedRange(), replacing: editor.string, with: replacement)
            coordinator.updating = true; editor.string = replacement; editor.setSelectedRange(selection); coordinator.updating = false
            editor.scrollRangeToVisible(selection)
        }
        if coordinator.focusTrigger != focusTrigger {
            coordinator.focusTrigger = focusTrigger
            let trigger = focusTrigger, owner = sessionID
            DispatchQueue.main.async { [weak editor, weak coordinator] in
                guard let editor, let coordinator, editor.sessionID == owner, coordinator.focusTrigger == trigger,
                      editor.isEditable, !editor.hasMarkedText(), let window = editor.window else { return }
                if window.firstResponder !== editor { window.makeFirstResponder(editor) }
            }
        }
    }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        guard let editor = scroll.documentView as? MediaTextView else { return }
        // Detaching a conversation is an intentional editing boundary. Preserve
        // the visible composition in that old session, never in the new one.
        editor.committedEdit = nil; editor.delegate = nil
        editor.submitChat = nil
        if let window = editor.window, window.firstResponder === editor { window.makeFirstResponder(nil) }
        if editor.hasMarkedText() { editor.unmarkText(); editor.inputContext?.discardMarkedText() }
        let value = editor.string, binding = coordinator.parent.$text
        coordinator.rememberSelection(editor)
        DispatchQueue.main.async { if binding.wrappedValue != value { binding.wrappedValue = value } }
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichChatInput
        var focusTrigger = -1
        var updating = false
        var displayTheme: MorrowTheme?
        var language = ""
        static var selections: [String: NSRange] = [:]
        private static var selectionOrder: [String] = []
        init(_ parent: RichChatInput) { self.parent = parent }
        func textDidChange(_ notification: Notification) { if let editor = notification.object as? MediaTextView { publish(editor) } }
        func textDidEndEditing(_ notification: Notification) { if let editor = notification.object as? MediaTextView { publish(editor) } }
        fileprivate func publish(_ editor: MediaTextView) {
            guard !updating, editor.sessionID == parent.sessionID, !editor.hasMarkedText() else { return }
            if (parent.currentText?() ?? parent.text) != editor.string { parent.text = editor.string }
            rememberSelection(editor)
        }
        fileprivate func rememberSelection(_ editor: MediaTextView) {
            Self.selections[editor.sessionID] = editor.selectedRange()
            Self.selectionOrder.removeAll { $0 == editor.sessionID }; Self.selectionOrder.append(editor.sessionID)
            while Self.selectionOrder.count > 100 { Self.selections.removeValue(forKey: Self.selectionOrder.removeFirst()) }
        }
    }
}

final class MediaTextView: NSTextView {
    var sessionID = "legacy"
    var mediaPaste: (() -> Void)?
    var committedEdit: ((MediaTextView) -> Void)?
    var submitChat: (() -> Void)?
    private func isSendChord(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        return [36, 76].contains(event.keyCode) && (modifiers == .command || modifiers == .control)
    }
    private func handleSendChord(_ event: NSEvent) {
        guard !event.isARepeat, isEditable else { return }
        // Candidates belong to the IME. A send chord never emits unfinished
        // pinyin or clears composition; confirm candidates before sending.
        guard !hasMarkedText() else { return }
        committedEdit?(self); submitChat?()
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isSendChord(event), window == nil || window?.firstResponder === self { handleSendChord(event); return true }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if isSendChord(event) { handleSendChord(event); return }
        super.keyDown(with: event)
    }
    var placeholder = "" { didSet { if oldValue != placeholder { needsDisplay = true } } }
    var placeholderColor = NSColor(Theme.muted) { didSet { needsDisplay = true } }
    override func paste(_ sender: Any?) {
        if NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil) || !((NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []).isEmpty { finishComposition(); mediaPaste?() }
        else { super.paste(sender) }
    }
    override func insertText(_ insertString: Any, replacementRange: NSRange) { super.insertText(insertString, replacementRange: replacementRange); if !hasMarkedText() { committedEdit?(self) } }
    override func unmarkText() { super.unmarkText(); committedEdit?(self) }
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { finishComposition() }
        return resigned
    }
    func finishComposition() {
        if hasMarkedText() { unmarkText(); inputContext?.discardMarkedText() }
        committedEdit?(self)
    }
    static func finishFocusedComposition() {
        guard let editor = NSApp.keyWindow?.firstResponder as? MediaTextView else { return }
        if editor.hasMarkedText(), let window = editor.window { window.makeFirstResponder(nil) }
        editor.finishComposition()
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty, !hasMarkedText(), !placeholder.isEmpty {
            NSAttributedString(string: placeholder, attributes: [.font: font ?? Theme.editorFont, .foregroundColor: placeholderColor])
                .draw(in: NSRect(x: textContainerInset.width, y: textContainerInset.height, width: max(0, bounds.width - textContainerInset.width * 2), height: max(0, bounds.height - textContainerInset.height * 2)))
        }
    }
}

private struct ChatMaterialPreview: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    let material: ChatMaterial
    var compact = false
    @EnvironmentObject var model: AppModel
    @State private var image: CGImage?
    var body: some View {
        Group {
            if let image { Image(decorative: image, scale: 2, orientation: .up).resizable().scaledToFit().frame(maxWidth: compact ? 64 : 270, maxHeight: compact ? 48 : 160).accessibilityLabel(material.name) }
            else { Label(compact ? "" : material.name, systemImage: material.mimeType.hasPrefix("audio/") ? "waveform" : "paperclip").font(Theme.label).foregroundStyle(Theme.secondary) }
        }.task(id: material.id + ":" + material.path + ":" + String(material.byteCount) + ":" + String(compact)) {
            guard material.mimeType.hasPrefix("image/") else { image = nil; return }
            let result = try? await MaterialThumbnailCache.shared.image(path: material.path, workspace: model.store.root, maximumPixels: compact ? 128 : 540)
            guard !Task.isCancelled else { return }; image = result?.image
        }.onDisappear { image = nil }
    }
}
