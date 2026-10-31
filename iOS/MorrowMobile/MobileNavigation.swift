import SwiftUI
import MorrowCore

enum MobileTab: Int, Hashable { case work, mail, people, attachments }
enum MobileRoute: Hashable { case mail(String), contact(String), attachment(String), connectMailbox(String), drafts, memory, responders, settings }
struct MobileComposerContext { let previous: WorkspaceContext?; let tab: MobileTab }

/// Immutable host boundary captured before a planning turn. It deliberately
/// separates a directory's scope from mail bodies actually given to the model.
struct MobileMailTurnScope {
    let context: WorkspaceContext
    let modelContext: WorkspaceContext
    let accounts: [MailAccount]
    let mails: [MailMessage]
    let allowedIDs: Set<String>
    let initialCandidates: [MailMessage]
    let mailbox: String
    init(context original: WorkspaceContext?, accounts availableAccounts: [MailAccount], mails availableMails: [MailMessage], folders: [MailFolder], fallbackAccountID: String, fallbackFilter: String, capturedAt: Date = Date()) {
        var scope = original ?? WorkspaceContext(page: "work", label: "工作")
        let knownIDs = Set(availableAccounts.map(\.id))
        let mailbox = scope.accountID ?? fallbackAccountID
        self.mailbox = mailbox
        let accountIDs = scope.mailList?.accountIDs ?? (mailbox.isEmpty ? availableAccounts.map(\.id) : [mailbox])
        let boundAccounts = availableAccounts.filter { accountIDs.contains($0.id) }
        var descriptor = scope.mailList ?? MailListContextDescriptor(accountIDs: accountIDs.filter(knownIDs.contains), destination: ["mail", "mail-list"].contains(scope.page) ? scope.filter ?? fallbackFilter : "all", capturedAt: capturedAt,
            folderRoles: Dictionary(folders.map { (MailListContextDescriptor.folderKey(accountID: $0.accountID, path: $0.path), $0.role) }, uniquingKeysWith: { first, _ in first }))
        descriptor.accountIDs = descriptor.accountIDs.filter(knownIDs.contains)
        let explicit = scope.hasExplicitMailSelection && (scope.page != "mail" || scope.mailIDs.count == 1)
        let originalIDs = Set(scope.mailIDs)
        let own = Dictionary(boundAccounts.map { ($0.id, $0.email) }, uniquingKeysWith: { first, _ in first })
        let captured: [MailMessage]
        if scope.page == "materials" { captured = [] }
        else {
            captured = availableMails.filter { mail in
                guard descriptor.accountIDs.contains(mail.accountID) else { return false }
                if !originalIDs.isEmpty && !originalIDs.contains(mail.id) { return false }
                if !explicit && !descriptor.matches(mail, ownEmail: own[mail.accountID]) { return false }
                if let contact = scope.contactEmail {
                    return ContactProfileBuilder.participants(mail).contains { $0.email.caseInsensitiveCompare(contact) == .orderedSame }
                }
                return true
            }
        }
        if !explicit {
            // Preserve legacy pinned IDs in the host boundary, but describe new
            // lists by portable filters and never send their complete ID set.
            scope.mailList = descriptor
            if scope.page == "mail" { scope.page = "mail-list" }
        }
        let capturedByID = Dictionary(captured.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let initial = explicit ? Array(scope.mailIDs.compactMap { capturedByID[$0] }.prefix(18)) : []
        var model = scope
        model.mailIDs = initial.map(\.id)
        model.attachmentIDs = explicit ? Array(scope.attachmentIDs.prefix(8)) : []
        model.mailList?.folderRoles = [:]
        self.context = scope; self.modelContext = model; self.accounts = boundAccounts
        self.mails = captured; self.allowedIDs = Set(captured.map(\.id))
        self.initialCandidates = initial
    }
}

extension MobileModel {
    func pathBinding(_ tab: MobileTab) -> Binding<[MobileRoute]> {
        Binding(get: { self.path(tab) }, set: { value in self.setPath(value, tab: tab); self.refreshVisibleContext() })
    }
    func path(_ tab: MobileTab) -> [MobileRoute] {
        switch tab { case .work: return workPath; case .mail: return mailPath; case .people: return peoplePath; case .attachments: return attachmentsPath }
    }
    func setPath(_ value: [MobileRoute], tab: MobileTab) {
        switch tab { case .work: workPath = value; case .mail: mailPath = value; case .people: peoplePath = value; case .attachments: attachmentsPath = value }
    }
    func displaySessionTitle(_ value: ChatSession?) -> String {
        guard let value else { return "Morrow" }
        return value.title == "新对话" ? MobileL10n.text("新对话") : value.title
    }
    func captureComposerContext(previous: WorkspaceContext?) {
        guard context?.page == "draft", let id = context?.draftID ?? workingDraft?.id,
              composerContexts[id] == nil, previous?.page != "draft" else { return }
        composerContexts[id] = MobileComposerContext(previous: previous, tab: selectedTab)
    }
    func restoreComposerContext(draftID: String) {
        guard let saved = composerContexts.removeValue(forKey: draftID),
              context?.page == "draft", context?.draftID == draftID else { return }
        // A newer route or explicit UI choice owns the current context.
        if selectedTab == saved.tab { context = saved.previous }
        else { refreshVisibleContext() }
    }
    func refreshVisibleContext() {
        guard workingDraft == nil else { return }
        if let route = path(selectedTab).last {
            switch route {
            case .mail(let id): if let mail = mails.first(where: { $0.id == id }) { context = mailContext(mail) }
            case .contact(let email): if let profile = profiles.first(where: { $0.email == email }) { context = contactContext(profile) }
            case .attachment(let id): if let item = attachments.first(where: { $0.id == id || $0.attachment.id == id }) { context = attachmentContext(item) }
            case .drafts: context = pageContext("drafts", label: MobileL10n.text("草稿"))
            case .memory: context = pageContext("memory", label: MobileL10n.text("记忆"))
            case .responders: context = pageContext("responders", label: MobileL10n.text("响应器"))
            case .settings: context = pageContext("settings", label: MobileL10n.text("设置"))
            case .connectMailbox: context = pageContext("settings", label: MobileL10n.text("连接邮箱"))
            }
        } else {
            switch selectedTab {
            case .work: context = pageContext("work", label: MobileL10n.text("工作"))
            case .mail: updateInboxContext()
            case .people: context = pageContext("contacts", label: MobileL10n.text("联系人"))
            case .attachments: context = pageContext("attachments", label: MobileL10n.text("附件"))
            }
        }
    }
    func pageContext(_ page: String, label: String) -> WorkspaceContext { var value = WorkspaceContext(page: page, label: label); value.accountID = ""; return value }
    func mailContext(_ mail: MailMessage) -> WorkspaceContext { var value = WorkspaceContext(page: "mail", label: mail.subject, mailIDs: [mail.id]); value.accountID = mail.accountID; return value }
    func contactContext(_ profile: ContactProfile) -> WorkspaceContext { var value = WorkspaceContext(page: "contacts", label: profile.name.isEmpty ? profile.email : profile.name, contactEmail: profile.email); value.accountID = ""; return value }
    func attachmentContext(_ item: MailAttachmentRecord) -> WorkspaceContext { var value = WorkspaceContext(page: "attachments", label: item.attachment.name, mailIDs: [item.mail.id], attachmentIDs: [item.attachment.id]); value.accountID = item.mail.accountID; return value }
    func updateInboxContext() {
        guard selectedTab == .mail, mailPath.isEmpty, workingDraft == nil else { return }
        let resultIDs = query.isEmpty ? [] : searchHits.map(\.id)
        var value = WorkspaceContext(page: resultIDs.isEmpty ? "mail-list" : "mail-results", label: query.isEmpty ? mailFilterLabel : MobileL10n.text("搜索邮件") + ": " + query, mailIDs: resultIDs)
        value.accountID = accountID; value.filter = mailFilter; value.query = query.isEmpty ? nil : query
        if resultIDs.isEmpty { value.mailList = currentMailListDescriptor(account: accountID) }
        context = value
    }
    func currentMailListDescriptor(account: String, filter: String? = nil, capturedAt: Date = Date()) -> MailListContextDescriptor {
        MailListContextDescriptor(accountIDs: account.isEmpty ? accounts.map(\.id) : [account], destination: filter ?? mailFilter, capturedAt: capturedAt,
            folderRoles: Dictionary(folders.map { (MailListContextDescriptor.folderKey(accountID: $0.accountID, path: $0.path), $0.role) }, uniquingKeysWith: { first, _ in first }))
    }
    func captureMailTurnScope(_ scope: WorkspaceContext?) -> MobileMailTurnScope {
        MobileMailTurnScope(context: scope, accounts: accounts, mails: mails, folders: folders, fallbackAccountID: accountID, fallbackFilter: mailFilter)
    }
    var mailFilterLabel: String {
        MobileL10n.text(["inbox": "邮件", "unread": "未读", "all": "全部", "sent": "已发送", "starred": "星标", "archive": "归档", "trash": "废纸篓"][mailFilter] ?? "邮件")
    }
    func mailMatchesFilter(_ mail: MailMessage) -> Bool {
        switch mailFilter {
        case "all": return true
        case "unread": return !mail.isRead
        case "starred": return mail.isStarred
        case "sent", "archive", "trash": return folders.first(where: { $0.accountID == mail.accountID && $0.path == mail.folder })?.role == mailFilter || mail.folder.caseInsensitiveCompare(["sent": "Sent", "archive": "Archive", "trash": "Trash"][mailFilter] ?? "") == .orderedSame
        default: return mail.folder.uppercased() == "INBOX"
        }
    }
    private func preserveEditorBeforeNavigation() async throws {
        for _ in 0..<2 {
            guard let snapshot = captureDraft() else { return }
            try await saveDraft(snapshot.draft)
            if draftOwner == snapshot.owner && workingDraftRevision == snapshot.revision { return }
        }
        throw MailError.message("草稿仍在编辑，已保留输入；请结束编辑后再切换页面。")
    }
    private func publishNavigation(_ tab: MobileTab, route: MobileRoute?, context value: WorkspaceContext, mailbox: String? = nil) async throws {
        try await preserveEditorBeforeNavigation()
        if let mailbox { accountID = mailbox }
        selectedTab = tab; setPath(route.map { [$0] } ?? [], tab: tab); context = value
        compose = nil; showChat = false; navigationRevision += 1
    }
    func openNativeMail(_ mail: MailMessage) async throws { try await publishNavigation(.mail, route: .mail(mail.id), context: mailContext(mail), mailbox: mail.accountID) }
    func openNativeMailboxConnection(_ hint: String) async throws { try await publishNavigation(.work, route: .connectMailbox(hint), context: pageContext("settings", label: MobileL10n.text("连接邮箱"))) }
    func openNativeContact(_ profile: ContactProfile) async throws { try await publishNavigation(.people, route: .contact(profile.email), context: contactContext(profile)) }
    func openNativeAttachment(_ item: MailAttachmentRecord) async throws { try await publishNavigation(.attachments, route: .attachment(item.id), context: attachmentContext(item)) }
    func showNativeSearch(_ query: String, hits: [SearchHit], mailbox: String) async throws {
        self.query = query; searchHits = hits
        var scope = WorkspaceContext(page: "mail-results", label: MobileL10n.text("搜索邮件") + ": " + query, mailIDs: hits.map(\.id)); scope.accountID = mailbox; scope.query = query
        try await publishNavigation(.mail, route: nil, context: scope, mailbox: mailbox)
    }
    func navigateNative(_ target: String, mailbox: String) async throws {
        guard mailbox.isEmpty || accounts.contains(where: { $0.id == mailbox }) else { throw MailError.message("邮箱不存在，页面没有切换。") }
        let name = target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch name {
        case "工作", "工作台", "work", "仕事": try await publishNavigation(.work, route: nil, context: pageContext("work", label: MobileL10n.text("工作")))
        case "邮件", "收件箱", "mail", "inbox", "メール", "受信トレイ", "已发送", "sent", "送信済み", "星标", "starred", "归档", "archive", "废纸篓", "trash", "ゴミ箱":
            query = ""; mailFilter = ["已发送": "sent", "sent": "sent", "送信済み": "sent", "星标": "starred", "starred": "starred", "归档": "archive", "archive": "archive", "废纸篓": "trash", "trash": "trash", "ゴミ箱": "trash"][name] ?? "inbox"
            var scope = WorkspaceContext(page: "mail-list", label: mailFilterLabel); scope.accountID = mailbox; scope.filter = mailFilter; scope.mailList = currentMailListDescriptor(account: mailbox)
            try await publishNavigation(.mail, route: nil, context: scope, mailbox: mailbox)
        case "联系人", "people", "contacts", "連絡先": try await publishNavigation(.people, route: nil, context: pageContext("contacts", label: MobileL10n.text("联系人")))
        case "附件", "attachments", "files", "添付ファイル": try await publishNavigation(.attachments, route: nil, context: pageContext("attachments", label: MobileL10n.text("附件")))
        case "草稿", "drafts", "下書き": try await publishNavigation(.work, route: .drafts, context: pageContext("drafts", label: MobileL10n.text("草稿")))
        case "记忆", "memory", "メモリー": try await publishNavigation(.work, route: .memory, context: pageContext("memory", label: MobileL10n.text("记忆")))
        case "响应器", "responders", "自動応答": try await publishNavigation(.work, route: .responders, context: pageContext("responders", label: MobileL10n.text("响应器")))
        case "设置", "settings", "設定": try await publishNavigation(.work, route: .settings, context: pageContext("settings", label: MobileL10n.text("设置")))
        default: throw MailError.message("尚无对应原生页面: " + target)
        }
    }
}

struct MobileContactReader: View {
    @EnvironmentObject var model: MobileModel
    let email: String
    var profile: ContactProfile? { model.profiles.first { $0.email == email } }
    var body: some View {
        List {
            if let profile {
                Section {
                    Text(profile.name.isEmpty ? profile.email : profile.name).font(.title2).fontWeight(.semibold)
                    Text(profile.email).foregroundStyle(.secondary).accessibilityIdentifier("contact.email")
                    Text("\(profile.received) received / \(profile.sent) sent").font(.caption)
                }
                Section(MobileL10n.text("邮件")) {
                    ForEach(model.mails.filter { profile.mailIDs.contains($0.id) }) { mail in NavigationLink(mail.subject, value: MobileRoute.mail(mail.id)) }
                }
                if !profile.claims.isEmpty { Section { ForEach(profile.claims) { claim in Text(claim.text) } } }
            }
        }.navigationTitle(MobileL10n.text("联系人")).navigationBarTitleDisplayMode(.inline)
            .onAppear { if let profile { model.context = model.contactContext(profile) } }
    }
}

struct MobileDraftLibrary: View {
    @EnvironmentObject var model: MobileModel
    var body: some View { List { ForEach(model.drafts.filter { $0.state == "draft" }) { draft in Button(draft.subject.isEmpty ? MobileL10n.text("草稿") : draft.subject) { model.compose = draft } } }.navigationTitle(MobileL10n.text("草稿")) }
}
