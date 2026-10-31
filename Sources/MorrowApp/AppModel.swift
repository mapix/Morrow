import Foundation
import SwiftUI
import MorrowCore
import AppKit
import UniformTypeIdentifiers
import UserNotifications
import Contacts

enum Destination: String, CaseIterable, Identifiable {
    case partner = "伙伴", inbox = "收件箱", focus = "待处理", delegations = "委托", drafts = "草稿", starred = "星标", snoozed = "稍后处理", sent = "已发送", contacts = "联系人", trash = "废纸篓", settings = "设置"
    var id: String { rawValue }
    var icon: String {
        switch self { case .partner: return "sparkle"; case .inbox: return "tray"; case .focus: return "checklist"; case .delegations: return "arrow.triangle.branch"; case .drafts: return "doc"; case .starred: return "star"; case .snoozed: return "clock"; case .sent: return "paperplane"; case .contacts: return "person.2"; case .trash: return "trash"; case .settings: return "gearshape" }
    }
}

@MainActor final class AppModel: ObservableObject {
    @Published var accounts: [MailAccount] = [] { didSet { rebuildMailboxMetadata() } }
    @Published var folders: [MailFolder] = [] { didSet { rebuildMailboxMetadata() } }
    @Published var mails: [MailMessage] = [] { didSet { mailProjection.rebuild(mails); mailRevision += 1; visibleProjection = nil; scheduleSearchRefresh() } }
    @Published private(set) var mailRevision = 0
    private var mailProjection = MailProjectionCache()
    private var metadataRevision = 0
    private var mailboxEmails: [String: String] = [:]
    private var folderRoles: [String: String] = [:]
    private var visibleProjection: (MailViewProjectionKey, [MailMessage])?
    private var actionProjection: (Int, Int, Int)?
    private var unreadProjection: (Int, Int, [String: Int], Int)?
    private var searchResultsRevision = 0
    private var reloadEpoch = 0
    private var localMutationEpoch = 0
    private var localMutationVersions: [String: Int] = [:]
    private var bulkSeenOverrides: [BulkSeenKey: (Bool, Date)] = [:]
    @Published var drafts: [ComposeDraft] = []
    @Published var delegations: [Delegation] = []
    @Published var responders: [MailResponder] = []
    @Published var responderReceipts: [ResponderReceipt] = []
    @Published var responderBusy = false
    @Published var responderEditor: MailResponder?
    @Published var openUIInteractions: [OpenUIInteraction] = []
    @Published var events: [PartnerEvent] = []
    @Published var chat: [PartnerChat] = [] { didSet { chatsBySession = Dictionary(grouping: chat, by: { $0.sessionID ?? "legacy" }).mapValues { $0.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date } } } }
    private var chatsBySession: [String: [PartnerChat]] = [:]
    @Published var chatSessions: [ChatSession] = [] { didSet { sessionsByID = Dictionary(chatSessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }); let ordered = chatSessions.sorted { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }; activeSessionsProjection = ordered.filter { !$0.archived }; archivedSessionsProjection = ordered.filter(\.archived) } }
    private var sessionsByID: [String: ChatSession] = [:]
    private var activeSessionsProjection: [ChatSession] = []
    private var archivedSessionsProjection: [ChatSession] = []
    @Published var activeSessionID = "legacy"
    @Published var executingSessionID: String?
    @Published var scrollChatID: String?
    @Published var workspacePreferences = WorkspacePreferences()
    @Published var memories: [AgentMemory] = []
    @Published var memoryStatus = "本机记忆"
    @Published var accountSyncStates: [String: AccountSyncState] = [:]
    var sessionDraftTask: Task<Void, Never>?
    var memoryTask: Task<Void, Never>?
    var memoryExtractionTask: Task<Void, Never>?
    var memoryExtractionQueue: [PartnerChat] = []
    var memoryVectorBusy = false
    var retrievedMemoryIDs: [String: [String]] = [:]
    @Published var memoryRevealIDs: [String] = []
    @Published var contacts: [ContactEntry] = []
    @Published var contactProfiles: [ContactProfile] = []
    @Published var selectedContactEmail: String?
    @Published var selectedAttachmentIDs = Set<String>()
    @Published var attachmentQuery = ""
    @Published var attachmentKind = "全部"
    @Published var chatInput = ""
    @Published var chatFocusNonce = 0
    @Published var newChatWork = false
    @Published var visibleRunID: String?
    @Published var workingDraft: ComposeDraft?
    @Published var workingArtifactID: String?
    @Published var sidebarTask: Task<Void, Never>?
    @Published var chatMaterials: [ChatMaterial] = []
    @Published var chatPinnedContext: WorkspaceContext?
    @Published var chatExpanded = true
    @Published var profileStatus = "正在建立联系人索引"
    @Published var materialBusy = false
    var profileTask: Task<Void, Never>?
    var profileBuildBusy = false
    var profileInventory = ""
    @Published var agentRuns: [AgentRun] = []
    @Published var agentArtifacts: [AgentArtifact] = []
    @Published var agentDecisions: [AgentDecision] = []
    @Published var selectedRunID: String?
    @Published var workspacePage: WorkspacePage = .desk
    @Published var inspectorPage: InspectorPage = .artifacts
    @Published var focusMailSearch = false
    @Published var settings = AgentSettings()
    @Published var mailPageIndex = 0
    @Published var mailPageSize = MailPageWindow.preferredSize
    @Published var destination: Destination = .partner { didSet { if oldValue != destination { mailPageIndex = 0; if searchMode { search() } } } }
    @Published var selectedID: String?
    @Published var selectedAccount: String? { didSet { if oldValue != selectedAccount { mailPageIndex = 0; if searchMode { search() } } } }
    @Published var selectedFolder: String? { didSet { if oldValue != selectedFolder { mailPageIndex = 0; searchScope = selectedFolder == nil ? .mailbox : .currentView; if searchMode { search() } } } }
    @Published var searchText = "" { didSet { if oldValue != searchText { mailPageIndex = 0 } } }
    @Published var searchStrategy: MailSearchStrategy = .semantic { didSet { if searchMode && oldValue != searchStrategy { search() } } }
    @Published var searchScope: MailboxSearchScope = .mailbox { didSet { if searchMode && oldValue != searchScope { search() } } }
    @Published var searchStatus = ""
    @Published var searchFallback = false
    @Published private var storedSearchHits: [SearchHit] = []
    var searchHits: [SearchHit] {
        get {
            let current = mailProjection.byID
            let query = MailQuery(searchText)
            return storedSearchHits.compactMap { hit in
                guard let mail = current[hit.id], matchesSearchScope(mail), query.matches(mail) else { return nil }
                var updated = hit; updated.message = mail; return updated
            }
        }
        set { storedSearchHits = newValue; searchResultsRevision += 1; visibleProjection = nil }
    }
    @Published var searchBusy = false
    @Published var searchMode = false
    @Published var unreadOnly = false { didSet { if oldValue != unreadOnly { mailPageIndex = 0; if searchMode { search() } } } }
    @Published var category: MailCategory? { didSet { if oldValue != category { mailPageIndex = 0; if searchMode { search() } } } }
    @Published var syncBusy = false
    @Published var syncStatus = "尚未连接邮箱"
    @Published var indexStatus = "等待邮件"
    @Published var indexCount = 0
    @Published var partnerBusy = false
    @Published var partnerStatus = "随时可以把事情交给我"
    @Published var error: String?
    @Published var composer: ComposeDraft?
    @Published var showAccount = false
    @Published var suggestedAccount: String = ""
    @Published var mailboxConnectionStatus: String?
    @Published var showDelegation = false
    @Published var calendarDraft: CalendarInvitation?
    @Published var attachmentTextPreview: AttachmentTextPreview?
    @Published var attachmentTextBusy = false
    @Published var batchBusy = false
    @Published var batchStatus: String?
    @Published var undoLabel: String?
    @Published var models: [String] = []
    @Published var isDemo = false
    @Published var started = false
    @Published var ready = false
    private var timerTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private var indexFailure: String?
    private var analysisTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var searchRefreshTask: Task<Void, Never>?
    private var searchNeedsRefresh = false
    private var searchGeneration = 0
    private var undoAction: (() async -> Void)?
    private var undoing = false
    private var outboundBusy = false
    @Published var delegationBusy = false
    @Published var executingRunIDs = Set<String>()
    @Published var sidebarEvidenceMailIDs = Set<String>()
    @Published var sidebarToolStatus: String?
    private var lastSyncFailure: String?
    let store: MailStore
    let transport = MailTransport()
    let index = EmbeddingIndex()
    let partner = PartnerEngine()
    let ai = AIEngine()
    let credentials = AccountCredentials()
    lazy var cloudWorkspace = CloudWorkspaceModel(store: store)
    private let notifications: any MailNotificationManaging

    init(root: URL? = nil, notifications: (any MailNotificationManaging)? = nil) {
        self.notifications = notifications ?? NativeMailNotifications()
        let args = ProcessInfo.processInfo.arguments
        let customRoot = args.firstIndex(of: "--data-dir").flatMap { i in i + 1 < args.count ? URL(fileURLWithPath: args[i + 1]) : nil }
        let rememberedRoot = UserDefaults.standard.string(forKey: "SmailWorkspaceRoot").map { URL(fileURLWithPath: $0) }.flatMap { FileManager.default.fileExists(atPath: $0.appendingPathComponent("mail.sqlite").path) ? $0 : nil }
        do { store = try MailStore(root: root ?? customRoot ?? rememberedRoot) } catch { fatalError("无法打开 Morrow 邮件库：\(error.localizedDescription)") }
        if root == nil, let customRoot, !args.contains("--transient-workspace") { UserDefaults.standard.set(customRoot.path, forKey: "SmailWorkspaceRoot") }
    }
    var selected: MailMessage? { selectedID.flatMap { mailProjection.byID[$0] } }
    var realAccounts: [MailAccount] { accounts.filter { !$0.isDemo } }
    var mailCount: Int { mailProjection.primary.count }
    var primaryMails: [MailMessage] { mailProjection.primary }
    var attachmentProjection: [MailAttachmentRecord] { mailProjection.attachments }
    func relatedMails(to mail: MailMessage) -> [MailMessage] { mailProjection.related(to: mail) }
    func mailByID(_ id: String) -> MailMessage? { mailProjection.byID[id] }
    func mails(withIDs ids: [String]) -> [MailMessage] {
        var unique: [String: MailMessage] = [:]
        for id in ids { if let mail = mailProjection.byID[id], unique[mail.canonicalID] == nil || mail.folder.uppercased() == "INBOX" { unique[mail.canonicalID] = mail } }
        return unique.values.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
    }
    func chatHistory(in sessionID: String) -> [PartnerChat] { chatsBySession[sessionID] ?? [] }
    func cachedSession(_ id: String) -> ChatSession? { sessionsByID[id] }
    func orderedChatSessions(archived: Bool) -> [ChatSession] { archived ? archivedSessionsProjection : activeSessionsProjection }
    func projectedInboxUnreadCount(_ accountID: String?) -> Int {
        if let cached = unreadProjection, cached.0 == mailRevision, cached.1 == metadataRevision { return accountID.flatMap { cached.2[$0] } ?? (accountID == nil ? cached.3 : 0) }
        var counts: [String: Int] = [:]; var total = 0
        for mail in primaryMails where !mail.isRead && (folderRoles[mail.accountID + "\u{1f}" + mail.folder] ?? "inbox") == "inbox" { counts[mail.accountID, default: 0] += 1; total += 1 }
        unreadProjection = (mailRevision, metadataRevision, counts, total)
        return accountID.flatMap { counts[$0] } ?? (accountID == nil ? total : 0)
    }
    private func rebuildMailboxMetadata() {
        metadataRevision += 1; visibleProjection = nil
        mailboxEmails = Dictionary(accounts.map { ($0.id, $0.email.lowercased()) }, uniquingKeysWith: { first, _ in first })
        folderRoles = Dictionary(folders.map { ($0.accountID + "\u{1f}" + $0.path, $0.role) }, uniquingKeysWith: { first, _ in first })
    }
    var actionCount: Int {
        if let cached = actionProjection, cached.0 == mailRevision, cached.1 == metadataRevision { return cached.2 }
        let count = primaryMails.filter { m in let role = folderRoles[m.accountID + "\u{1f}" + m.folder]; return m.actionable && !isOutbound(m) && role != "trash" && role != "junk" }.count
        actionProjection = (mailRevision, metadataRevision, count); return count
    }
    var visibleMails: [MailMessage] {
        let key = MailViewProjectionKey(revision: mailRevision, metadata: metadataRevision, destination: destination.rawValue, account: selectedAccount, folder: selectedFolder, category: category?.rawValue, unread: unreadOnly, search: searchMode, query: searchText, strategy: searchStrategy.rawValue, scope: searchScope.rawValue, results: searchResultsRevision, clockBucket: Int(Date().timeIntervalSince1970 / 15))
        if let cached = visibleProjection, cached.0 == key { return cached.1 }
        if searchMode { let result = searchHits.map(\.message); visibleProjection = (key, result); return result }
        let filtered = mails.filter(matchesMailScope)
        var unique: [String: MailMessage] = [:]
        for mail in filtered { if unique[mail.canonicalID] == nil || mail.folder == "INBOX" { unique[mail.canonicalID] = mail } }
        let result = unique.values.sorted {
            if destination == .partner || destination == .focus { let a = $0.analysis?.priority ?? 0; let b = $1.analysis?.priority ?? 0; if a != b { return a > b } }; return $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date
        }
        visibleProjection = (key, result); return result
    }
    func matchesMailScope(_ mail: MailMessage) -> Bool {
        if let selectedAccount, mail.accountID != selectedAccount { return false }
        if let selectedFolder, mail.folder != selectedFolder { return false }
        if unreadOnly && mail.isRead { return false }
        if let category, mail.analysis?.category != category { return false }
        let role = folderRoles[mail.accountID + "\u{1f}" + mail.folder] ?? "inbox"
        switch destination {
        case .focus, .partner: return mail.actionable && !isOutbound(mail) && role != "trash" && role != "junk" && (mail.snoozedUntil == nil || mail.snoozedUntil! <= Date())
        case .starred: return mail.isStarred && role != "trash"
        case .snoozed: return mail.snoozedUntil.map { $0 > Date() } ?? false
        case .sent: return role == "sent"
        case .trash: return role == "trash"
        default: return selectedFolder != nil || role == "inbox"
        }
    }
    func isOutbound(_ mail: MailMessage) -> Bool {
        guard let ownEmail = mailboxEmails[mail.accountID], mail.from.email.lowercased() == ownEmail else { return false }
        return mail.to.contains { $0.email.lowercased() != ownEmail } || folderRoles[mail.accountID + "\u{1f}" + mail.folder] == "sent"
    }
    func start() async {
        guard !started else { return }; started = true
        defer { ready = true }
        do {
            if let acceptance = try AcceptanceRequest.parse() {
                let parent = store.root.deletingLastPathComponent().appendingPathComponent("MorrowAcceptance", isDirectory: true)
                let workspace = acceptance.workspace(in: parent)
                _ = await AcceptanceHarness().run(mode: acceptance.mode, id: acceptance.id, workspace: workspace, modelDir: acceptance.modelDirectory ?? Bundle.main.resourceURL?.appendingPathComponent("embeddinggemma-2"), peerBinding: acceptance.peerBinding)
                return
            }
            try importOAuthApplicationSecret()
            accounts = try await store.load(MailAccount.self, kind: "account")
            folders = try await store.load(MailFolder.self, kind: "folder")
            settings = try await store.load(AgentSettings.self, kind: "settings").first ?? AgentSettings()
            settings.replyLanguage = PresentationPreferences.shared.replyLanguageName
            drafts = try await store.load(ComposeDraft.self, kind: "draft")
            delegations = try await store.load(Delegation.self, kind: "delegation")
            responders = try await store.load(MailResponder.self, kind: "responder")
            responderReceipts = try await store.load(ResponderReceipt.self, kind: "responder-receipt")
            openUIInteractions = try await store.load(OpenUIInteraction.self, kind: "openui-interaction")
            events = try await store.load(PartnerEvent.self, kind: "event")
            chat = try await store.load(PartnerChat.self, kind: "chat")
            chatSessions = try await store.load(ChatSession.self, kind: "chat-session")
            workspacePreferences = try await store.load(WorkspacePreferences.self, kind: "workspace-preferences").first ?? WorkspacePreferences()
            memories = try await store.load(AgentMemory.self, kind: "agent-memory")
            for var status in try await store.load(AccountSyncState.self, kind: "account-sync-state") { status.syncing = false; accountSyncStates[status.accountID] = status }
            await restoreChatSessions()
            contacts = try await store.load(ContactEntry.self, kind: "contact")
            contactProfiles = try await store.load(ContactProfile.self, kind: "contact-profile")
            agentRuns = try await store.load(AgentRun.self, kind: "agent-run")
            agentArtifacts = try await store.load(AgentArtifact.self, kind: "agent-artifact")
            agentDecisions = try await store.load(AgentDecision.self, kind: "agent-decision")
            for var run in agentRuns where run.phase == .completed && delegations.contains(where: { $0.id == run.delegationID && $0.active }) {
                run.phase = .monitoring; run.summary = "已有成果已保留，委托仍在持续关注后续邮件。"; await saveRun(run)
            }
            // SMTP delivery may have succeeded before an interrupted process persisted its receipt.
            for i in drafts.indices where drafts[i].state == "sending" { drafts[i].state = "uncertain"; drafts[i].error = "上次发送被中断，请核对已发送邮箱后决定是否重发。"; try await store.save(drafts[i], kind: "draft", id: drafts[i].id) }
            if settings.embeddingDirectory.isEmpty {
                let bundleModel = Bundle.main.resourceURL?.appendingPathComponent("embeddinggemma-2")
                settings.embeddingDirectory = bundleModel.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("model.safetensors").path) ? $0.path : "" } ?? ""
                if settings.embeddingDirectory.isEmpty { settings.embeddingDirectory = store.root.appendingPathComponent("models/embeddinggemma-2").path }
            }
            isDemo = !accounts.isEmpty && accounts.allSatisfy(\.isDemo)
            if ProcessInfo.processInfo.arguments.contains("--demo"), accounts.isEmpty { await loadDemo() }
            await reload()
            if ProcessInfo.processInfo.arguments.contains("--agent-demo") { await installAgentDemoScenarios() }
            if ProcessInfo.processInfo.arguments.contains("--iteration-demo") { await installIterationDemo() }
            if ProcessInfo.processInfo.arguments.contains("--multi-demo") { await installMultiAccountDemo() }
            await migrateContactKnowledge(); scheduleMemoryIndex()
            cloudWorkspace.onImport = { [weak self] in await self?.reloadCloudWorkspace() }
            await cloudWorkspace.restore()
            if !realAccounts.isEmpty { Task { await sync() } }
            process()
            timerTask = Task { [weak self] in
                var lastSync = Date()
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(15))
                    guard let self else { return }
                    await self.runResponders(); await self.sendPending(); await self.runDelegations()
                    if Date().timeIntervalSince(lastSync) >= Double(max(60, self.settings.syncInterval)) {
                        lastSync = Date(); await self.sync(); self.process()
                    }
                }
            }
        } catch { self.error = error.localizedDescription }
    }
    func reload() async {
        reloadEpoch += 1; let request = reloadEpoch, mutationAtStart = localMutationEpoch
        do {
            var loaded = try await store.messages()
            guard request == reloadEpoch else { return }
            for i in loaded.indices {
                if (localMutationVersions[loaded[i].id] ?? 0) > mutationAtStart, let current = mailProjection.byID[loaded[i].id] { loaded[i] = current }
                loaded[i] = Self.validatedMail(loaded[i])
            }
            // Mutating a @Published array element republishes and copies the
            // entire array. Prepare locally, then publish one validated snapshot.
            mails = loaded; indexCount = try await store.indexCount(); isDemo = !accounts.isEmpty && accounts.allSatisfy(\.isDemo)
            await refreshContactProfiles()
            if isDemo { syncStatus = "示例工作区，未连接真实邮箱" }
            if processingTask == nil && indexCount > 0 && indexFailure == nil { indexStatus = "\(indexCount) 封邮件已建立向量索引" }
            if analysisTask == nil && !mails.isEmpty && primaryMails.allSatisfy({ $0.analysis != nil && $0.analysis?.source != "规则分析" }) { partnerStatus = "已整理，等待新邮件或你的委托" }
        } catch { self.error = error.localizedDescription }
    }
    private static func validatedMail(_ original: MailMessage) -> MailMessage {
        var mail = original
        if var analysis = mail.analysis {
            if analysis.deadline != nil { analysis.deadline = DeadlineEvidence.validated(analysis.deadline, quote: analysis.deadlineEvidence, original: mail.text + "\n" + (analysis.evidenceText ?? "")) }
            if ReplySuggestionPolicy.containsUnverifiedConfirmation(analysis.replySuggestion) { analysis.replySuggestion = ReplySuggestionPolicy.neutralReply(subject: mail.normalizedSubject, original: mail.text) }
            mail.analysis = analysis
        }
        return mail
    }
    func navigate(_ destination: Destination) { searchGeneration += 1; searchTask?.cancel(); searchRefreshTask?.cancel(); searchRefreshTask = nil; searchNeedsRefresh = false; searchMode = false; searchBusy = false; self.destination = destination; workspacePage = destination == .partner ? .desk : .mail; selectedAccount = nil; selectedFolder = nil; searchText = ""; searchScope = destination == .inbox ? .mailbox : .currentView; selectedID = nil; category = nil; unreadOnly = false }
    func select(_ mail: MailMessage) { selectedID = mail.id; if !mail.isRead { Task { await markRead(mail, true) } } }
    func saveSettings() async {
        settings.replyLanguage = PresentationPreferences.shared.replyLanguageName
        if !settings.enabled || !settings.autoAnalyze { analysisTask?.cancel(); profileTask?.cancel() }
        do { try await store.save(settings, kind: "settings", id: "main"); process() } catch { self.error = error.localizedDescription }
    }
    func configurationDidSave() {
        if !settings.enabled || !settings.autoAnalyze { analysisTask?.cancel(); profileTask?.cancel() }
        process()
    }
    func refreshModels() async { do { models = try await ai.configuredModels(settings: settings) } catch { self.error = error.localizedDescription } }

    func addAccount(_ account: MailAccount, password: String, storedSecret: String? = nil) async throws {
        try Task.checkCancellation()
        _ = try await transport.test(account, password: password)
        try Task.checkCancellation()
        try SecretStore.save(storedSecret ?? password, accountID: account.id)
        try await store.save(account, kind: "account", id: account.id)
        if let i = accounts.firstIndex(where: { $0.id == account.id }) { accounts[i] = account } else { accounts.append(account) }
        isDemo = false; showAccount = false; await log("邮箱已连接", detail: account.email, kind: "account")
        Task { await sync() }
    }
    func removeAccount(_ account: MailAccount) async {
        do { try await store.deleteAccount(account.id); SecretStore.delete(accountID: account.id); accounts.removeAll { $0.id == account.id }; folders.removeAll { $0.accountID == account.id }; await reload() } catch { self.error = error.localizedDescription }
    }
    func sync(accountID: String? = nil) async {
        guard !syncBusy, !realAccounts.isEmpty else { return }; syncBusy = true; defer { syncBusy = false }
        var failures: [String] = []; var newCount = 0
        for account in realAccounts where account.enabled && (accountID == nil || account.id == accountID) {
            let failureStart = failures.count; await setAccountSyncState(account, syncing: true)
            do {
                let secret = try await credentials.credential(account)
                syncStatus = "正在连接 \(account.name)"
                if account.usesPOP { let result = try await syncPOP(account, secret: secret); newCount += result.0; failures += result.1; await setAccountSyncState(account, syncing: false, error: result.1.isEmpty ? nil : result.1.joined(separator: "\n")); continue }
                let remoteFolders = try await transport.folders(account, password: secret)
                folders.removeAll { $0.accountID == account.id }; folders += remoteFolders
                for folder in remoteFolders {
                    try await store.save(folder, kind: "folder", id: folder.id)
                    syncStatus = "正在同步 \(account.name) / \(folder.name)"
                    let inventoryStarted = Date()
                    let (validity, flags) = try await transport.inventory(account, folder: folder.path, password: secret)
                    bulkSeenOverrides = bulkSeenOverrides.filter { key, value in key.account != account.id || key.folder != folder.path || (key.validity == validity && value.1 > inventoryStarted) }
                    let existing = try await store.syncRecords(account: account.id, folder: folder.path)
                    let byUID = Dictionary(uniqueKeysWithValues: existing.filter { $0.uidValidity == validity && $0.uid > 0 }.map { ($0.uid, $0) })
                    for (uid, flag) in flags.sorted(by: { $0.key > $1.key }) {
                        if let old = byUID[uid] {
                            guard var mail = try await store.message(old.id) else { continue }
                            if mail.localFlagModifiedAt.map({ $0 > inventoryStarted }) == true { continue }
                            let seen = bulkSeenValue(account: account.id, folder: folder.path, validity: validity, uid: uid, inventoryStarted: inventoryStarted)
                            if mail.isRead != (seen?.0 ?? flag.read) || mail.isStarred != flag.starred { mail.isRead = seen?.0 ?? flag.read; mail.isStarred = flag.starred; if let seen { mail.localFlagModifiedAt = seen.1 }; try await store.upsert(mail) }
                        } else {
                            do {
                                var mail = try await transport.fetch(account, folder: folder.path, uid: uid, validity: validity, password: secret)
                                let seen = bulkSeenValue(account: account.id, folder: folder.path, validity: validity, uid: uid, inventoryStarted: inventoryStarted)
                                mail.isRead = seen?.0 ?? flag.read; mail.isStarred = flag.starred; if let seen { mail.localFlagModifiedAt = seen.1 }; mail.analysis = PartnerEngine.baseline(mail)
                                try await store.upsert(mail); newCount += 1
                                if newCount % 10 == 0 { await reload(); process() }
                            } catch { failures.append(account.name + " / " + folder.name + " / UID \(uid)：" + error.localizedDescription) }
                        }
                    }
                    for old in existing where old.uid > 0 && (old.uidValidity != validity || flags[old.uid] == nil) { try await store.deleteMessage(old.id) }
                }
            } catch { failures.append(account.name + "：" + error.localizedDescription) }
            let ownFailures = Array(failures.dropFirst(failureStart)); await setAccountSyncState(account, syncing: false, error: ownFailures.isEmpty ? nil : ownFailures.joined(separator: "\n"))
        }
        await reload(); process()
        syncStatus = failures.isEmpty ? "同步于 " + Date().uiFormatted(date: .omitted, time: .shortened) : failures.joined(separator: "\n")
        if newCount > 0 { await log("收到 \(newCount) 封邮件", detail: "已存入本地邮件库，正在索引和整理。", kind: "sync") }
        if !failures.isEmpty { if syncStatus != lastSyncFailure { error = syncStatus }; lastSyncFailure = syncStatus } else { lastSyncFailure = nil }
    }
    private func syncPOP(_ account: MailAccount, secret: String) async throws -> (Int, [String]) {
        let defaults = try await transport.folders(account, password: secret)
        for folder in defaults where !folders.contains(where: { $0.id == folder.id }) { folders.append(folder); try await store.save(folder, kind: "folder", id: folder.id) }
        let inventory = try await transport.popInventory(account, password: secret)
        let known = Set(try await store.syncRecords(account: account.id).compactMap(\.popUID))
        var added = 0; var failures: [String] = []
        for (uid, number) in inventory.sorted(by: { $0.value > $1.value }) where !known.contains(uid) {
            syncStatus = "正在下载 \(account.name) / 邮件\(number)"
            do { var mail = try await transport.popFetch(account, uid: uid, number: number, password: secret); mail.analysis = PartnerEngine.baseline(mail); try await store.upsert(mail); added += 1; if added % 10 == 0 { await reload(); process() } }
            catch { failures.append(account.name + " / 邮件\(number)：" + error.localizedDescription) }
        }
        // POP3 has no server folders or read flags. Local mail remains after remote deletion.
        await transport.closePOP(account)
        return (added, failures)
    }
    func createFolder(_ account: MailAccount, name: String) async throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MailError.message("请填写文件夹名称。") }
        if account.usesPOP {
            let folder = MailFolder(accountID: account.id, path: name); try await store.save(folder, kind: "folder", id: folder.id); if !folders.contains(where: { $0.id == folder.id }) { folders.append(folder) }
        } else { try await transport.createFolder(account, path: name, password: credentials.credential(account)); await sync() }
    }

    func process() {
        scheduleProfileAnalysis()
        Task { await runResponders() }
        analyzeNew()
        guard processingTask == nil else { return }
        processingTask = Task { [weak self] in
            guard let self else { return }
            var continueBacklog = false
            defer { self.processingTask = nil; if continueBacklog && !Task.isCancelled { self.process() } }
            do { try await index.load(directory: settings.embeddingDirectory) }
            catch { indexFailure = error.localizedDescription; indexStatus = error.localizedDescription; return }
            let snapshot = mails.map(\.id)
            var lastRefresh = Date.distantPast
            var lastProgressUpdate = Date.distantPast
            for (i, messageID) in snapshot.enumerated() {
                if Task.isCancelled { return }
                // Re-read to preserve concurrent flags, notes and completion edits.
                guard let mail = try? await store.message(messageID) else { continue }
                if Date().timeIntervalSince(lastProgressUpdate) >= 1 || i == snapshot.count - 1 { indexStatus = "索引 \(i + 1) / \(snapshot.count)"; lastProgressUpdate = Date() }
                do {
                    let changed = try await index.index(mail, store: store, attachments: settings.indexAttachments)
                    if changed { indexFailure = nil }
                    if changed && Date().timeIntervalSince(lastRefresh) >= 1 { indexCount = try await store.indexCount(); scheduleSearchRefresh(); lastRefresh = Date() }
                } catch { indexFailure = error.localizedDescription; indexStatus = error.localizedDescription; return }
            }
            await reload()
            if indexFailure == nil { indexStatus = "\(indexCount) 封邮件已建立向量索引" }
            await runDelegations()
            continueBacklog = indexCount < mailCount
        }
    }
    private func analyzeNew() {
        guard analysisTask == nil, settings.enabled, settings.autoAnalyze else { return }
        analysisTask = Task { [weak self] in
            guard let self else { return }; defer { self.analysisTask = nil }
            let pendingIDs = mails.filter { $0.analysis == nil || $0.analysis?.source == "规则分析" || $0.analysis?.evidenceVersion != MailEvidence.version }.map(\.id)
            for id in pendingIDs {
                guard !Task.isCancelled, settings.enabled, settings.autoAnalyze else { return }
                guard let original = try? await store.message(id) else { continue }
                partnerStatus = "正在读：" + original.subject
                do {
                    let reused = mails.first { $0.canonicalID == original.canonicalID && $0.analysis?.evidenceVersion == MailEvidence.version && $0.analysis?.source != "规则分析" }?.analysis
                    let analysis: MailAnalysis
                    if let reused { analysis = reused } else { analysis = try await partner.analyze(MailEvidence.forAnalysis(original, store: store), settings: settings) }
                    guard var current = try await store.message(original.id) else { continue }
                    current.analysis = analysis; try await store.upsert(current)
                    if reused == nil && analysis.priority > 0 && current.actionable && !isOutbound(current) {
                        await log(analysis.action ?? "发现重要邮件", detail: analysis.summary, messageIDs: [current.id], kind: "attention")
                        await notify(id: "mail:" + current.id, title: "有件事需要你处理", body: analysis.action ?? current.subject)
                        if let deadline = analysis.deadline, deadline > Date() { await notify(id: "due:" + current.id, title: "事项即将到期", body: analysis.action ?? current.subject, at: max(Date().addingTimeInterval(1), deadline.addingTimeInterval(-1800))) }
                    }
                    await reload()
                } catch { partnerStatus = "模型暂不可用：" + error.localizedDescription; return }
            }
            partnerStatus = "已整理，等待新邮件或你的委托"; await runDelegations()
        }
    }
    func reanalyze(_ mail: MailMessage) async {
        guard !partnerBusy else { return }; partnerBusy = true; defer { partnerBusy = false }
        do { let analysis = try await partner.analyze(MailEvidence.forAnalysis(mail, store: store), settings: settings); guard var m = try await store.message(mail.id) else { return }; m.analysis = analysis; try await store.upsert(m); await reload() } catch { self.error = error.localizedDescription }
    }
    private func scheduleSearchRefresh() {
        // Sync/index reloads can arrive faster than retrieval completes. Let
        // the current query finish, then coalesce updates instead of cancelling
        // it on every new snapshot. Existing hits resolve against current mail.
        guard searchMode else { return }
        searchNeedsRefresh = true
        guard !searchBusy, searchRefreshTask == nil else { return }
        let query = searchText
        searchRefreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.searchRefreshTask = nil
            guard self.searchMode, self.searchText == query, !self.searchBusy else { return }
            self.search(preserveSelection: true)
        }
    }
    func search(preserveSelection: Bool = false) {
        searchRefreshTask?.cancel(); searchRefreshTask = nil
        searchNeedsRefresh = false; searchGeneration += 1
        let generation = searchGeneration
        searchTask?.cancel(); searchMode = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard searchMode else { searchHits = []; searchBusy = false; return }
        if !preserveSelection { selectedID = nil; searchHits = [] }
        searchBusy = true
        let query = searchText, strategy = searchStrategy
        searchStatus = strategy.title + "搜索中…"; searchFallback = false
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(250)); guard !Task.isCancelled else { return }
            do {
                let parsed = MailQuery(query)
                let allowedIDs = Set(mails.filter { matchesSearchScope($0) && parsed.matches($0) }.map(\.id))
                guard !allowedIDs.isEmpty else { searchHits = []; searchBusy = false; searchStatus = "当前范围没有邮件"; if searchNeedsRefresh { scheduleSearchRefresh() }; return }
                let hits: [SearchHit]
                var resultStatus = "", fallback = false
                if strategy == .keyword || parsed.text.isEmpty {
                    hits = try await store.keywordSearch(query, allowedIDs: allowedIDs)
                    resultStatus = parsed.text.isEmpty ? "条件筛选" : "关键词搜索"
                } else {
                    do {
                        try await index.load(directory: settings.embeddingDirectory)
                        let coverage = try await index.searchCoverage(store: store, allowedIDs: allowedIDs)
                        hits = try await index.search(query, store: store, allowedIDs: allowedIDs, strategy: strategy)
                        fallback = coverage.indexedCount == 0
                        resultStatus = (fallback ? "关键词搜索，语义索引尚未就绪" : strategy.title + "搜索，按相关度排序") + "；\(coverage.indexedCount)/\(coverage.eligibleCount)封已索引"
                    } catch {
                        guard !Task.isCancelled else { return }
                        hits = try await store.keywordSearch(query, allowedIDs: allowedIDs)
                        fallback = true; resultStatus = "已降级为关键词搜索：" + error.localizedDescription
                    }
                }
                guard !Task.isCancelled, generation == searchGeneration, query == searchText else { return }
                searchHits = hits; searchFallback = fallback; searchStatus = resultStatus; searchBusy = false
                if searchNeedsRefresh { scheduleSearchRefresh() }
            } catch { if !Task.isCancelled, generation == searchGeneration { self.error = error.localizedDescription; searchBusy = false; if searchNeedsRefresh { scheduleSearchRefresh() } } }
        }
    }
    func markRead(_ mail: MailMessage, _ value: Bool) async {
        await updateFlag(mail, flag: "\\Seen", value: value)
    }
    func star(_ mail: MailMessage) async { await updateFlag(mail, flag: "\\Flagged", value: !mail.isStarred) }
    private func updateFlag(_ mail: MailMessage, flag: String, value: Bool) async {
        do { replaceCachedMails([try await performFlag(mail, flag: flag, value: value)]) } catch { self.error = error.localizedDescription }
    }
    private func replaceCachedMails(_ updates: [MailMessage]) {
        guard !updates.isEmpty else { return }
        var updated = mails
        localMutationEpoch += 1
        for mail in updates { if let position = mailProjection.positions[mail.id], updated.indices.contains(position) { updated[position] = Self.validatedMail(mail); localMutationVersions[mail.id] = localMutationEpoch } }
        mails = updated
    }
    func cacheReadStates(_ states: [String: Bool], modifiedAt: Date) {
        guard !states.isEmpty else { return }
        var updated = mails; localMutationEpoch += 1
        for (id, value) in states { if let position = mailProjection.positions[id], updated.indices.contains(position) { updated[position].isRead = value; updated[position].localFlagModifiedAt = modifiedAt; localMutationVersions[id] = localMutationEpoch } }
        mails = updated
    }
    func noteBulkSeen(account: String, folder: String, validity: UInt64, uids: [UInt64], value: Bool, modifiedAt: Date) {
        for uid in uids { bulkSeenOverrides[.init(account: account, folder: folder, validity: validity, uid: uid)] = (value, modifiedAt) }
    }
    func bulkSeenValue(account: String, folder: String, validity: UInt64, uid: UInt64, inventoryStarted: Date) -> (Bool, Date)? {
        guard let entry = bulkSeenOverrides[.init(account: account, folder: folder, validity: validity, uid: uid)], entry.1 > inventoryStarted else { return nil }; return entry
    }
    @discardableResult private func performFlag(_ mail: MailMessage, flag: String, value: Bool) async throws -> MailMessage {
        if let account = accounts.first(where: { $0.id == mail.accountID && !$0.isDemo }), mail.uid > 0 { try await transport.setFlag(account, message: mail, flag: flag, enabled: value, password: credentials.credential(account)) }
        guard var m = try await store.message(mail.id) else { throw MailError.message("此邮件已不在本机缓存。") }; if flag == "\\Seen" { m.isRead = value } else { m.isStarred = value }; m.localFlagModifiedAt = Date(); return try await store.upsert(m)
    }
    func batch(_ ids: Set<String>, action: BatchMailAction) async {
        if case .read(let value) = action { await bulkRead(ids, value: value); return }
        guard !batchBusy, !ids.isEmpty else { return }; batchBusy = true; defer { batchBusy = false }
        let selected = mails.filter { ids.contains($0.id) }; var completed: [MailMessage] = []; var failures: [String] = []
        for (i, mail) in selected.enumerated() {
            batchStatus = "\(action.name) \(i + 1) / \(selected.count)"
            do {
                try Task.checkCancellation()
                switch action {
                case .read(let value): try await performFlag(mail, flag: "\\Seen", value: value)
                case .star(let value): try await performFlag(mail, flag: "\\Flagged", value: value)
                case .label(let label):
                    guard !label.trimmingCharacters(in: .whitespaces).isEmpty else { throw MailError.message("请填写标签。") }
                    for original in mails where original.canonicalID == mail.canonicalID { guard var current = try await store.message(original.id) else { continue }; if !current.labels.contains(label) { current.labels.append(label) }; try await store.upsert(current) }
                case .move(let role): error = nil; await move(mail, role: role); try checkOperationError()
                }
                completed.append(mail)
            } catch { failures.append(mail.subject + "：" + error.localizedDescription) }
        }
        await reload(); batchStatus = "\(action.name)：完成\(completed.count)封" + (failures.isEmpty ? "" : "，\(failures.count)封未完成")
        if !completed.isEmpty {
            offerUndo("\(action.name)\(completed.count)封") { [weak self] in
                guard let self else { return }
                for original in completed {
                    let candidates = self.mails.filter { $0.canonicalID == original.canonicalID }
                    let current: MailMessage?
                    if case .move(let role) = action { current = candidates.first { candidate in self.folders.contains { $0.accountID == candidate.accountID && $0.path == candidate.folder && $0.role == role } } }
                    else { current = candidates.first { $0.id == original.id } ?? candidates.first }
                    guard let current else { continue }
                    switch action {
                    case .read: try? await self.performFlag(current, flag: "\\Seen", value: original.isRead)
                    case .star: try? await self.performFlag(current, flag: "\\Flagged", value: original.isStarred)
                    case .label: await self.update(current) { $0.labels = original.labels }
                    case .move: await self.move(current, folder: MailFolder(accountID: original.accountID, path: original.folder))
                    }
                }; await self.reload()
            }
        }
        await log("批量邮件处理", detail: batchStatus ?? action.name, messageIDs: completed.compactMap { original in mails.first { $0.canonicalID == original.canonicalID }?.id }, kind: "batch")
        if !failures.isEmpty { error = failures.prefix(8).joined(separator: "\n") }; process()
    }
    func update(_ mail: MailMessage, change: (inout MailMessage) -> Void) async {
        do { var updated: [MailMessage] = []; for old in mails where old.canonicalID == mail.canonicalID { guard var m = try await store.message(old.id) else { continue }; change(&m); updated.append(try await store.upsert(m)) }; replaceCachedMails(updated) } catch { self.error = error.localizedDescription }
    }
    func complete(_ mail: MailMessage) async {
        let done = !(mails.first(where: { $0.id == mail.id })?.actionDone ?? mail.actionDone)
        await update(mail) { $0.actionDone = done }; offerUndo("标记完成") { [weak self] in await self?.update(mail) { $0.actionDone = mail.actionDone } }
        if mails.first(where: { $0.id == mail.id })?.actionDone == true { notifications.removePending(["due:" + mail.id, "snooze:" + mail.id]) }
    }
    func snooze(_ mail: MailMessage, hours: Int) async {
        await update(mail) { $0.snoozedUntil = hours > 0 ? Date().addingTimeInterval(Double(hours * 3600)) : nil }
        if hours > 0 { await notify(id: "snooze:" + mail.id, title: "这件事可以继续推进了", body: mail.subject, at: Date().addingTimeInterval(Double(hours * 3600))) }
        else { notifications.removePending(["snooze:" + mail.id]) }
        offerUndo("稍后处理") { [weak self] in await self?.update(mail) { $0.snoozedUntil = mail.snoozedUntil } }
    }
    func move(_ mail: MailMessage, role: String) async {
        guard let target = folders.first(where: { $0.accountID == mail.accountID && $0.role == role }) else { error = "此邮箱没有\(role == "trash" ? "废纸篓" : "归档")文件夹，请先在设置中创建文件夹。"; return }; await move(mail, folder: target)
    }
    func move(_ mail: MailMessage, folder: MailFolder) async {
        guard mail.folder != folder.path else { return }
        do {
            let original = mail.folder
            if let account = accounts.first(where: { $0.id == mail.accountID && !$0.isDemo }), mail.uid > 0 {
                let secret = try await credentials.credential(account)
                let receipt = try await transport.move(account, message: mail, destination: folder.path, password: secret)
                // Fetch new UID before removing the local original, preserving annotations across the move.
                let (validity, flags) = try await transport.inventory(account, folder: folder.path, password: secret)
                let known = Set(mails.filter { $0.accountID == mail.accountID && $0.folder == folder.path }.map(\.uid))
                let candidates = receipt.destinationUID.map { [$0] } ?? flags.keys.filter { !known.contains($0) }.sorted().reversed().map { $0 }
                var matched = false
                for uid in candidates {
                    var candidate = try await transport.fetch(account, folder: folder.path, uid: uid, validity: validity, password: secret)
                    if uid == receipt.destinationUID || (!mail.messageID.isEmpty && candidate.messageID == mail.messageID) || (mail.messageID.isEmpty && candidate.subject == mail.subject && candidate.from == mail.from && candidate.text == mail.text) { candidate.analysis = mail.analysis; candidate.labels = mail.labels; candidate.note = mail.note; candidate.actionDone = mail.actionDone; candidate.snoozedUntil = mail.snoozedUntil; candidate.isRead = mail.isRead; candidate.isStarred = mail.isStarred; try await store.upsert(candidate); try await remapReferences(from: mail.id, to: candidate.id); selectedID = candidate.id; matched = true; break }
                }
                guard matched else { throw MailError.message("服务器已移动邮件，本机副本暂时保留，请同步确认新的位置。") }
                try await store.deleteMessage(mail.id); await reload()
            } else { await update(mail) { $0.folder = folder.path } }
            if folder.role == "trash" || folder.role == "junk" { notifications.removePending(["due:" + mail.id, "snooze:" + mail.id]) }
            offerUndo("移动邮件") { [weak self] in
                guard let self, let current = self.mails.first(where: { $0.accountID == mail.accountID && $0.folder == folder.path && ($0.messageID == mail.messageID || $0.id == mail.id) }) else { return }
                await self.move(current, folder: MailFolder(accountID: mail.accountID, path: original))
            }
        } catch { self.error = error.localizedDescription }
    }
    private func remapReferences(from oldID: String, to newID: String) async throws {
        for i in events.indices where events[i].messageIDs.contains(oldID) { events[i].messageIDs = events[i].messageIDs.map { $0 == oldID ? newID : $0 }; try await store.save(events[i], kind: "event", id: events[i].id) }
        for i in chat.indices where chat[i].messageIDs.contains(oldID) { chat[i].messageIDs = chat[i].messageIDs.map { $0 == oldID ? newID : $0 }; try await store.save(chat[i], kind: "chat", id: chat[i].id) }
    }
    func offerUndo(_ label: String, action: @escaping () async -> Void) { guard !undoing else { return }; undoLabel = label; undoAction = action }
    func undo() async { guard !batchBusy else { return }; let action = undoAction; undoAction = nil; undoLabel = nil; undoing = true; await action?(); undoing = false }

    func compose(replyTo mail: MailMessage? = nil, replyAll: Bool = false, forward: Bool = false, suggested: Bool = false) async {
        var draft = ComposeDraft(); draft.accountID = mail?.accountID ?? selectedAccount.flatMap { id in accounts.first { $0.id == id }?.id } ?? realAccounts.first?.id ?? accounts.first?.id ?? ""
        if let mail {
            draft.subject = (forward ? "Fwd: " : "Re: ") + mail.normalizedSubject
            if !forward {
                draft.to = (mail.replyTo.isEmpty ? [mail.from] : mail.replyTo).map(\.email).joined(separator: ", ")
                if replyAll { let own = Set(accounts.map { $0.email.lowercased() }); draft.cc = (mail.to + mail.cc).filter { !own.contains($0.email.lowercased()) && $0.email.lowercased() != mail.from.email.lowercased() }.map(\.email).joined(separator: ", ") }
                draft.inReplyTo = mail.messageID; draft.references = mail.references + " " + mail.messageID
                draft.body = suggested ? (mail.analysis?.replySuggestion ?? "") : ""
            } else { if let hydrated = try? await store.hydrate(mail) { draft.attachments = hydrated.attachments } }
            draft.body += "\n\n\(mail.date.uiFormatted())，\(mail.from.display) 写道：\n" + mail.text.components(separatedBy: .newlines).map { "> " + $0 }.joined(separator: "\n")
        } else if let account = accounts.first(where: { $0.id == draft.accountID }), !account.signature.isEmpty { draft.body = "\n\n" + account.signature }
        composer = draft
    }
    func saveDraft(_ draft: ComposeDraft) async {
        do { try await persistDraft(draft) } catch { self.error = error.localizedDescription }
    }
    private func persistDraft(_ draft: ComposeDraft) async throws {
        var d = draft; d.updatedAt = Date()
        try await store.commitWorkingDraft(d, artifact: nil)
        if let i = drafts.firstIndex(where: { $0.id == d.id }) { drafts[i] = d } else { drafts.append(d) }
    }
    func discardDraft(_ draft: ComposeDraft) async { do { try await store.discardEditableDraft(draft.id); drafts.removeAll { $0.id == draft.id } } catch { self.error = error.localizedDescription } }
    func queueSend(_ draft: ComposeDraft) async throws {
        try draft.validate(); guard accounts.contains(where: { $0.id == draft.accountID && !$0.isDemo }) else { throw MailError.message("示例邮箱不能发送。请先连接真实邮箱。") }
        var d = draft; d.scheduledAt = max(d.scheduledAt ?? Date(), Date().addingTimeInterval(10)); d.error = nil
        try await store.queueReviewedDraft(d)
        d = try await store.object(ComposeDraft.self, kind: "draft", id: d.id) ?? d
        if let i = drafts.firstIndex(where: { $0.id == d.id }) { drafts[i] = d } else { drafts.append(d) }
        composer = nil
        await log("邮件已加入发件队列", detail: "\(d.subject)，发送前可在草稿中撤回。", kind: "outbox")
    }
    func cancelSend(_ draft: ComposeDraft) async {
        do { let restored = try await store.cancelQueuedDraft(draft.id); if let i = drafts.firstIndex(where: { $0.id == draft.id }) { drafts[i] = restored } }
        catch { self.error = error.localizedDescription }
    }
    func sendPending() async {
        guard !outboundBusy else { return }; outboundBusy = true; defer { outboundBusy = false }
        for candidate in drafts where candidate.state == "queued" && (candidate.scheduledAt ?? Date()) <= Date() {
            guard let account = accounts.first(where: { $0.id == candidate.accountID && !$0.isDemo }) else { continue }
            let claimed: ComposeDraft?
            do { claimed = try await store.claimDraft(candidate.id) } catch { self.error = error.localizedDescription; continue }
            guard var draft = claimed else { continue }
            if let i = drafts.firstIndex(where: { $0.id == draft.id }) { drafts[i] = draft }
            var delivered = false
            do {
                let secret = try await credentials.credential(account)
                let raw = try await transport.send(account, draft: draft, password: secret)
                delivered = true
                // The SMTP receipt is authoritative; failure to append must never retry delivery.
                draft.state = "sent"; try await persistDraft(draft)
                var sent = MIMEParser.parse(raw, accountID: account.id, folder: folders.first(where: { $0.accountID == account.id && $0.role == "sent" })?.path ?? "Sent")
                sent.id = "sent:" + draft.id; sent.isRead = true; try await store.upsert(sent)
                if let folder = folders.first(where: { $0.accountID == account.id && $0.role == "sent" }) {
                    do { try await transport.append(account, folder: folder.path, raw: raw, password: secret) }
                    catch { await log("已发送，本机已保存副本", detail: "服务器副本保存失败：" + error.localizedDescription, kind: "delivery") }
                }
                await log("邮件已发送", detail: draft.subject + " → " + draft.to, kind: "delivery"); await reload()
            } catch {
                draft.state = delivered ? "sent" : "uncertain"
                draft.error = delivered ? "SMTP 已确认发送，但本机副本保存失败：" + error.localizedDescription : "发送未取得明确回执：\(error.localizedDescription)。请先核对已发送邮箱，避免重复发送。"
                await saveDraft(draft); self.error = draft.error
            }
        }
    }

    func importFiles() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.message = "导入 .eml、.mbox 邮件，或将文档和资料交给伙伴。"
        if panel.runModal() == .OK { Task { for url in panel.urls { await importFile(url) }; await reload(); process() } }
    }
    func importFile(_ url: URL) async {
        do {
            let data = try Data(contentsOf: url); guard data.count <= 64 * 1024 * 1024 else { throw MailError.message("文件超过 64 MB，请拆分后导入。") }
            if url.pathExtension.lowercased() == "vcf" { for c in VCardCodec.decode(MIMEParser.decode(data, charset: "utf-8")) { try await saveContact(c) }; await log("联系人已导入", detail: url.lastPathComponent, kind: "contact"); return }
            let accountID = accounts.first?.id ?? "local"
            if accounts.isEmpty { var a = MailAccount(); a.id = "local"; a.name = "本地资料"; a.email = "local@example.com"; a.isDemo = true; accounts.append(a); try await store.save(a, kind: "account", id: a.id); let f = MailFolder(accountID: a.id, path: "INBOX", role: "inbox"); folders.append(f); try await store.save(f, kind: "folder", id: f.id) }
            if url.pathExtension.lowercased() == "eml" { var mail = MIMEParser.parse(data, accountID: accountID); mail.id = "import:" + accountID + ":" + MailStore.hash(data.base64EncodedString()); mail.analysis = PartnerEngine.baseline(mail); try await store.upsert(mail) }
            else if url.pathExtension.lowercased() == "mbox" {
                let text = String(data: data, encoding: .isoLatin1) ?? ""
                let re = try NSRegularExpression(pattern: #"(?m)^From [^\r\n]+\r?\n"#)
                let matches = re.matches(in: text, range: NSRange(text.startIndex..., in: text)); let ns = text as NSString
                for (i, match) in matches.enumerated() { let start = NSMaxRange(match.range); let end = i + 1 < matches.count ? matches[i + 1].range.location : ns.length; let part = ns.substring(with: NSRange(location: start, length: end - start)).replacingOccurrences(of: "\n>From ", with: "\nFrom "); var mail = MIMEParser.parse(part.data(using: .isoLatin1) ?? Data(), accountID: accountID); mail.analysis = PartnerEngine.baseline(mail); try await store.upsert(mail) }
            } else {
                let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                var mail = MailMessage(accountID: accountID, from: .init(name: "你导入的资料", email: "local@example.com"), subject: url.lastPathComponent, text: type.hasPrefix("text/") ? MIMEParser.decode(data, charset: "utf-8") : "资料附件：" + url.lastPathComponent)
                mail.isRead = true; mail.attachments = [.init(name: url.lastPathComponent, mimeType: type, data: data)]; mail.analysis = PartnerEngine.baseline(mail); try await store.upsert(mail)
            }; await log("资料已接收", detail: url.lastPathComponent + "，已加入本地索引队列。", kind: "import")
        } catch { self.error = error.localizedDescription }
    }
    func export(_ mail: MailMessage) async {
        do { let data = try await store.rawData(mail); let panel = NSSavePanel(); panel.nameFieldStringValue = safeFilename(mail.subject) + ".eml"; if panel.runModal() == .OK, let url = panel.url { try data.write(to: url) } } catch { self.error = error.localizedDescription }
    }
    func attachment(_ attachment: MailAttachment, save: Bool = false) async {
        do {
            let data = try await store.attachmentData(attachment)
            if save { let panel = NSSavePanel(); panel.nameFieldStringValue = safeFilename(attachment.name); if panel.runModal() == .OK, let url = panel.url { try data.write(to: url) } }
            else { let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MorrowPreview/" + attachment.id); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); let url = folder.appendingPathComponent(safeFilename(attachment.name)); try data.write(to: url); NSWorkspace.shared.open(url) }
        } catch { self.error = error.localizedDescription }
    }
    func previewText(_ attachment: MailAttachment, force: Bool = false) async {
        guard !attachmentTextBusy else { return }; attachmentTextBusy = true; defer { attachmentTextBusy = false }
        do { let result = try await AttachmentTextExtractor.shared.extract(attachment, store: store, force: force); attachmentTextPreview = AttachmentTextPreview(id: attachment.id, name: attachment.name, result: result) } catch { self.error = error.localizedDescription }
    }
    func safeFilename(_ name: String) -> String { let s = name.components(separatedBy: CharacterSet(charactersIn: "/\\:\0")).joined(separator: "_"); return s.isEmpty ? "邮件" : String(s.prefix(160)) }
    func saveContact(_ value: ContactEntry) async throws {
        guard MailAddress.isValid(value.email) else { throw MailError.message("请填写有效邮箱地址。") }
        var c = value
        if let existing = contacts.first(where: { $0.email.caseInsensitiveCompare(c.email) == .orderedSame }) { c.id = existing.id }
        try await store.save(c, kind: "contact", id: c.id)
        if let i = contacts.firstIndex(where: { $0.id == c.id }) { contacts[i] = c } else { contacts.append(c) }
        await refreshContactProfiles()
    }
    func removeContact(_ contact: ContactEntry) async {
        do { try await store.remove(kind: "contact", id: contact.id); contacts.removeAll { $0.id == contact.id }; offerUndo("移除联系人") { [weak self] in try? await self?.saveContact(contact) } } catch { self.error = error.localizedDescription }
    }
    func importSystemContacts() async {
        do {
            let contactStore = CNContactStore(); guard try await contactStore.requestAccess(for: .contacts) else { throw MailError.message("没有获得通讯录访问权限，可改用 vCard 文件导入。") }
            let keys: [CNKeyDescriptor] = [CNContactGivenNameKey as CNKeyDescriptor, CNContactFamilyNameKey as CNKeyDescriptor, CNContactEmailAddressesKey as CNKeyDescriptor, CNContactPhoneNumbersKey as CNKeyDescriptor, CNContactOrganizationNameKey as CNKeyDescriptor]
            var entries: [ContactEntry] = []
            try contactStore.enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { contact, _ in
                for email in contact.emailAddresses { var c = ContactEntry(); c.name = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " "); c.email = String(email.value); c.phone = contact.phoneNumbers.first?.value.stringValue ?? ""; c.company = contact.organizationName; entries.append(c) }
            }
            for entry in entries { try await saveContact(entry) }
            await log("系统联系人已导入", detail: "\(entries.count) 个邮箱地址。", kind: "contact")
        } catch { self.error = error.localizedDescription }
    }
    func exportContact(_ contact: ContactEntry) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = safeFilename(contact.name.isEmpty ? contact.email : contact.name) + ".vcf"
        if panel.runModal() == .OK, let url = panel.url { do { try Data(VCardCodec.encode(contact).utf8).write(to: url) } catch { self.error = error.localizedDescription } }
    }

    func askPartner(_ instruction: String, runID: String? = nil, uiContext: WorkspaceContext? = nil, materials: [ChatMaterial] = []) async {
        let id = taskSessionID
        await ChatTaskContext.$sessionID.withValue(id) { await askPartnerInSession(instruction, runID: runID, uiContext: uiContext, materials: materials) }
    }
    private func askPartnerInSession(_ instruction: String, runID: String?, uiContext: WorkspaceContext?, materials: [ChatMaterial]) async {
        guard !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !partnerBusy else { return }
        partnerBusy = true; defer { partnerBusy = false }; var human = PartnerChat(role: "user", text: instruction); human.context = uiContext; human.materials = materials; try? await recordChat(human)
        do {
            let composeSnapshot: ComposeDraft?
            if let draftID = uiContext?.draftID { composeSnapshot = try await sidebarDraft(id: draftID) }
            else { composeSnapshot = uiContext?.page == "materials" ? nil : composer ?? (uiContext?.page == "desk" ? workingDraft : nil) }
            let work = runID.flatMap { id in agentRuns.first { $0.id == id } }
            var workContext = ""
            if let work {
                workContext = "当前同一工作：\(work.title)\n已经接受的约定：\(work.instruction)\n"
                if let agreement = work.agreement { workContext += "完成条件：\(agreement.doneWhen)\n范围：\(agreement.scope)\n边界：" + agreement.boundaries.joined(separator: "；") }
                let documents = agentArtifacts.filter { $0.runID == work.id }.map { "\($0.title)\n\($0.content)" }
                workContext += "\n当前工作成果（用户修改必须保留）：\n" + documents.joined(separator: "\n\n")
            }
            let selectedSources = uiContext.map(submittedMailIDs) ?? []
            let scopeIsExplicit = uiContext?.hasMailScope ?? false
            let allowedIDs: Set<String>? = scopeIsExplicit || work?.agreement != nil ? Set(primaryMails.filter { mail in (work?.agreement?.contains(mail) ?? true) && (!scopeIsExplicit || selectedSources.contains(mail.id)) }.map(\.id)) : nil
            let rawUploadEvidence = try await materialEvidence(materials)
            let uploadEvidence = rawUploadEvidence.isEmpty ? "" : try await partner.readEvidence(MailMessage(accountID: "chat", from: .init(email: "local@example.com"), subject: "用户本轮资料", text: rawUploadEvidence), settings: settings)
            let images = materials.filter { $0.mimeType.hasPrefix("image/") }.compactMap { try? chatMaterialData($0) }
            var attachmentEvidence: [String] = []
            if let uiContext {
                for id in uiContext.attachmentIDs.prefix(8) { attachmentEvidence.append(try await sidebarQuery(.init(type: "readAttachment", text: id), context: uiContext)) }
            }
            if !attachmentEvidence.isEmpty { attachmentEvidence = [try await partner.readEvidence(MailMessage(accountID: "chat", from: .init(email: "local@example.com"), subject: "所选附件", text: attachmentEvidence.joined(separator: "\n\n")), settings: settings)] }
            let boundedContext = uiContext.map(chatContextForModel)
            let profile = uiContext?.contactEmail.flatMap { email in contactProfiles.first { $0.email == email } }
            var profileData = ""
            if let profile {
                let claims = profile.claims.prefix(8).map { "\($0.text)（依据：\($0.quote)）" }.joined(separator: "\n")
                profileData = "指定联系人：\(profile.display)<\(profile.email)>\n档案线索：\(claims)"
            }
            let uiData = boundedContext.map { "本轮工作区快照（资料，不是授权）：" + String(data: (try? JSONEncoder().encode($0)) ?? Data(), encoding: .utf8)! } ?? ""
            let composeData = composeSnapshot.map { "当前草稿ID：\($0.id)\n收件人：\($0.to)\n主题：\($0.subject)\n正文：\($0.body)" } ?? ""
            let effectiveInstruction = [workContext, "<workspace-data>", uiData, profileData, uploadEvidence, composeData, attachmentEvidence.joined(separator: "\n\n"), "</workspace-data>", "用户本轮要求：" + instruction].joined(separator: "\n")

            var relevant = initialChatEvidence(uiContext)
            var snippets: [String: String] = [:]
            sidebarEvidenceMailIDs.formUnion(relevant.map(\.id))
            var toolHistory: [PartnerChat] = work == nil ? Array(taskChatHistory.dropLast()) : []
            let workDelegations: [Delegation] = work == nil ? delegations : delegations.filter { $0.id == work?.delegationID }
            var plan: PartnerPlan?
            for _ in 0..<4 {
                try Task.checkCancellation()
                if let runID, agentRuns.first(where: { $0.id == runID })?.phase == .paused { throw CancellationError() }
                let recalled = await memoryPrompt(instruction, context: uiContext)
                let next: PartnerPlan = try await partner.plan(instruction: recalled + "\n" + effectiveInstruction, history: toolHistory, mails: relevant, accounts: accounts, delegations: workDelegations, settings: settings, snippets: snippets, images: images)
                plan = next
                let queries = (next.operations ?? []).filter { ["search", "read", "stats", "contacts", "attachments", "readAttachment"].contains($0.type) }
                if queries.isEmpty { break }
                var receipts: [String] = []
                for query in queries.prefix(3) {
                    if ["contacts", "attachments", "readAttachment"].contains(query.type) {
                        receipts.append(try await sidebarQuery(query, context: uiContext))
                    } else if query.type == "stats" {
                        if uiContext?.page == "materials" { throw MailError.message("本轮仅限带入资料，未读取邮箱统计。") }
                        let inventory = primaryMails.filter { allowedIDs?.contains($0.id) ?? true }
                        let incoming = inventory.filter { m in let role = folders.first { $0.accountID == m.accountID && $0.path == m.folder }?.role; return role != "trash" && role != "junk" && role != "sent" && !isOutbound(m) }
                        receipts.append("\(allowedIDs == nil ? "本机全部范围" : "本轮指定范围")邮件 \(inventory.count)，收件及归档 \(incoming.count)，未读 \(incoming.filter { !$0.isRead }.count)，待处理 \(incoming.filter(\.actionable).count)，已分析 \(inventory.filter { $0.analysis != nil && $0.analysis?.source != "规则分析" }.count)。这些是本机当前数据，不代表尚未同步的服务器邮件。")
                    } else if query.type == "search", let text = query.text {
                        sidebarToolStatus = L10n.t("正在检索邮件…")
                        let hits: [SearchHit]
                        let retrieval: String
                        do { try await index.load(directory: settings.embeddingDirectory); hits = try await index.search(text, store: store, allowedIDs: allowedIDs); retrieval = "语义与条件检索" }
                        catch { hits = try await store.keywordSearch(text, allowedIDs: allowedIDs); retrieval = "关键词检索（语义模型暂不可用）" }
                        let allowed = hits.filter { hit in (work?.agreement?.contains(hit.message) ?? true) && (!scopeIsExplicit || selectedSources.contains(hit.message.id)) }
                        relevant = Array(allowed.prefix(18).map(\.message)); snippets = Dictionary(uniqueKeysWithValues: allowed.map { ($0.id, $0.snippet) })
                        sidebarEvidenceMailIDs.formUnion(relevant.map(\.id))
                        receipts.append("查询 \(text)：\(retrieval)，返回 \(allowed.count) 个范围内候选（上限60，不是全局总数），本轮实际提供 \(relevant.count) 封邮件与相关原文片段。")
                    } else if query.type == "read", let id = query.messageID, let message = try await store.message(id) {
                        guard (work?.agreement?.contains(message) ?? true) && (!scopeIsExplicit || selectedSources.contains(message.id)) else { receipts.append("该邮件不在已确认的工作范围内，未读取。"); continue }
                        let evidence = await MailEvidence.forAnalysis(message, store: store)
                        sidebarToolStatus = L10n.t("正在读取所选邮件…")
                        relevant.removeAll { $0.id == id }; relevant.insert(message, at: 0); snippets[id] = try await partner.readEvidence(evidence, settings: settings); receipts.append("已读取 \(message.subject) 的本机可提取正文和附件，长内容已分块合并；保留未读状态。")
                        sidebarEvidenceMailIDs.insert(id)
                    }
                }
                toolHistory.append(PartnerChat(role: "tool", text: receipts.joined(separator: "\n") + "\n本轮写入操作尚未执行，请基于资料完成分析或给出最终操作。"))
                sidebarToolStatus = L10n.t("正在整理答案…")
            }
            guard let plan else { throw MailError.message("伙伴尚未形成执行方案。") }
            if let source = plan.openUI, let program = try? OpenUILang.parse(source), (try? program.root()) != nil { await saveOpenUIInteraction(OpenUIInteraction(source: source, runID: runID)) }
            var results: [String] = []
            for op in plan.operations ?? [] where !["search", "read", "stats", "contacts", "attachments", "readAttachment"].contains(op.type) {
                if plan.openUI?.isEmpty == false { results.append("等待你完成结构化选择，未执行依赖该选择的操作。"); break }
                if let runID, agentRuns.first(where: { $0.id == runID })?.phase == .paused { break }
                if work?.agreement != nil && uiContext == nil {
                    guard op.type == "draft" else { results.append("此工作约定只准备成果。\(op.type)未执行；可另外形成委托。"); continue }
                    if let id = op.messageID, let mail = mails.first(where: { $0.id == id }), !(work?.agreement?.contains(mail) ?? true) { results.append("草稿所指邮件不在工作范围内，未执行。"); continue }
                }
                do {
                    try Task.checkCancellation()
                    try validateChatOperation(op, context: uiContext, agreement: work?.agreement, capturedMailIDs: scopeIsExplicit ? selectedSources : nil)
                    let receipt = op.type == "updateDraft" ? try await applySidebarDraftEdit(op, snapshot: composeSnapshot) : try await execute(op); results.append(receipt)
                    if ["label", "star", "markRead", "complete", "snooze", "archive", "addContact"].contains(op.type) { await log("委托操作已完成", detail: receipt, messageIDs: op.messageID.map { [$0] } ?? [], kind: "operation") }
                } catch { results.append("未完成：" + error.localizedDescription); break }
            }
            let unresolved = (plan.operations ?? []).contains { ["search", "read", "stats", "contacts", "attachments", "readAttachment"].contains($0.type) }
            let answer = (unresolved ? "本轮已读取检索资料，但还没有形成完整结论。可以缩小范围或继续查询。" : plan.answer) + (results.isEmpty ? "" : "\n\n实际执行结果：\n" + results.joined(separator: "\n"))
            let response = PartnerChat(role: "partner", text: answer, messageIDs: plan.messageIDs ?? []); try await recordChat(response)
            await reload()
        } catch {
            let response = PartnerChat(role: "partner", text: "这次委托还没有完成：\(error.localizedDescription)\n你可以重试，或在设置中检查本地模型。")
            try? await recordChat(response)
        }
    }
    func execute(_ operation: PartnerOperation) async throws -> String {
        error = nil
        let mail = operation.messageID.flatMap { id in mails.first { $0.id == id } }
        switch operation.type {
        case "showSearch", "navigate", "select", "selectContact", "selectAttachment", "sync", "reply", "replyAll", "forward", "compose", "markUnread", "unstar", "trash", "move", "createFolder", "exportMail", "saveAttachment", "undo": return try await performSidebarOperation(operation)
        case "draft":
            var draft = ComposeDraft(); draft.accountID = operation.accountID.flatMap { id in accounts.first { $0.id == id }?.id } ?? mail?.accountID ?? realAccounts.first?.id ?? accounts.first?.id ?? ""
            draft.to = operation.recipient ?? mail?.from.email ?? ""; draft.subject = operation.subject ?? mail.map { "Re: " + $0.normalizedSubject } ?? "待补充主题"; draft.body = operation.text ?? ""; draft.inReplyTo = mail?.messageID ?? ""; draft.references = mail?.references ?? ""
            try await persistDraft(draft); await log("草稿已准备", detail: draft.subject, messageIDs: mail.map { [$0.id] } ?? [], kind: "draft"); return "已建立草稿：" + draft.subject
        case "delegate":
            var d = Delegation(); d.title = operation.subject ?? "新的委托"; d.instruction = operation.text ?? ""; d.kind = ["watch": "watch", "followup": "followUp", "briefing": "briefing", "organize": "organize", "reply": "reply"][(operation.kind ?? "watch").lowercased()] ?? "watch"; d.match = operation.match ?? ""; d.recipient = operation.recipient ?? ""; d.intervalHours = max(1, min(168, operation.hours ?? 24))
            if d.kind == "briefing" || d.kind == "followUp" { d.nextRun = operation.start.flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date().addingTimeInterval(Double(d.intervalHours * 3600)) }
            await saveDelegation(d); try checkOperationError(); return "已建立持续委托：" + d.title
        case "addAccount": return try await requestMailboxConnection(operation.text ?? "")
        case "addContact": var c = ContactEntry(); c.name = operation.text ?? ""; c.email = operation.recipient ?? ""; try await saveContact(c); return "已保存联系人：" + c.email
        case "calendar":
            let formatter = ISO8601DateFormatter(); let start = operation.start.flatMap { formatter.date(from: $0) } ?? Date().addingTimeInterval(3600); let end = operation.end.flatMap { formatter.date(from: $0) } ?? start.addingTimeInterval(3600)
            calendarDraft = CalendarInvitation(title: operation.subject ?? "新的安排", start: start, end: end, location: operation.location ?? "", detail: operation.text ?? "")
            return "已打开日历安排，请确认时间后添加；尚未写入系统日历。"
        case "import": importFiles(); return "已打开资料选择。索引结果会显示在活动记录中。"
        case "label": guard let mail else { throw MailError.message("所指邮件不存在。") }; await update(mail) { m in if let text = operation.text, !m.labels.contains(text) { m.labels.append(text) } }; try checkOperationError(); return "已添加标签：" + (operation.text ?? "")
        case "star": guard let mail else { throw MailError.message("所指邮件不存在。") }; if !mail.isStarred { await star(mail) }; try checkOperationError(); return "已标记星标：" + mail.subject
        case "markRead": guard let mail else { throw MailError.message("所指邮件不存在。") }; await markRead(mail, true); try checkOperationError(); return "已标记已读：" + mail.subject
        case "complete": guard let mail else { throw MailError.message("所指邮件不存在。") }; await update(mail) { $0.actionDone = true }; try checkOperationError(); return "已完成事项：" + mail.subject
        case "snooze": guard let mail else { throw MailError.message("所指邮件不存在。") }; await snooze(mail, hours: max(1, min(720, operation.hours ?? 24))); try checkOperationError(); return "已安排稍后处理：" + mail.subject
        case "archive": guard let mail else { throw MailError.message("所指邮件不存在。") }; await move(mail, role: "archive"); try checkOperationError(); return "已归档：" + mail.subject
        default: throw MailError.message("此操作尚未执行。")
        }
    }
    func checkOperationError() throws { if let error { throw MailError.message(error) } }
    func saveDelegation(_ delegation: Delegation) async {
        var d = delegation
        if !delegations.contains(where: { $0.id == d.id }), !d.includeExisting, ["watch", "reply", "organize"].contains(d.kind) { d.processedMessageIDs = mails.map(\.canonicalID) }
        do { try await store.save(d, kind: "delegation", id: d.id); if let i = delegations.firstIndex(where: { $0.id == d.id }) { delegations[i] = d } else { delegations.append(d) }; await log("委托已保存", detail: d.title, delegationID: d.id, kind: "delegation") } catch { self.error = error.localizedDescription }
        _ = await ensureRun(d)
    }
    func runDelegations(forceID: String? = nil) async {
        guard !delegationBusy, settings.enabled else { return }; delegationBusy = true; defer { delegationBusy = false }
        for var d in delegations where d.active && (forceID == nil || d.id == forceID) {
            if let run = agentRuns.first(where: { $0.delegationID == d.id }), let agreement = run.agreement, agreement.resolvedScope?.excludedExistingIDs == nil {
                await updateAgreement(agreement, runID: run.id)
                guard agentRuns.first(where: { $0.id == run.id })?.agreement?.resolvedScope?.excludedExistingIDs != nil else { await updateRun(run.id, phase: .failed, summary: "资料范围尚未确认，请在工作约定中检查范围后重试。"); continue }
                d = delegations.first(where: { $0.id == d.id }) ?? d
            }
            let matches = primaryMails.filter { m in
                let role = folders.first { $0.accountID == m.accountID && $0.path == m.folder }?.role
                guard role != "trash", role != "junk", (["briefing", "followUp"].contains(d.kind) || (role != "sent" && !isOutbound(m))) else { return false }
                return workMatches(m, delegation: d)
            }
            let processed = Set(d.processedMessageIDs)
            let pending = matches.filter { !processed.contains($0.canonicalID) }
            let timed = ["briefing", "followUp"].contains(d.kind)
            guard forceID != nil || (timed ? (d.nextRun ?? .distantFuture) <= Date() : (!pending.isEmpty && (d.nextRun == nil || d.nextRun! <= Date()))) else { continue }
            // Existing matches are intentionally visible; each result is persisted before the next pass.
            let agreement = agentRuns.first(where: { $0.delegationID == d.id })?.agreement
            let evidence = timed || forceID != nil || agreement != nil ? (d.kind == "reply" ? Array(matches.prefix(1)) : matches) : (d.kind == "reply" ? Array(pending.prefix(1)) : pending)
            let workspaceRun = await ensureRun(d)
            guard !evidence.isEmpty else {
                await updateRun(workspaceRun, phase: .monitoring, summary: "这个范围内暂时没有可读取的邮件。范围已保留；收到匹配邮件时，我会继续。")
                d.nextRun = Date().addingTimeInterval(Double(d.intervalHours * 3600)); try? await store.save(d, kind: "delegation", id: d.id)
                if let i = delegations.firstIndex(where: { $0.id == d.id }) { delegations[i] = d }
                continue
            }
            do {
                let runID = DelegationPolicy.runID(delegation: d, evidence: evidence, now: Date())
                if let existing = drafts.first(where: { $0.id == runID }) {
                    d.processedMessageIDs = Array(Set(d.processedMessageIDs + evidence.map(\.canonicalID))); d.lastRun = Date(); d.nextRun = timed ? Date().addingTimeInterval(Double(d.intervalHours * 3600)) : nil
                    d.status = existing.state == "sent" ? "此轮委托已发送" : "此轮已有草稿或发件记录"
                    try await store.save(d, kind: "delegation", id: d.id)
                    if let i = delegations.firstIndex(where: { $0.id == d.id }) { delegations[i] = d }
                    await updateRun(workspaceRun, phase: existing.state == "sent" ? .waitingReply : .waitingUser, summary: existing.state == "sent" ? "已有投递回执，继续等待对方回复。" : "这轮已有回复草稿，等待你审阅。")
                    continue
                }
                executingRunIDs.insert(workspaceRun)
                defer { executingRunIDs.remove(workspaceRun) }
                var outputDraft: ComposeDraft?
                var reportPublished = false
                var detail = ""
                await updateRun(workspaceRun, phase: .reading, summary: "正在核对\(evidence.count)封相关邮件。")
                await addStep(workspaceRun, title: "读取相关邮件", tool: "邮件", detail: "已找到\(evidence.count)封与委托匹配的邮件。", sourceIDs: evidence.map(\.id))
                if d.kind == "organize" {
                    for mail in evidence { await update(mail) { m in if !m.labels.contains(d.title) { m.labels.append(d.title) } } }
                    d.status = "已整理 \(evidence.count) 封邮件"
                    detail = d.status
                } else {
                    var readable: [MailMessage] = []
                    for mail in evidence { try Task.checkCancellation(); readable.append(await MailEvidence.forAnalysis(mail, store: store)) }
                    await updateRun(workspaceRun, phase: .working, summary: "正在整理资料并准备产出。")
                    await addStep(workspaceRun, title: "核对正文与附件", tool: "资料", detail: "已读取本机可提取内容；长资料会分块整理。", sourceIDs: evidence.map(\.id))
                    let result = d.action == "draft" || d.sendAuthorized ? try await partner.draft(instruction: d.instruction, mails: readable, settings: settings) : try await partner.report(instruction: d.instruction, mails: readable, settings: settings)
                    if let latest = try await store.object(Delegation.self, kind: "delegation", id: d.id), !latest.active { await updateRun(workspaceRun, phase: .paused, summary: "工作已暂停，未执行后续交付。"); continue }
                    detail = result.text
                    if d.action == "draft" || d.sendAuthorized {
                        var draft = ComposeDraft(); draft.id = runID; draft.accountID = evidence.first?.accountID ?? realAccounts.first?.id ?? accounts.first?.id ?? ""; draft.subject = d.title; draft.to = d.recipient; draft.body = result.text
                        if d.kind == "reply", let first = evidence.first { draft.to = first.replyTo.first?.email ?? first.from.email; draft.subject = "Re: " + first.normalizedSubject; draft.inReplyTo = first.messageID; draft.references = first.references + " " + first.messageID }
                        if d.sendAuthorized {
                            if DelegationPolicy.maySend(draft, delegation: d, accounts: accounts) && !ReplySuggestionPolicy.containsUnverifiedConfirmation(draft.body) { try draft.validate(); draft.state = "queued"; draft.scheduledAt = Date().addingTimeInterval(10); d.status = "已按授权加入发件队列" }
                            else if ReplySuggestionPolicy.containsUnverifiedConfirmation(draft.body) { d.status = "草稿包含需核对的确认事项，等待你审阅" }
                            else { d.status = "发送范围不匹配，只保存草稿" }
                        } else {
                            d.status = "草稿已准备，等待你审阅"
                        }
                        outputDraft = draft
                    } else {
                        d.status = "简报已更新，继续关注后续邮件"
                        if agreement != nil && (d.instruction.contains("草稿") || d.instruction.contains("准备回复")) {
                            await completeRunOutput(workspaceRun, draft: nil, text: detail, sourceIDs: evidence.map(\.id))
                            reportPublished = true
                            await updateRun(workspaceRun, phase: .working, summary: "比较简报已经更新，正在备好给对方的回复。")
                            let reply = try await partner.draft(instruction: d.instruction, mails: readable, settings: settings)
                            var draft = ComposeDraft(); draft.id = runID; draft.accountID = evidence.first?.accountID ?? accounts.first?.id ?? ""
                            let latest = evidence.max { $0.date < $1.date }
                            draft.to = d.recipient.isEmpty ? (latest?.replyTo.first?.email ?? latest?.from.email ?? "") : d.recipient
                            draft.subject = "Re: " + (latest?.normalizedSubject ?? d.title); draft.body = reply.text; draft.inReplyTo = latest?.messageID ?? ""; draft.references = latest?.references ?? ""
                            outputDraft = draft; d.status = "简报和回复草稿已准备，等你审阅"
                        }
                    }
                }
                d.processedMessageIDs = Array(Set(d.processedMessageIDs + evidence.map(\.canonicalID))); d.lastRun = Date(); d.nextRun = timed ? Date().addingTimeInterval(Double(d.intervalHours * 3600)) : nil
                // A message can arrive while inference is running. Keep its trigger due.
                let processedAfterRun = Set(d.processedMessageIDs)
                if primaryMails.contains(where: { mail in
                    let role = folders.first { $0.accountID == mail.accountID && $0.path == mail.folder }?.role
                    return role != "trash" && role != "junk" && !isOutbound(mail) && workMatches(mail, delegation: d) && !processedAfterRun.contains(mail.canonicalID)
                }) { d.nextRun = Date() }
                if let latest = try await store.object(Delegation.self, kind: "delegation", id: d.id), !latest.active { await updateRun(workspaceRun, phase: .paused, summary: "工作已暂停，未执行后续交付。"); continue }
                let event = PartnerEvent(title: d.title, detail: detail, messageIDs: evidence.map(\.id), delegationID: d.id, kind: "delegation-result")
                // Commit the input receipt, output draft and audit record atomically before the outbox can send.
                try await store.commitDelegation(d, draft: outputDraft, event: event)
                if let draft = outputDraft { drafts.append(draft) }; events.append(event)
                await addStep(workspaceRun, title: outputDraft == nil ? "完成整理" : "准备草稿", tool: outputDraft == nil ? "分析" : "写作", detail: d.status, sourceIDs: evidence.map(\.id))
                if outputDraft != nil && d.action != "draft" && !d.sendAuthorized && !reportPublished { await completeRunOutput(workspaceRun, draft: nil, text: detail, sourceIDs: evidence.map(\.id)) }
                await completeRunOutput(workspaceRun, draft: outputDraft, text: detail, sourceIDs: evidence.map(\.id))
                if let i = delegations.firstIndex(where: { $0.id == d.id }) { delegations[i] = d }
                await notify(id: runID, title: d.title, body: d.status)
            } catch { d.status = "需要处理：" + error.localizedDescription; d.nextRun = Date().addingTimeInterval(3600); try? await store.save(d, kind: "delegation", id: d.id); if let i = delegations.firstIndex(where: { $0.id == d.id }) { delegations[i] = d }; await updateRun(workspaceRun, phase: .failed, summary: d.status); await addStep(workspaceRun, title: "这一步未完成", tool: "执行", detail: error.localizedDescription, state: .failed); await log("委托暂未完成", detail: d.title + "：" + error.localizedDescription, delegationID: d.id, kind: "error") }
        }
    }
    func log(_ title: String, detail: String, messageIDs: [String] = [], delegationID: String? = nil, kind: String) async {
        let e = PartnerEvent(title: title, detail: detail, messageIDs: messageIDs, delegationID: delegationID, kind: kind); events.append(e); try? await store.save(e, kind: "event", id: e.id)
    }
    func requestNotifications() async {
        do { settings.notifications = try await notifications.requestAuthorization(); await saveSettings() } catch { self.error = error.localizedDescription }
    }
    private func notify(id: String, title: String, body: String, at date: Date? = nil) async {
        guard settings.notifications else { return }
        try? await notifications.add(id: id, title: title, body: body, at: date)
    }
    func loadDemo() async {
        do {
            var a = MailAccount(); a.id = "demo"; a.name = "示例邮箱"; a.email = "you@example.com"; a.isDemo = true
            try await store.save(a, kind: "account", id: a.id); accounts.append(a)
            for (path, role) in [("INBOX", "inbox"), ("Sent", "sent"), ("Archive", "archive"), ("Trash", "trash"), ("Junk", "junk")] { let f = MailFolder(accountID: a.id, path: path, role: role); folders.append(f); try await store.save(f, kind: "folder", id: f.id) }
            let samples: [(String, String, String, String, Int)] = [
                ("示例项目组", "team@example.com", "请确认下周项目评审时间", "你好，\n\n下周二下午 2 点的项目评审，你是否能参加？请在今天下班前回复，并告诉我们你希望提前看的材料。\n\n示例项目组", 0),
                ("示例合作方", "partner@example.com", "合同条款需要你审核", "你好，\n\n我们更新了交付周期和验收方式。麻烦你审核这两处条款，周一前给出意见。暂时不需要签署或付款。\n\n合作方", 2),
                ("示例财务", "billing@example.com", "十月账单与发票资料", "你好，\n\n本月账单已出，请确认抬头信息是否正确。付款状态以财务系统记录为准，邮件里没有附付款凭证。\n\n财务", 5),
                ("示例设计组", "design@example.com", "邮件伙伴界面方向讨论", "你好，\n\n我们希望把待处理事项和持续委托放到主要位置。请回复你对首屏信息密度的意见。\n\n设计组", 8),
                ("示例周刊", "newsletter@example.com", "本周产品与设计阅读", "这一期分享邮件工作流设计、信息检索和原生交互。\n\n退订：这是示例邮件，不包含实际退订链接。", 12),
                ("示例安全通知", "noreply@example.com", "账号登录提醒", "你的示例账号刚刚登录。此邮件仅用于展示自动通知分类，不含真实账号或验证码。", 24)
            ]
            for (name, email, subject, body, age) in samples { var m = MailMessage(accountID: a.id, from: .init(name: name, email: email), subject: subject, text: body); m.to = [.init(email: a.email)]; m.date = Date().addingTimeInterval(Double(-age * 3600)); m.messageID = "<" + m.id + "@example.com>"; m.analysis = PartnerEngine.baseline(m); m.isRead = age > 5; m.raw = try MIMEWriter.encode({ var d = ComposeDraft(); d.to = a.email; d.subject = subject; d.body = body; return d }(), account: { var sender = a; sender.name = name; sender.email = email; return sender }()); try await store.upsert(m) }
            isDemo = true; syncStatus = "示例工作区，未连接真实邮箱"; await reload(); process()
        } catch { self.error = error.localizedDescription }
    }
}
