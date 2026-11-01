import Foundation
import MorrowCore

extension AppModel {
    var compactLayout: Bool { workspacePreferences.density == "compact" }
    func inboxUnreadCount(_ accountID: String?) -> Int {
        projectedInboxUnreadCount(accountID)
    }
    func chooseMailbox(_ id: String?) { dismissInlineTools(); navigate(.inbox); selectedAccount = id }
    func chooseFolder(_ folder: MailFolder) { dismissInlineTools(); navigate(.inbox); selectedAccount = folder.accountID; selectedFolder = folder.path }
    func installMultiAccountDemo() async {
        guard isDemo, !accounts.contains(where: { $0.id == "demo-work" }) else { return }
        do {
            var account = MailAccount(); account.id = "demo-work"; account.name = "工作演示邮箱"; account.email = "work@example.com"; account.isDemo = true
            try await store.save(account, kind: "account", id: account.id); accounts.append(account)
            for folder in [MailFolder(accountID: account.id, path: "INBOX", role: "inbox"), MailFolder(accountID: account.id, path: "Sent", role: "sent"), MailFolder(accountID: account.id, path: "Archive", role: "archive"), MailFolder(accountID: account.id, path: "Trash", role: "trash")] { try await store.save(folder, kind: "folder", id: folder.id); folders.append(folder) }
            var unread = MailMessage(accountID: account.id, from: .init(name: "示例项目负责人", email: "project@example.com"), subject: "工作邮箱：待核对材料", text: "这是独立工作邮箱的演示来信。请核对材料清单，再准备回复。")
            unread.to = [.init(email: account.email)]; unread.messageID = "<multi-demo-unread@example.com>"; unread.analysis = PartnerEngine.baseline(unread)
            var read = MailMessage(accountID: account.id, from: .init(name: "示例行政", email: "office@example.com"), subject: "工作邮箱：已读通知", text: "这是一封已经阅读的演示通知，不需要回复。")
            read.to = [.init(email: account.email)]; read.messageID = "<multi-demo-read@example.com>"; read.isRead = true; read.analysis = PartnerEngine.baseline(read)
            try await store.upsert(unread); try await store.upsert(read); await reload(); process()
        } catch { self.error = error.localizedDescription }
    }
    func setAccountSyncState(_ account: MailAccount, syncing: Bool, error: String? = nil, completed: Bool = true) async {
        var status = accountSyncStates[account.id] ?? AccountSyncState(accountID: account.id)
        status.syncing = syncing; status.error = error
        if !syncing && error == nil && completed { status.lastSyncAt = Date() }
        accountSyncStates[account.id] = status; try? await store.save(status, kind: "account-sync-state", id: account.id)
    }
}
