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
    @State private var closing = false
    @State private var error = ""
    @State private var showCC = false
    @State private var autosave: Task<Void, Never>?
    @State private var rich = true
    @State private var connecting = false
    @StateObject private var richActions = RichTextActions()
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(L10n.t("写邮件")).font(Theme.title); Spacer(); Text(L10n.t("草稿自动保存在本机")).font(Theme.label).foregroundStyle(Theme.muted); Button { close() } label: { Image(systemName: "xmark") }.buttonStyle(IconButtonStyle()).help(L10n.t("关闭并保留草稿")) }
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 12) {
                GridRow { Text(L10n.t("发件人")).foregroundStyle(Theme.muted); Picker(L10n.t("发件人"), selection: $draft.accountID) { ForEach(model.accounts) { a in Text(a.name + " <" + a.email + ">").tag(a.id) } }.labelsHidden() }
                GridRow { Text(L10n.t("收件人")).foregroundStyle(Theme.muted); HStack { TextField(L10n.t("name@example.com，多个地址用逗号分隔"), text: $draft.to).textFieldStyle(PaperFieldStyle()).accessibilityLabel(L10n.t("收件人")); Button(showCC ? L10n.t("收起") : L10n.t("抄送/密送")) { showCC.toggle() }.buttonStyle(.link).font(Theme.label) } }
                if showCC { GridRow { Text(L10n.t("抄送")).foregroundStyle(Theme.muted); TextField("name@example.com", text: $draft.cc).textFieldStyle(PaperFieldStyle()).accessibilityLabel(L10n.t("抄送")) }; GridRow { Text(L10n.t("密送")).foregroundStyle(Theme.muted); TextField("name@example.com", text: $draft.bcc).textFieldStyle(PaperFieldStyle()).accessibilityLabel(L10n.t("密送")) } }
                GridRow { Text(L10n.t("主题")).foregroundStyle(Theme.muted); TextField(L10n.t("邮件主题"), text: $draft.subject).textFieldStyle(PaperFieldStyle()).accessibilityLabel(L10n.t("主题")) }
            }
            Divider().overlay(Theme.rule)
            HStack(spacing: 16) {
                Toggle(L10n.t("格式化正文"), isOn: $rich).toggleStyle(.checkbox).font(Theme.label)
                if rich {
                    Button { richActions.toggle(.boldFontMask) } label: { Image(systemName: "bold") }.buttonStyle(IconButtonStyle()).help(L10n.t("粗体"))
                    Button { richActions.toggle(.italicFontMask) } label: { Image(systemName: "italic") }.buttonStyle(IconButtonStyle()).help(L10n.t("斜体"))
                    Button { richActions.underline() } label: { Image(systemName: "underline") }.buttonStyle(IconButtonStyle()).help(L10n.t("下划线"))
                    Button { richActions.link() } label: { Image(systemName: "link") }.buttonStyle(IconButtonStyle()).help(L10n.t("添加链接"))
                }; Spacer()
            }
            if rich { RichMailEditor(text: $draft.body, html: $draft.htmlBody, actions: richActions).frame(minHeight: 240).background(Theme.sheet) }
            else { TextEditor(text: $draft.body).font(Theme.reader).lineSpacing(5).scrollContentBackground(.hidden).frame(minHeight: 240).padding(8).background(Theme.sheet).accessibilityLabel(L10n.t("邮件正文")) }
            if !draft.attachments.isEmpty {
                ScrollView(.horizontal) { HStack(spacing: 16) { ForEach(draft.attachments) { a in HStack(spacing: 8) { Image(systemName: "paperclip"); Text(a.name).lineLimit(1); Text(a.size).foregroundStyle(Theme.muted); Button { draft.attachments.removeAll { $0.id == a.id }; saveSoon() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help(L10n.t("移除附件")) }.font(Theme.label).padding(10).background(Theme.paper) } } }
            }
            if !inline { HStack { TextField(L10n.t("交给伙伴：例如把这封邮件改得更简洁"), text: $prompt).textFieldStyle(PaperFieldStyle()).accessibilityLabel(L10n.t("给伙伴的写作委托")); Button(busy ? L10n.t("准备中…") : L10n.t("帮我写")) { generate() }.buttonStyle(QuietButtonStyle()).disabled(busy) } }
            if schedule { DatePicker(L10n.t("发送时间"), selection: $date, in: Date()...).datePickerStyle(.compact) }
            if !error.isEmpty { Text(error).font(Theme.label).foregroundStyle(Theme.error).textSelection(.enabled) }
            if !canSend { HStack { Text(L10n.t("示例邮箱不能发送。连接真实邮箱后可以发送这份草稿。")).font(Theme.label).foregroundStyle(Theme.muted); Button(L10n.t("连接邮箱")) { connecting = true }.buttonStyle(.link).font(Theme.label) } }
            HStack(spacing: 16) {
                Button { attach() } label: { Label(L10n.t("附件"), systemImage: "paperclip") }.buttonStyle(.link)
                Toggle(L10n.t("定时发送"), isOn: $schedule).toggleStyle(.checkbox).font(Theme.label)
                Spacer()
                Button(L10n.t("保留草稿")) { close() }.buttonStyle(QuietButtonStyle())
                Button(schedule ? L10n.t("安排发送") : L10n.t("发送")) {
                    if rich { richActions.flush?() } else { draft.htmlBody = nil }
                    draft.scheduledAt = schedule ? date : nil
                    do { try draft.validate(); busy = true; closing = true; autosave?.cancel(); Task { do { try await model.queueSend(draft); finishClose() } catch { closing = false; self.error = error.localizedDescription }; busy = false } } catch { self.error = error.localizedDescription }
                }.buttonStyle(PrimaryButtonStyle()).disabled(busy || !canSend || !editable || model.partnerBusy)
            }
        }.padding(28).frame(width: inline ? nil : 820, height: inline ? nil : (showCC ? 790 : 720)).background(Theme.paper)
            .onAppear { draft = initial; showCC = !draft.cc.isEmpty || !draft.bcc.isEmpty; if let scheduled = draft.scheduledAt { date = max(scheduled, Date()); schedule = true } }
            .onChange(of: draft.body) { saveSoon() }.onChange(of: draft.subject) { saveSoon() }.onChange(of: draft.to) { saveSoon() }.onChange(of: draft.cc) { saveSoon() }.onChange(of: draft.bcc) { saveSoon() }.onChange(of: draft.accountID) { saveSoon() }.onChange(of: draft.htmlBody) { saveSoon() }
            .onChange(of: model.composer?.updatedAt) { if inline, let updated = model.composer, updated.id == draft.id, updated.updatedAt != draft.updatedAt { draft = updated } }
            .onChange(of: rich) { if !rich { richActions.flush?(); draft.htmlBody = nil } }
            .onDisappear { autosave?.cancel(); if !closing && editable { Task { await model.saveDraft(draft) } } }
            .sheet(isPresented: $connecting) { AccountSetupView().environmentObject(model) }
            .onChange(of: model.accounts.count) { if !canSend, let account = model.realAccounts.last { draft.accountID = account.id } }
    }
    private var editable: Bool { !["sent", "queued", "sending", "uncertain"].contains(initial.state) }
    private var canSend: Bool { model.accounts.contains { $0.id == draft.accountID && !$0.isDemo && $0.enabled } }
    private func finishClose() { if inline { model.composer = nil } else { dismiss() } }
    private func saveSoon() { guard editable else { return }; if inline { model.composer = draft }; autosave?.cancel(); autosave = Task { try? await Task.sleep(for: .milliseconds(700)); if !Task.isCancelled && !closing && !busy { await model.saveDraft(draft) } } }
    private func close() { closing = true; autosave?.cancel(); Task { if editable { await model.saveDraft(draft) }; finishClose() } }
    private func generate() {
        busy = true; error = ""; Task {
            do { let result = try await model.partner.draft(instruction: prompt.isEmpty ? L10n.t("请根据现有主题和正文完成邮件正文，不编造事实。") : prompt, mails: [MailMessage(accountID: draft.accountID, from: .init(email: draft.to), subject: draft.subject, text: draft.body)], settings: model.settings); draft.htmlBody = nil; draft.body = result.text; await model.saveDraft(draft) } catch { self.error = error.localizedDescription }; busy = false
        }
    }
    private func attach() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            let urls = panel.urls, draftID = draft.id, accountID = draft.accountID
            Task {
                do {
                    var additions: [MailAttachment] = []
                    let gmail = model.accounts.first(where: { $0.id == accountID })?.imapHost == "imap.gmail.com"
                    let maximumTotal = (gmail ? 25 : 100) * 1024 * 1024
                    var totalBytes = draft.attachments.reduce(0) { $0 + max($1.byteCount, $1.data.count) }
                    for url in urls {
                        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                        let values = try url.resourceValues(forKeys: [.fileSizeKey])
                        guard let size = values.fileSize, size <= maximumTotal - totalBytes else { throw MailError.message(L10n.t("附件合计超过大小限制，请使用网盘链接。")) }
                        let data = try await Task.detached(priority: .utility) { try BoundedFileReader.read(url, maximumBytes: 25 * 1024 * 1024) }.value
                        guard data.count <= maximumTotal - totalBytes else { throw MailError.message(L10n.t("附件合计超过大小限制，请使用网盘链接。")) }
                        totalBytes += data.count
                        additions.append(.init(name: url.lastPathComponent, mimeType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream", data: data))
                    }
                    guard draft.id == draftID, editable, !closing else { return }
                    draft.attachments.append(contentsOf: additions); saveSoon()
                } catch { self.error = error.localizedDescription }
            }
        }
    }
}
