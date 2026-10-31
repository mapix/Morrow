import SwiftUI
import MorrowCore
import WebKit
import AppKit

struct ReaderView: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    @EnvironmentObject var model: AppModel
    var mail: MailMessage
    @State private var plainText = false
    @State private var remoteImages = false
    @State private var showingDetails = false
    @State private var label = ""
    @State private var note = ""
    @State private var document: ReaderDocument?
    @State private var bodySource: ReaderBodySource?
    @State private var bodySelection = ReaderBodySelection()
    @State private var bodyRetry = 0
    @State private var loading = true
    @State private var failure: String?
    @State private var related: [RelatedMail] = []
    @State private var relatedLimit = 50
    init(mail: MailMessage) {
        self.mail = mail
        _remoteImages = State(initialValue: MailReadingPreferences.loadsExternalImages())
    }
    private struct RelatedMail: Identifiable { var id: String; var sender: String; var date: Date }
    private struct Preparation: Equatable {
        var id: String; var version: String; var ready: Bool; var plain: Bool; var remote: Bool; var theme: String; var language: String
    }
    private var bodyRequest: ReaderBodyRequest { .init(id: mail.id, version: mail.bodyVersion, retry: bodyRetry) }
    private var preparation: Preparation { .init(id: mail.id, version: bodySource?.version ?? mail.bodyVersion, ready: bodySource != nil, plain: plainText, remote: remoteImages, theme: Theme.current.rawValue, language: L10n.languageCode) }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Theme.rule)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    Text(mail.subject).font(Theme.readerTitle).lineLimit(2).textSelection(.enabled).help(mail.subject)
                    Spacer(minLength: 8)
                    Button { showingDetails.toggle() } label: { Image(systemName: "info.circle").font(Theme.actionIcon) }.buttonStyle(.plain).foregroundStyle(Theme.muted).help(L10n.t("邮件详情"))
                        .popover(isPresented: $showingDetails) { details.frame(width: 480, height: 520) }
                }
                HStack(spacing: 10) {
                    Text(mail.from.display).font(Theme.body.weight(.medium)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(mail.date.uiFormatted(date: .abbreviated, time: .shortened)).font(Theme.small).foregroundStyle(Theme.muted)
                }
                HStack(spacing: 10) {
                    MailReadState(read: mail.isRead)
                    if !mail.attachments.isEmpty { Button { showingDetails = true } label: { Label("\(mail.attachments.count)", systemImage: "paperclip") }.buttonStyle(.plain).font(Theme.label).foregroundStyle(Theme.muted) }
                    Spacer()
                    if bodySource?.html.isEmpty == false {
                        Picker(L10n.t("正文显示方式"), selection: $plainText) {
                            Text(L10n.t("原始排版")).tag(false)
                            Text(L10n.t("纯文本")).tag(true)
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 170)
                    }
                }
            }.padding(.horizontal, 20).padding(.vertical, 16)
            if let action = mail.analysis?.action, mail.actionable && !mail.actionDone {
                HStack(spacing: 8) {
                    Image(systemName: "checklist").foregroundStyle(Theme.accent2).accessibilityHidden(true)
                    Text(action).font(Theme.label).lineLimit(2)
                    Spacer(minLength: 8)
                    Button(L10n.t("判断依据")) { showingDetails = true }.buttonStyle(.link).font(Theme.label)
                }.padding(.horizontal, 20).padding(.vertical, 10).background(Theme.paper)
            }
            Divider().overlay(Theme.rule)
            ZStack {
                if let document {
                    SecureHTMLView(document: document, failure: $failure).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else { Theme.sheet }
                if loading && document == nil { ProgressView(L10n.t("正在准备正文…")).font(Theme.label) }
                if failure != nil {
                    VStack(spacing: 12) {
                        Text(L10n.t("正文暂时无法显示，请切换纯文本重试。")).font(Theme.label)
                        Button(L10n.t("显示纯文本")) { plainText = true; failure = nil; document = nil; bodySource = nil; bodyRetry += 1 }.buttonStyle(QuietButtonStyle())
                    }.padding(24).background(Theme.sheet)
                }
            }
            HStack(spacing: 8) {
                Image(systemName: remoteImages ? "photo" : "shield.lefthalf.filled").accessibilityHidden(true)
                Text(remoteImages ? L10n.t("外部图片已启用，脚本仍被阻止。") : L10n.t("外部图片和脚本已阻止。链接需点击后打开。")).lineLimit(1)
                Spacer(minLength: 4)
                if document?.hasRemoteImages == true && !plainText {
                    Button(remoteImages ? L10n.t("阻止外部图片") : L10n.t("加载外部图片")) { remoteImages.toggle() }
                        .buttonStyle(.link).help(L10n.t("加载外部图片可能通知发件人此邮件已打开。"))
                }
            }.font(Theme.small).foregroundStyle(Theme.muted).padding(.horizontal, 20).padding(.vertical, 8)
            Divider().overlay(Theme.rule)
            HStack(spacing: 18) {
                Button { Task { await model.compose(replyTo: mail) } } label: { Label(L10n.t("回复"), systemImage: "arrowshape.turn.up.left") }.buttonStyle(CompactButtonStyle())
                Menu(L10n.t("更多")) {
                    Button(L10n.t("回复全部")) { Task { await model.compose(replyTo: mail, replyAll: true) } }
                    Button(L10n.t("转发")) { Task { await model.compose(replyTo: mail, forward: true) } }
                }.menuStyle(.borderlessButton).font(Theme.label).fixedSize()
                Spacer(minLength: 0)
                Button { model.prepareWorkChat(for: mail) } label: { Label(L10n.t("委托"), systemImage: "bubble.left") }.buttonStyle(.plain).font(Theme.label).foregroundStyle(Theme.accent2)
            }.padding(.horizontal, 20).padding(.vertical, 14)
        }.background(Theme.sheet)
        .onAppear { note = mail.note }
        .onChange(of: mail.note) { if !showingDetails { note = mail.note } }
        .onChange(of: presentationState.loadExternalImagesByDefault) { remoteImages = presentationState.loadExternalImagesByDefault }
        .task(id: bodyRequest) {
            let request = bodyRequest, ticket = bodySelection.begin(bodyRequest)
            if bodySource?.id != request.id { bodySource = nil; document = nil }
            loading = true
            do {
                let source = try await ReaderBodySource.load(id: request.id, store: model.store)
                guard !Task.isCancelled, bodySelection.accepts(ticket), source.id == request.id else { return }
                bodySource = source; failure = nil
            } catch { if !Task.isCancelled, bodySelection.accepts(ticket) { bodySource = nil; loading = false; failure = "body_unavailable" } }
        }
        .task(id: model.mailRevision) {
            related = model.relatedMails(to: mail).map { RelatedMail(id: $0.id, sender: $0.from.display, date: $0.date) }
        }
        .task(id: preparation) {
            guard let source = bodySource else { return }
            let preparationStarted = ProcessInfo.processInfo.systemUptime
            let input = ReaderDocumentInput(mailID: source.id, body: plainText || source.html.isEmpty ? source.text : source.html,
                usesHTML: !plainText && !source.html.isEmpty, allowsRemoteImages: remoteImages,
                themeCSS: Theme.htmlTokens, emptyMessage: L10n.t("此邮件没有可显示的纯文本正文。"), blockedImageLabel: L10n.t("外部图片已阻止"), attachments: source.attachments)
            loading = true
            do {
                let result = try await ReaderDocumentCache.shared.prepare(input)
                guard !Task.isCancelled, bodySource?.id == source.id, bodySource?.version == source.version else { return }
                if document?.id != result.id { document = result; failure = nil }
                loading = false
                MailReaderMetrics.record("document_prepared", since: preparationStarted)
            } catch { if !Task.isCancelled { loading = false; failure = "preparation" } }
        }
        .onDisappear { bodySelection.cancel(); bodySource = nil; document = nil }

    }
    private var toolbar: some View {
        HStack(spacing: 6) {
            Button { model.selectedID = nil } label: { Image(systemName: "xmark") }.buttonStyle(IconButtonStyle()).help(L10n.t("关闭阅读"))
            Spacer()
            Button { Task { await model.star(mail) } } label: { Image(systemName: mail.isStarred ? "star.fill" : "star") }.buttonStyle(IconButtonStyle()).help(L10n.t("星标邮件"))
            Menu {
                Button(L10n.t("今天晚些时候")) { Task { await model.snooze(mail, hours: 3) } }
                Button(L10n.t("明天")) { Task { await model.snooze(mail, hours: 24) } }
                Button(L10n.t("下周")) { Task { await model.snooze(mail, hours: 168) } }
                Button(L10n.t("取消稍后处理")) { Task { await model.snooze(mail, hours: 0) } }
            } label: { Image(systemName: "clock").frame(width: 44, height: 44) }.menuStyle(.borderlessButton).frame(width: 44, height: 44).help(L10n.t("稍后处理"))
            Button { Task { await model.move(mail, role: "archive") } } label: { Image(systemName: "archivebox") }.buttonStyle(IconButtonStyle()).help(L10n.t("归档"))
            Button { Task { await model.move(mail, role: "trash") } } label: { Image(systemName: "trash") }.buttonStyle(IconButtonStyle()).help(L10n.t("移到废纸篓"))
            Menu {
                Button(mail.isRead ? L10n.t("标记未读") : L10n.t("标记已读")) { Task { await model.markRead(mail, !mail.isRead) } }
                Button(L10n.t("导出原始邮件…")) { Task { await model.export(mail) } }
                Menu(L10n.t("移动到")) { ForEach(model.folders.filter { $0.accountID == mail.accountID }) { folder in Button(folder.name) { Task { await model.move(mail, folder: folder) } } } }
            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.menuStyle(.borderlessButton).frame(width: 44, height: 44).help(L10n.t("更多邮件操作"))
        }.padding(.horizontal, 20).frame(height: 52)
    }
    private var details: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(L10n.t("邮件详情")).font(Theme.heading)
                Text(mail.subject).font(Theme.body.weight(.medium)).textSelection(.enabled)
                Text(mail.from.display + " <" + mail.from.email + ">").font(Theme.label).textSelection(.enabled)
                Text(L10n.t("收件人：") + mail.to.map(\.display).joined(separator: ", ")).font(Theme.label).textSelection(.enabled)
                if !mail.cc.isEmpty { Text(L10n.t("抄送：") + mail.cc.map(\.display).joined(separator: ", ")).font(Theme.label) }
                if let analysis = mail.analysis {
                    Divider()
                    HStack { Text(L10n.t("伙伴读到了这些")).font(Theme.body.weight(.medium)); Spacer(); Button { Task { await model.reanalyze(mail) } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).disabled(model.partnerBusy).help(L10n.t("重新分析")) }
                    Text(analysis.summary).font(Theme.reader).textSelection(.enabled)
                    Text(analysis.source == "规则分析" ? L10n.t("规则整理") : analysis.source).font(Theme.small).foregroundStyle(Theme.muted)
                    if let action = analysis.action {
                        Text(action).font(Theme.body.weight(.medium))
                        if let due = analysis.deadline { Text(L10n.t("截止：") + due.uiFormatted()).font(Theme.label).foregroundStyle(Theme.error) }
                        Button(mail.actionDone ? L10n.t("重新打开") : L10n.t("完成")) { Task { await model.complete(mail) } }.buttonStyle(.link)
                    }
                    if !analysis.reasoning.isEmpty { DisclosureGroup(L10n.t("判断依据")) { Text(analysis.reasoning).font(Theme.label).textSelection(.enabled) } }
                    if !analysis.replySuggestion.isEmpty {
                        DisclosureGroup(L10n.t("已准备的回复建议")) {
                            Text(analysis.replySuggestion).font(Theme.reader).textSelection(.enabled).padding(.vertical, 8)
                            Button(L10n.t("用这份建议回复")) { Task { await model.compose(replyTo: mail, suggested: true) } }.buttonStyle(QuietButtonStyle())
                        }
                    }
                }
                if !mail.attachments.isEmpty {
                    Divider(); Text(L10n.t("附件")).font(Theme.body.weight(.medium))
                    ForEach(document?.invitations ?? []) { invitation in InvitationView(invitation: invitation, mail: mail) }
                    ForEach(mail.attachments) { attachment in
                        HStack(spacing: 10) {
                            Image(systemName: "paperclip").foregroundStyle(Theme.muted).accessibilityHidden(true)
                            Button(attachment.name) { Task { await model.attachment(attachment) } }.buttonStyle(.link).lineLimit(1)
                            Spacer(); Text(attachment.size).font(Theme.small).foregroundStyle(Theme.muted)
                            Menu {
                                Button(L10n.t("查看提取文字")) { Task { await model.previewText(attachment) } }
                                Button(L10n.t("重新提取文字")) { Task { await model.previewText(attachment, force: true) } }
                                Button(L10n.t("保存附件")) { Task { await model.attachment(attachment, save: true) } }
                            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 28)
                        }
                    }
                }
                Divider()
                DisclosureGroup(L10n.t("标签与笔记")) {
                    VStack(alignment: .leading, spacing: 10) {
                        if !mail.labels.isEmpty { Text(mail.labels.joined(separator: ", ")).font(Theme.label) }
                        HStack { TextField(L10n.t("新标签"), text: $label).textFieldStyle(PaperFieldStyle()); Button(L10n.t("添加")) { let value = label.trimmingCharacters(in: .whitespaces); guard !value.isEmpty else { return }; Task { await model.update(mail) { if !$0.labels.contains(value) { $0.labels.append(value) } } }; label = "" }.buttonStyle(.link) }
                        TextEditor(text: $note).font(Theme.body).frame(height: 90)
                        Button(L10n.t("保存笔记")) { Task { await model.update(mail) { $0.note = note } } }.buttonStyle(.link)
                    }.padding(.top, 10)
                }
                if !related.isEmpty {
                    DisclosureGroup(L10n.format("同一主题的通信 ({0})", "\(related.count)")) {
                        LazyVStack(spacing: 4) {
                            ForEach(related.prefix(relatedLimit)) { item in Button { if let target = model.mails.first(where: { $0.id == item.id }) { model.select(target) }; showingDetails = false } label: { HStack { Text(item.sender).lineLimit(1); Spacer(); Text(item.date.uiFormatted(date: .abbreviated, time: .omitted)) }.padding(.vertical, 8) }.buttonStyle(.link) }
                            if relatedLimit < related.count { Button(L10n.t("显示更多")) { relatedLimit += 50 }.buttonStyle(.link) }
                        }
                    }
                }
            }.font(Theme.label).padding(24).foregroundStyle(Theme.ink)
        }.background(Theme.sheet)
    }
}

