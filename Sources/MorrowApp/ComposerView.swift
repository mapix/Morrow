import SwiftUI
import MorrowCore
import AppKit
import UniformTypeIdentifiers

struct ComposerView: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    var inline = false
    var initial: ComposeDraft
    @State private var draft = ComposeDraft()
    @State private var schedule = false
    @State private var date = Date().addingTimeInterval(3600)
    @State private var prompt = ""
    @State private var busy = false
    @State private var saving = false
    @State private var closing = false
    @State private var error = ""
    @State private var showCC = false
    @State private var autosave: Task<Void, Never>?
    @State private var rich = true
    @State private var previewing = false
    @State private var connecting = false
    @State private var previewAttachment: MailAttachment?
    @StateObject private var richActions = RichTextActions()
    private var deliveryState: DraftPresentationState { .init(model.drafts.first { $0.id == initial.id }?.state ?? (draft.id == initial.id ? draft.state : initial.state)) }
    private var editable: Bool { deliveryState.editable && !closing }
    private var account: MailAccount? { model.accounts.first { $0.id == draft.accountID } }
    private var canSend: Bool { editable && account.map { !$0.isDemo && $0.enabled } == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(editable ? (previewing ? L10n.t("邮件预览") : L10n.t("新邮件")) : deliveryState.title).font(Theme.heading)
                Spacer(minLength: 8)
                Text(editable ? L10n.t(saving ? "正在保存…" : "自动保存到草稿") : deliveryState.receipt).font(Theme.small).foregroundStyle(deliveryState == .uncertain ? Theme.error : Theme.secondary).lineLimit(1)
                if editable {
                    Button { richActions.flush?(); previewing.toggle() } label: { Image(systemName: previewing ? "square.and.pencil" : "eye") }.buttonStyle(IconButtonStyle()).accessibilityIdentifier("draft.toggle-preview").help(L10n.t(previewing ? "返回编辑" : "预览效果"))
                }
                Button { close() } label: { Image(systemName: "xmark") }.buttonStyle(IconButtonStyle()).help(L10n.t(editable ? "关闭并保留草稿" : "关闭"))
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                if editable {
                GridRow { fieldTitle("发件人"); Picker(L10n.t("发件人"), selection: $draft.accountID) { ForEach(model.accounts) { a in Text((a.name.isEmpty ? "" : a.name + " ") + "<" + a.email + ">").tag(a.id) } }.labelsHidden().controlSize(.small).frame(maxWidth: .infinity, alignment: .leading) }
                GridRow { fieldTitle("收件人"); HStack(spacing: 8) { addressField("收件人", text: $draft.to, prompt: L10n.t("多个地址用逗号分隔")); Button(showCC ? L10n.t("收起") : L10n.t("抄送/密送")) { showCC.toggle() }.buttonStyle(.plain).font(Theme.label).foregroundStyle(Theme.secondary) } }
                if showCC {
                    GridRow { fieldTitle("抄送"); addressField("抄送", text: $draft.cc) }
                    GridRow { fieldTitle("密送"); addressField("密送", text: $draft.bcc) }
                }
                GridRow { fieldTitle("主题"); addressField("主题", text: $draft.subject, prompt: L10n.t("邮件主题")) }
                } else {
                    GridRow { fieldTitle("发件人"); recordField(account.map { ($0.name.isEmpty ? "" : $0.name + " ") + "<" + $0.email + ">" } ?? L10n.t("尚未选择发件邮箱")) }
                    GridRow { fieldTitle("收件人"); recordField(draft.to) }
                    if !draft.cc.isEmpty { GridRow { fieldTitle("抄送"); recordField(draft.cc) } }
                    if !draft.bcc.isEmpty { GridRow { fieldTitle("密送"); recordField(draft.bcc) } }
                    GridRow { fieldTitle("主题"); recordField(draft.subject) }
                }
            }.disabled(editable && busy)
            Divider().overlay(Theme.rule)
            if editable {
                HStack(spacing: 8) {
                    Toggle(L10n.t("格式化正文"), isOn: $rich).toggleStyle(.checkbox).font(Theme.label)
                    if rich {
                        Button { richActions.toggle(.boldFontMask) } label: { Image(systemName: "bold") }.buttonStyle(IconButtonStyle()).help(L10n.t("粗体"))
                        Button { richActions.toggle(.italicFontMask) } label: { Image(systemName: "italic") }.buttonStyle(IconButtonStyle()).help(L10n.t("斜体"))
                        Button { richActions.underline() } label: { Image(systemName: "underline") }.buttonStyle(IconButtonStyle()).help(L10n.t("下划线"))
                        Button { richActions.link() } label: { Image(systemName: "link") }.buttonStyle(IconButtonStyle()).help(L10n.t("添加链接"))
                    }
                    Spacer()
                }.disabled(busy)
            }
            Group {
                if previewing || !editable { DraftBodyPreview(draft: draft) }
                else if rich { RichMailEditor(text: $draft.body, html: $draft.htmlBody, actions: richActions) }
                else { TextEditor(text: $draft.body).font(Theme.reader).lineSpacing(4).scrollContentBackground(.hidden).padding(8).accessibilityLabel(L10n.t("邮件正文")) }
            }.frame(minHeight: 180, maxHeight: .infinity).background(Theme.sheet)
            if !draft.attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 12) { ForEach(draft.attachments) { attachment in
                        HStack(spacing: 6) {
                            Button { previewAttachment = attachment } label: { Label(attachment.name, systemImage: "paperclip").lineLimit(1) }.buttonStyle(.plain).help(L10n.t("查看附件：") + attachment.name)
                            Text(attachment.size).foregroundStyle(Theme.muted)
                            if editable { Button { draft.attachments.removeAll { $0.id == attachment.id }; saveSoon() } label: { Image(systemName: "xmark") }.buttonStyle(IconButtonStyle()).help(L10n.t("移除附件")) }
                        }.font(Theme.label).padding(.vertical, 4)
                    } }
                }.frame(maxHeight: 40)
            }
            if !inline && editable {
                HStack(spacing: 8) { TextField(L10n.t("告诉伙伴如何修改这封邮件"), text: $prompt).textFieldStyle(PaperFieldStyle()).accessibilityLabel(L10n.t("给伙伴的写作委托")); Button(L10n.t(busy ? "准备中…" : "帮我写")) { generate() }.buttonStyle(QuietButtonStyle()) }.disabled(busy)
            }
            if editable && schedule { DatePicker(L10n.t("发送时间"), selection: $date, in: Date()...).datePickerStyle(.compact).font(Theme.label) }
            if !error.isEmpty { Text(error).font(Theme.label).foregroundStyle(Theme.error).textSelection(.enabled) }
            if editable, let account, account.isDemo { Text(L10n.t("演示邮箱只保存草稿，不发送真实邮件。")).font(Theme.label).foregroundStyle(Theme.secondary) }
            else if editable && (account == nil || account?.enabled == false) {
                HStack { Text(L10n.t(account == nil ? "请选择发件邮箱" : "发件邮箱已停用")).font(Theme.label).foregroundStyle(Theme.secondary); Button(L10n.t("邮箱设置")) { connecting = true }.buttonStyle(.plain).font(Theme.label) }
            }
            HStack(spacing: 12) {
                if editable {
                    Button { attach() } label: { Label(L10n.t("附件"), systemImage: "paperclip") }.buttonStyle(CompactButtonStyle()).disabled(busy)
                    Toggle(L10n.t("定时发送"), isOn: $schedule).toggleStyle(.checkbox).font(Theme.label).disabled(busy)
                    Spacer()
                    Button(L10n.t("保留草稿")) { close() }.buttonStyle(QuietButtonStyle()).disabled(busy)
                    Button(L10n.t(schedule ? "安排发送" : "发送")) { send() }.buttonStyle(PrimaryButtonStyle()).disabled(busy || !canSend || model.partnerBusy).accessibilityIdentifier("draft.send")
                } else {
                    if deliveryState == .uncertain { Button(L10n.t("查看已发送")) { model.dismissInlineTools(); model.navigate(.sent) }.buttonStyle(CompactButtonStyle()) }
                    Spacer(); Button(L10n.t("关闭")) { close() }.buttonStyle(QuietButtonStyle())
                }
            }
        }.padding(24).frame(minWidth: inline ? nil : 640, idealWidth: inline ? nil : 760, minHeight: inline ? nil : 560, idealHeight: inline ? nil : 680).background(Theme.paper)
            .onAppear { draft = initial; showCC = !initial.cc.isEmpty || !initial.bcc.isEmpty; previewing = !deliveryState.editable; if let value = initial.scheduledAt { date = max(value, Date()); schedule = true } }
            .onChange(of: draft.body) { saveSoon() }.onChange(of: draft.subject) { saveSoon() }.onChange(of: draft.to) { saveSoon() }.onChange(of: draft.cc) { saveSoon() }.onChange(of: draft.bcc) { saveSoon() }.onChange(of: draft.accountID) { saveSoon() }.onChange(of: draft.htmlBody) { saveSoon() }
            .onChange(of: deliveryState) { state in if !state.editable { autosave?.cancel(); previewing = true; if let value = model.drafts.first(where: { $0.id == initial.id }) { draft = value } } }
            .onChange(of: model.composer?.updatedAt) { if inline, let value = model.composer, value.id == initial.id, value.updatedAt != draft.updatedAt { draft = value } }
            .onChange(of: rich) { if editable && !rich { richActions.flush?(); draft.htmlBody = nil } }
            .onDisappear { autosave?.cancel(); if !closing && deliveryState.editable { let value = draft; Task { await model.saveDraft(value) } } }
            .sheet(isPresented: $connecting) { AccountSetupView().environmentObject(model) }
            .sheet(item: $previewAttachment) { attachment in AttachmentPreviewView(attachment: attachment).environmentObject(model) }
    }
    private func fieldTitle(_ key: String) -> some View { Text(L10n.t(key)).font(Theme.label).foregroundStyle(Theme.secondary).frame(width: 48, alignment: .leading) }
    private func addressField(_ key: String, text: Binding<String>, prompt: String = "") -> some View { TextField(prompt, text: text).textFieldStyle(.plain).font(Theme.body).padding(.vertical, 6).overlay(alignment: .bottom) { Rectangle().fill(Theme.rule).frame(height: 1) }.accessibilityLabel(L10n.t(key)) }
    private func recordField(_ value: String) -> some View { Text(value).font(Theme.body).foregroundStyle(Theme.ink).lineLimit(3).textSelection(.enabled).help(value).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading) }
    private func finishClose() { if inline { model.composer = nil } else { dismiss() } }
    private func saveSoon() {
        guard editable else { return }; if inline { model.composer = draft }; autosave?.cancel()
        autosave = Task { try? await Task.sleep(for: .milliseconds(700)); guard !Task.isCancelled, editable, !busy else { return }; saving = true; let value = draft; await model.saveDraft(value); saving = false }
    }
    private func close() {
        guard !closing else { return }
        richActions.flush?(); autosave?.cancel()
        if !deliveryState.editable { closing = true; finishClose(); return }
        closing = true; let value = draft
        Task {
            await model.saveDraft(value)
            guard let saved = model.drafts.first(where: { $0.id == value.id }), model.sameDraftContent(saved, value) else { closing = false; error = model.error ?? L10n.t("草稿未能保存，请重试"); return }
            finishClose()
        }
    }
    private func send() {
        guard editable, canSend, !busy else { return }
        if rich && !previewing { richActions.flush?() } else if !rich { draft.htmlBody = nil }
        draft.scheduledAt = schedule ? date : nil
        do { try draft.validate(); busy = true; closing = true; autosave?.cancel(); let value = draft; Task { do { try await model.queueSend(value); finishClose() } catch { closing = false; self.error = error.localizedDescription }; busy = false } }
        catch { self.error = error.localizedDescription }
    }
    private func generate() {
        guard editable, !busy else { return }; busy = true; error = ""; let value = draft
        Task {
            do {
                let result = try await model.partner.draft(instruction: prompt.isEmpty ? L10n.t("请根据现有主题和正文完成邮件正文，不编造事实。") : prompt, mails: [MailMessage(accountID: value.accountID, from: .init(email: value.to), subject: value.subject, text: value.body)], settings: model.settings)
                guard editable, draft.id == value.id else { busy = false; return }
                guard model.sameDraftContent(draft, value) else { error = L10n.t("你在生成时修改了草稿，编辑内容已保留"); busy = false; return }
                draft.htmlBody = nil; draft.body = result.text; await model.saveDraft(draft)
            } catch { self.error = error.localizedDescription }; busy = false
        }
    }
    private func attach() {
        guard editable, !busy else { return }
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        let completed: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }; let urls = panel.urls, draftID = draft.id, accountID = draft.accountID
            Task {
                do {
                    var additions: [MailAttachment] = []
                    let maximumTotal = (model.accounts.first(where: { $0.id == accountID })?.imapHost == "imap.gmail.com" ? 25 : 100) * 1024 * 1024
                    var total = draft.attachments.reduce(0) { $0 + max($1.byteCount, $1.data.count) }
                    for url in urls {
                        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                        let maximum = min(25 * 1024 * 1024, maximumTotal - total)
                        guard maximum > 0 else { throw MailError.message(L10n.t("附件合计超过大小限制，请使用网盘链接。")) }
                        let data = try await Task.detached(priority: .utility) { try BoundedFileReader.read(url, maximumBytes: maximum) }.value
                        total += data.count; additions.append(.init(name: url.lastPathComponent, mimeType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream", data: data))
                    }
                    guard draft.id == draftID, editable, !closing else { return }; draft.attachments.append(contentsOf: additions); saveSoon()
                } catch { self.error = error.localizedDescription }
            }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completed) } else { panel.begin(completionHandler: completed) }
    }
}
