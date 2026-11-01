import Foundation
import MorrowCore

extension MobileModel {
    func setMailForeground(_ active: Bool) async {
        mailForeground = active
        if active {
            await refreshMailRealtimeMonitoring()
            await sync(accountScope: "")
        } else {
            realtimeSyncTask?.cancel(); realtimeSyncTask = nil; pendingRealtimeAccounts.removeAll()
            await mailRealtimeMonitor.stop()
        }
    }
    func refreshMailRealtimeMonitoring() async {
        guard mailForeground, ready else { return }
        let credentials = credentials
        await mailRealtimeMonitor.update(accounts: accounts, folders: folders, credential: { account in
            try await credentials.credential(account)
        }, onChange: { [weak self] id in await self?.mailboxChanged(id) })
    }
    private func mailboxChanged(_ id: String) {
        guard mailForeground else { return }
        pendingRealtimeAccounts.insert(id); scheduleRealtimeMailSync()
    }
    func scheduleRealtimeMailSync() {
        guard mailForeground, !syncing, realtimeSyncTask == nil, !pendingRealtimeAccounts.isEmpty else { return }
        realtimeSyncTask = Task { [weak self] in
            guard let self else { return }
            defer { self.realtimeSyncTask = nil; self.scheduleRealtimeMailSync() }
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            guard self.mailForeground, !self.syncing else { return }
            let accounts = self.pendingRealtimeAccounts
            for id in accounts {
                guard !Task.isCancelled else { return }
                self.pendingRealtimeAccounts.remove(id)
                await self.sync(accountScope: id)
            }
        }
    }
}