struct SecureHTMLView: NSViewRepresentable {
    let document: ReaderDocument
    @Binding var failure: String?
    func makeCoordinator() -> Coordinator { Coordinator(failure: $failure) }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = ReaderWebKitContext.dataStore
        configuration.processPool = ReaderWebKitContext.processPool
        configuration.setURLSchemeHandler(context.coordinator.assets, forURLScheme: "morrow-cid")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator; view.uiDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        context.coordinator.view = view
        // CSP is installed before original head content; this extra WebKit rule
        // blocks remote resources even if an email contains malformed markup.
        context.coordinator.policyTask = Task { @MainActor [weak coordinator = context.coordinator] in
            let rules = await ReaderNetworkPolicy.compiledLists()
            guard !Task.isCancelled, let coordinator, !coordinator.disposed else { return }
            coordinator.rules = rules; coordinator.ready = true; coordinator.loadPending()
        }
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        guard !context.coordinator.disposed else { return }
        context.coordinator.failure = $failure
        context.coordinator.pending = document
        context.coordinator.loadPending()
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.dispose()
        view.stopLoading(); view.navigationDelegate = nil; view.uiDelegate = nil
        view.loadHTMLString("", baseURL: nil)
    }
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        weak var view: WKWebView?
        var loaded = ""
        var disposed = false
        var policyTask: Task<Void, Never>?
        private var navigationStarted = ProcessInfo.processInfo.systemUptime
        var ready = false
        fileprivate var rules = ReaderNetworkLists()
        var pending: ReaderDocument?
        var failure: Binding<String?>
        let assets = ReaderInlineAssetHandler()
        init(failure: Binding<String?>) { self.failure = failure }
        func dispose() {
            disposed = true; policyTask?.cancel(); policyTask = nil; pending = nil; view = nil; failure = .constant(nil); assets.releaseAssets()
        }
        func loadPending() {
            guard !disposed, ready, let view, let document = pending else { return }
            pending = nil
            guard loaded != document.id else { return }
            loaded = document.id
            assets.replace(host: document.host, assets: document.assets)
            view.configuration.userContentController.removeAllContentRuleLists()
            if let rule = document.allowsRemoteImages ? (rules.images ?? rules.blocked) : rules.blocked { view.configuration.userContentController.add(rule) }
            navigationStarted = ProcessInfo.processInfo.systemUptime
            view.loadHTMLString(document.content, baseURL: nil)
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let scheme = navigationAction.request.url?.scheme?.lowercased() ?? ""
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url, ["https", "http", "mailto"].contains(scheme) { NSWorkspace.shared.open(url); decisionHandler(.cancel) }
            else if scheme == "about" || scheme == "data" { decisionHandler(.allow) }
            else { decisionHandler(.cancel) }
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { MailReaderMetrics.record("navigation_finished", since: navigationStarted) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { report(error) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { report(error) }
        private func report(_ error: Error) { if !disposed, (error as NSError).code != NSURLErrorCancelled { failure.wrappedValue = "navigation" } }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    }
}

final class ReaderInlineAssetHandler: NSObject, WKURLSchemeHandler {
    private var host = ""
    private var assets: [String: ReaderInlineAsset] = [:]
    private var pending: [ObjectIdentifier: UUID] = [:]
    private let queue: OperationQueue = { let q = OperationQueue(); q.maxConcurrentOperationCount = 2; q.qualityOfService = .utility; return q }()
    func replace(host: String, assets: [String: ReaderInlineAsset]) { cancelAll(); self.host = host; self.assets = assets }
    func cancelAll() { pending.removeAll(); queue.cancelAllOperations() }
    func releaseAssets() { cancelAll(); host = ""; assets.removeAll() }
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, url.host == host,
              let id = String(url.path.dropFirst()).removingPercentEncoding, let asset = assets[id] else {
            urlSchemeTask.didFailWithError(URLError(.resourceUnavailable)); return
        }
        let key = ObjectIdentifier(urlSchemeTask), ticket = UUID(); pending[key] = ticket
        queue.addOperation { [weak self] in
            let data: Data?
            if !asset.data.isEmpty { data = asset.data.count <= 10 * 1024 * 1024 ? asset.data : nil }
            else if let path = asset.path { data = try? BoundedFileReader.read(URL(fileURLWithPath: path), maximumBytes: 10 * 1024 * 1024) }
            else { data = nil }
            DispatchQueue.main.async {
                guard let self, self.pending[key] == ticket else { return }; self.pending.removeValue(forKey: key)
                guard let data else { urlSchemeTask.didFailWithError(URLError(.resourceUnavailable)); return }
                urlSchemeTask.didReceive(URLResponse(url: url, mimeType: asset.mimeType, expectedContentLength: data.count, textEncodingName: nil))
                urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
            }
        }
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) { pending.removeValue(forKey: ObjectIdentifier(urlSchemeTask)) }
}

