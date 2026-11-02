import Foundation
import MorrowCore

extension AppModel {
    func refreshMailRealtimeMonitoring() async {
        let credentials = credentials
        await mailRealtimeMonitor.update(accounts: accounts, folders: folders.filter(settings.effectiveMailSyncScope.includes), credential: { account in
            try await credentials.credential(account)
        }, onChange: { [weak self] accountID in
            await self?.mailboxChanged(accountID)
        })
    }
    private func mailboxChanged(_ accountID: String) {
        guard Date() >= mailRealtimeSuspendedUntil else { return }
        pendingRealtimeAccounts.insert(accountID)
        scheduleRealtimeMailSync()
    }
    func scheduleRealtimeMailSync() {
        guard !syncBusy, realtimeSyncTask == nil, !pendingRealtimeAccounts.isEmpty else { return }
        realtimeSyncTask = Task { [weak self] in
            guard let self else { return }
            defer { self.realtimeSyncTask = nil; self.scheduleRealtimeMailSync() }
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            guard !self.syncBusy else { return }
            let accounts = self.pendingRealtimeAccounts
            for id in accounts {
                guard !Task.isCancelled else { return }
                self.pendingRealtimeAccounts.remove(id)
                await self.sync(accountID: id)
            }
        }
    }
}
