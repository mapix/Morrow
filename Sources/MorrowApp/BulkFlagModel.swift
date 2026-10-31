import Foundation
import MorrowCore

private struct StarGroup: Hashable { let account: String; let folder: String; let validity: UInt64 }
private struct StarTarget { let id: String; let uid: UInt64 }
private struct StarUndo { let account: MailAccount; let folder: String; let validity: UInt64; let uids: [UInt64]; let changes: [MailFlagStateChange] }

extension AppModel {
    func bulkLabel(_ ids: Set<String>, label: String) async {
        guard !batchBusy, !ids.isEmpty else { return }; batchBusy = true; defer { batchBusy = false }
        do {
            let changed = try await store.addLabel(ids: ids, label: label, includeCanonicalCopies: true)
            cacheLabelAddition(Set(changed.map(\.id)), label: label)
            batchStatus = L10n.format("{0}：完成 {1} 封", L10n.t("添加标签"), "\(changed.count)")
            if !changed.isEmpty { offerUndo(L10n.t("添加标签")) { [weak self] in
                guard let self else { return }
                for original in changed { if let metadata = self.mailByID(original.id) { await self.update(metadata) { $0.labels = original.labels } } }
            } }
        } catch { self.error = error.localizedDescription }
    }
    func bulkStar(_ ids: Set<String>, value: Bool) async {
        guard !batchBusy, !ids.isEmpty else { return }; batchBusy = true; defer { batchBusy = false }
        let captured = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        var groups: [StarGroup: [StarTarget]] = [:], local = Set<String>()
        for mail in mails where ids.contains(mail.id) && mail.isStarred != value {
            if let account = captured[mail.accountID], !account.isDemo, !account.usesPOP, mail.uid > 0 {
                groups[.init(account: mail.accountID, folder: mail.folder, validity: mail.uidValidity), default: []].append(.init(id: mail.id, uid: mail.uid))
            } else { local.insert(mail.id) }
        }
        var allChanges: [MailFlagStateChange] = [], localChanges: [MailFlagStateChange] = [], remote: [StarUndo] = [], failures: [String] = []
        do { localChanges = try await store.setStarState(ids: local, starred: value, includeCanonicalCopies: true); allChanges += localChanges }
        catch { failures.append(error.localizedDescription) }
        for (i, entry) in groups.enumerated() {
            let (key, targets) = entry; guard let account = captured[key.account] else { continue }
            batchStatus = L10n.format("批量标记：正在处理 {0}/{1} 组", "\(i + 1)", "\(groups.count)")
            do {
                let result = try await transport.setFlags(account, folder: key.folder, uids: targets.map(\.uid), expectedValidity: key.validity, flag: "\\Flagged", enabled: value, password: credentials.credential(account))
                let confirmed = Set(result.uids)
                let changes = try await store.setStarState(ids: Set(targets.filter { confirmed.contains($0.uid) }.map(\.id)), starred: value, includeCanonicalCopies: true)
                allChanges += changes
                if !result.uids.isEmpty { remote.append(.init(account: account, folder: key.folder, validity: result.uidValidity, uids: result.uids, changes: changes)) }
                if let failure = result.failure { failures.append(failure) }
            } catch { failures.append(error.localizedDescription) }
        }
        cacheStarStates(Dictionary(allChanges.map { ($0.id, value) }, uniquingKeysWith: { _, last in last }), modifiedAt: Date())
        batchStatus = L10n.format("{0}：完成 {1} 封", value ? L10n.t("添加星标") : L10n.t("取消星标"), "\(allChanges.count)")
        if !allChanges.isEmpty { offerUndo(L10n.t("星标")) { [weak self] in
            guard let self else { return }
            var restore = localChanges, errors: [String] = []
            for group in remote {
                do {
                    let result = try await self.transport.setFlags(group.account, folder: group.folder, uids: group.uids, expectedValidity: group.validity, flag: "\\Flagged", enabled: !value, password: self.credentials.credential(group.account))
                    if Set(result.uids) == Set(group.uids) { restore += group.changes }
                    else { errors.append(result.failure ?? "部分星标撤销未完成，请同步后重试。") }
                } catch { errors.append(error.localizedDescription) }
            }
            do {
                let restored = try await self.store.restoreStarState(changes: restore)
                self.cacheStarStates(Dictionary(restore.filter { restored.contains($0.id) }.map { ($0.id, $0.wasEnabled) }, uniquingKeysWith: { _, last in last }), modifiedAt: Date())
            } catch { errors.append(error.localizedDescription) }
            if !errors.isEmpty { self.error = errors.prefix(4).joined(separator: "\n") }
        } }
        if !failures.isEmpty { self.error = failures.prefix(4).joined(separator: "\n") }
    }
}