@MainActor private enum ReaderWebKitContext {
    static let processPool = WKProcessPool()
    static let dataStore = WKWebsiteDataStore.nonPersistent()
}

private struct ReaderNetworkLists: @unchecked Sendable {
    var blocked: WKContentRuleList?
    var images: WKContentRuleList?
}

@MainActor private enum ReaderNetworkPolicy {
    private static var compilation: Task<ReaderNetworkLists, Never>?
    static func compiledLists() async -> ReaderNetworkLists {
        if let compilation { return await compilation.value }
        let task = Task { @MainActor in
            let blocked = await compile("MorrowReaderBlockRemoteV1", imageException: false)
            let images = await compile("MorrowReaderImagesOnlyV1", imageException: true)
            return ReaderNetworkLists(blocked: blocked, images: images)
        }
        compilation = task; return await task.value
    }
    private static func compile(_ identifier: String, imageException: Bool) async -> WKContentRuleList? {
        let exception = imageException ? ",{\"trigger\":{\"url-filter\":\"^https?://\",\"resource-type\":[\"image\"]},\"action\":{\"type\":\"ignore-previous-rules\"}}" : ""
        let rules = "[{\"trigger\":{\"url-filter\":\"^https?://\"},\"action\":{\"type\":\"block\"}}" + exception + "]"
        return await withCheckedContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: rules) { list, _ in continuation.resume(returning: list) }
        }
    }
}
