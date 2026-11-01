import Foundation
import MorrowCore

struct BulkSeenKey: Hashable { let account: String; let folder: String; let validity: UInt64; let uid: UInt64 }
private struct ReadGroupKey: Hashable { let account: String; let folder: String; let validity: UInt64 }
private struct ReadTarget { let id: String; let uid: UInt64 }
private struct ReadUndoGroup {
    let account: MailAccount
    let folder: String
    let validity: UInt64
    let uids: [UInt64]
    let value: Bool
    let changedIDs: Set<String>
}

extension AppModel {
    var canMarkWholeFolderRead: Bool { wholeReadFolders() != nil && !accounts.isEmpty }
    private func wholeReadFolders() -> [(MailAccount, String)]? {
        guard !searchMode, category == nil else { return nil }
        let role: String
        if selectedFolder != nil { role = "custom" }
        else { switch destination { case .inbox: role = "inbox"; case .sent: role = "sent"; case .trash: role = "trash"; default: return nil } }
        return accounts.filter { selectedAccount == nil || $0.id == selectedAccount }.compactMap { account in
            if let path = selectedFolder { return (account, path) }
            if role == "inbox" { return (account, "INBOX") }
            return folders.first(where: { $0.accountID == account.id && $0.role == role }).map { (account, $0.path) }
        }
    }
    func markAllReadInCurrentList() async {
        guard !batchBusy else { return }
        guard let folderTargets = wholeReadFolders(), !folderTargets.isEmpty else { await bulkRead(Set(visibleMails.map(\.id)), value: true, all: true); return }
        await markFoldersRead(folderTargets)
    }
    func markFoldersRead(_ folderTargets: [(MailAccount, String)]) async {
        guard !batchBusy, !folderTargets.isEmpty else { return }
        batchBusy = true; defer { batchBusy = false }
        let known = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        var changes: [MailReadStateChange] = [], undoGroups: [ReadUndoGroup] = []
        var localOnly = Set<String>(), failures: [String] = []; var confirmed = 0
        for (i, entry) in folderTargets.enumerated() {
            let (account, folder) = entry
            batchStatus = L10n.format("全部标为已读：正在处理 {0}/{1} 个邮箱文件夹", "\(i + 1)", "\(folderTargets.count)")
            do {
                try Task.checkCancellation()
                if account.isDemo || account.usesPOP {
                    let ids = Set(mails.filter { $0.accountID == account.id && $0.folder == folder && !$0.isRead }.map(\.id))
                    let updated = try await store.setReadState(ids: ids, read: true, includeCanonicalCopies: true)
                    changes += updated; localOnly.formUnion(updated.map(\.id)); confirmed += ids.count
                } else {
                    let validities = Set(mails.filter { $0.accountID == account.id && $0.folder == folder && $0.uid > 0 }.map(\.uidValidity).filter { $0 > 0 })
                    guard validities.count <= 1 else { throw MailError.message("文件夹正在重新同步，请完成同步后再批量标记。") }
                    let receipt = try await transport.markFolderRead(account, folder: folder, expectedValidity: validities.first, password: credentials.credential(account))
                    let date = Date(); noteBulkSeen(account: account.id, folder: folder, validity: receipt.uidValidity, uids: receipt.uids, value: true, modifiedAt: date)
                    let ids = cachedIDs(account: account.id, folder: folder, validity: receipt.uidValidity, uids: Set(receipt.uids))
                    var updated: [MailReadStateChange] = []
                    do { updated = try await store.setReadState(ids: ids, read: true, modifiedAt: date, includeCanonicalCopies: true) }
                    catch { failures.append(account.name + "：服务器标记已确认，本机缓存尚未更新。" + error.localizedDescription) }
                    changes += updated; confirmed += receipt.uids.count
                    if !receipt.uids.isEmpty { undoGroups.append(.init(account: known[account.id] ?? account, folder: folder, validity: receipt.uidValidity, uids: receipt.uids, value: false, changedIDs: Set(updated.map(\.id)))) }
                    if let failure = receipt.failure { failures.append(account.name + "：" + failure) }
                    // Imported mail without a server UID remains a local item.
                    let local = Set(mails.filter { $0.accountID == account.id && $0.folder == folder && $0.uid == 0 && !$0.isRead }.map(\.id))
                    let imported = try await store.setReadState(ids: local, read: true, includeCanonicalCopies: true)
                    changes += imported; localOnly.formUnion(imported.map(\.id)); confirmed += local.count
                }
            } catch { failures.append(account.name + "：" + error.localizedDescription) }
        }
        finishReadBatch(changes: changes, remote: undoGroups, localOnly: localOnly, confirmed: confirmed, failures: failures, value: true, all: true)
    }
    func bulkRead(_ ids: Set<String>, value: Bool, all: Bool = false) async {
        guard !batchBusy, !ids.isEmpty else { return }
        batchBusy = true; defer { batchBusy = false }
        let accountSnapshot = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        var groups: [ReadGroupKey: [ReadTarget]] = [:], local = Set<String>()
        for mail in mails where ids.contains(mail.id) && mail.isRead != value {
            if let account = accountSnapshot[mail.accountID], !account.isDemo, !account.usesPOP, mail.uid > 0 {
                groups[.init(account: mail.accountID, folder: mail.folder, validity: mail.uidValidity), default: []].append(.init(id: mail.id, uid: mail.uid))
            } else { local.insert(mail.id) }
        }
        var changes: [MailReadStateChange] = [], undoGroups: [ReadUndoGroup] = [], failures: [String] = []; var confirmed = 0
        do { let updated = try await store.setReadState(ids: local, read: value, includeCanonicalCopies: true); changes += updated; confirmed += local.count; local = Set(updated.map(\.id)) }
        catch { failures.append(error.localizedDescription) }
        for (i, pair) in groups.sorted(by: { ($0.key.account, $0.key.folder, $0.key.validity) < ($1.key.account, $1.key.folder, $1.key.validity) }).enumerated() {
            let (key, targets) = pair; guard let account = accountSnapshot[key.account] else { continue }
            batchStatus = L10n.format("批量标记：正在处理 {0}/{1} 组", "\(i + 1)", "\(groups.count)")
            do {
                try Task.checkCancellation()
                let receipt = try await transport.setFlags(account, folder: key.folder, uids: targets.map(\.uid), expectedValidity: key.validity, flag: "\\Seen", enabled: value, password: credentials.credential(account))
                let acknowledged = Set(receipt.uids), date = Date()
                noteBulkSeen(account: key.account, folder: key.folder, validity: receipt.uidValidity, uids: receipt.uids, value: value, modifiedAt: date)
                var changed: [MailReadStateChange] = []
                do { changed = try await store.setReadState(ids: Set(targets.filter { acknowledged.contains($0.uid) }.map(\.id)), read: value, modifiedAt: date, includeCanonicalCopies: true) }
                catch { failures.append(account.name + "：服务器标记已确认，本机缓存尚未更新。" + error.localizedDescription) }
                changes += changed; confirmed += acknowledged.count
                if !receipt.uids.isEmpty { undoGroups.append(.init(account: account, folder: key.folder, validity: receipt.uidValidity, uids: receipt.uids, value: !value, changedIDs: Set(changed.map(\.id)))) }
                if let failure = receipt.failure { failures.append(account.name + "：" + failure) }
            } catch { failures.append(account.name + "：" + error.localizedDescription) }
        }
        finishReadBatch(changes: changes, remote: undoGroups, localOnly: local, confirmed: confirmed, failures: failures, value: value, all: all)
    }
    private func cachedIDs(account: String, folder: String, validity: UInt64, uids: Set<UInt64>) -> Set<String> {
        Set(mails.filter { $0.accountID == account && $0.folder == folder && $0.uidValidity == validity && uids.contains($0.uid) }.map(\.id))
    }
    private func finishReadBatch(changes: [MailReadStateChange], remote: [ReadUndoGroup], localOnly: Set<String>, confirmed: Int, failures: [String], value: Bool, all: Bool) {
        let date = Date(); cacheReadStates(Dictionary(changes.map { ($0.id, value) }, uniquingKeysWith: { _, last in last }), modifiedAt: date)
        let name = value ? (all ? L10n.t("全部标为已读") : L10n.t("标为已读")) : L10n.t("标为未读")
        batchStatus = L10n.format("{0}：完成 {1} 封", name, "\(confirmed)") + (failures.isEmpty ? "" : L10n.format("，{0} 组未完成", "\(failures.count)"))
        if confirmed > 0 || !changes.isEmpty {
            let originals = Dictionary(changes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            offerUndo(name) { [weak self] in await self?.undoReadBatch(remote: remote, localOnly: localOnly, originals: originals) }
        }
        if !failures.isEmpty { error = failures.prefix(4).joined(separator: "\n") }
    }
    private func undoReadBatch(remote: [ReadUndoGroup], localOnly: Set<String>, originals: [String: MailReadStateChange]) async {
        guard !batchBusy else { return }; batchBusy = true; defer { batchBusy = false }
        var eligible = localOnly, failures: [String] = []
        for group in remote {
            do {
                let receipt = try await transport.setFlags(group.account, folder: group.folder, uids: group.uids, expectedValidity: group.validity, flag: "\\Seen", enabled: group.value, password: credentials.credential(group.account))
                let acknowledged = Set(receipt.uids); noteBulkSeen(account: group.account.id, folder: group.folder, validity: group.validity, uids: receipt.uids, value: group.value, modifiedAt: Date())
                if acknowledged.count == Set(group.uids).count { eligible.formUnion(group.changedIDs) }
                else {
                    let ids = cachedIDs(account: group.account.id, folder: group.folder, validity: group.validity, uids: acknowledged)
                    let canonical = Set(mails.filter { ids.contains($0.id) }.map(\.canonicalID))
                    eligible.formUnion(mails.filter { group.changedIDs.contains($0.id) && canonical.contains($0.canonicalID) }.map(\.id))
                }
                if let failure = receipt.failure { failures.append(failure) }
            } catch { failures.append(error.localizedDescription) }
        }
        do {
            let selected = eligible.compactMap { originals[$0] }, date = Date()
            let restored = try await store.restoreReadState(changes: selected, modifiedAt: date)
            cacheReadStates(Dictionary(selected.filter { restored.contains($0.id) }.map { ($0.id, $0.wasRead) }, uniquingKeysWith: { _, last in last }), modifiedAt: date)
            batchStatus = L10n.t("已撤销批量已读标记")
        } catch { failures.append(error.localizedDescription) }
        if !failures.isEmpty { error = failures.prefix(4).joined(separator: "\n"); batchStatus = L10n.t("部分撤销尚未完成，请同步后重试") }
    }
}
