import Foundation
import MorrowCore

struct MailReadMutationKey: Hashable {
    let account: String
    let canonical: String
    init(_ mail: MailMessage) { account = mail.accountID; canonical = mail.canonicalID }
}

struct MailReadMutation {
    let id: UUID
    let value: Bool
    let modifiedAt: Date
    let originalStates: [String: Bool]
    var task: Task<Void, Never>?
}

extension AppModel {
    /// Keep server batching and partial receipts, with immediate feedback for
    /// cached rows. Failed rows are restored from storage after the batch.
    func withReadBatchFeedback(ids: Set<String>, value: Bool, operation: @escaping () async -> Void) async {
        guard !batchBusy else { return }
        batchBusy = true; defer { batchBusy = false }
        let keys = Set(mails.filter { ids.contains($0.id) }.map(MailReadMutationKey.init))
        let copies = mails.filter { keys.contains(MailReadMutationKey($0)) }
        let originals = Dictionary(copies.map { ($0.id, $0.isRead) }, uniquingKeysWith: { first, _ in first })
        let previous = keys.compactMap { pendingReadMutations[$0]?.task }
        let id = UUID(), date = Date()
        for key in keys {
            let baseline = pendingReadMutations[key]?.originalStates ?? Dictionary(copies.filter { MailReadMutationKey($0) == key }.map { ($0.id, $0.isRead) }, uniquingKeysWith: { first, _ in first })
            pendingReadMutations[key] = .init(id: id, value: value, modifiedAt: date, originalStates: baseline)
        }
        cacheReadStates(Dictionary(copies.map { ($0.id, value) }, uniquingKeysWith: { _, last in last }), modifiedAt: date)
        let task = Task {
            for task in previous { await task.value }
            await operation()
            let affected = self.mails.filter { keys.contains(MailReadMutationKey($0)) }
            let summaries = try? await self.store.messageSummaries(ids: Set(affected.map(\.id)).union(originals.keys))
            let currentKeys = keys.filter { self.pendingReadMutations[$0]?.id == id }
            for key in currentKeys { self.pendingReadMutations[key] = nil }
            let eligible = Set(affected.filter { currentKeys.contains(MailReadMutationKey($0)) }.map(\.id))
            let states = summaries.map { Dictionary($0.filter { eligible.contains($0.id) }.map { ($0.id, $0.displayMessage.isRead) }, uniquingKeysWith: { _, last in last }) }
                ?? originals.filter { eligible.contains($0.key) }
            self.cacheReadStates(states, modifiedAt: Date())
        }
        for key in keys { pendingReadMutations[key]?.task = task }
        await task.value
    }

    /// Publish before any server or database wait. Requests for the same mail
    /// run in order, while only the latest request controls the visible state.
    @discardableResult
    func beginReadMutation(_ source: MailMessage, value: Bool) -> Task<Void, Never>? {
        let mail = mailByID(source.id) ?? source, key = MailReadMutationKey(mail)
        let previous = pendingReadMutations[key]
        if let previous, previous.value == value { return previous.task }
        let copies = mails.filter { MailReadMutationKey($0) == key }
        guard previous != nil || mail.isRead != value || copies.contains(where: { $0.isRead != value }) else { return nil }
        let id = UUID(), date = Date()
        let originals = previous?.originalStates ?? Dictionary(copies.map { ($0.id, $0.isRead) }, uniquingKeysWith: { first, _ in first })
        pendingReadMutations[key] = .init(id: id, value: value, modifiedAt: date, originalStates: originals)
        cacheReadStates(Dictionary(copies.map { ($0.id, value) }, uniquingKeysWith: { _, last in last }), modifiedAt: date)
        let task = Task { [weak self] in
            await previous?.task?.value
            guard let self else { return }
            do {
                try Task.checkCancellation()
                if let account = self.accounts.first(where: { $0.id == mail.accountID && !$0.isDemo && !$0.usesPOP }), mail.uid > 0 {
                    if let write = self.writeReadFlag { try await write(account, mail, value) }
                    else { try await self.transport.setFlag(account, message: mail, flag: "\\Seen", enabled: value, password: self.credentials.credential(account)) }
                }
                let confirmedAt = Date()
                let changes = try await self.store.setReadState(ids: [mail.id], read: value, modifiedAt: confirmedAt, includeCanonicalCopies: true)
                // An inventory captured before the acknowledgement must not
                // restore its older server flags during the next sync.
                for copy in self.mails where MailReadMutationKey(copy) == key && copy.uid > 0 {
                    self.noteBulkSeen(account: copy.accountID, folder: copy.folder, validity: copy.uidValidity, uids: [copy.uid], value: value, modifiedAt: confirmedAt)
                }
                guard self.pendingReadMutations[key]?.id == id else { return }
                self.pendingReadMutations[key] = nil
                let ids = Set(changes.map(\.id)).union(self.mails.filter { MailReadMutationKey($0) == key }.map(\.id))
                self.cacheReadStates(Dictionary(ids.map { ($0, value) }, uniquingKeysWith: { _, last in last }), modifiedAt: confirmedAt)
            } catch {
                guard self.pendingReadMutations[key]?.id == id else { return }
                // Restore confirmed storage, which may contain a successful
                // earlier request. Preserve other metadata changed meanwhile.
                let ids = Set(originals.keys).union(self.mails.filter { MailReadMutationKey($0) == key }.map(\.id))
                let summaries = try? await self.store.messageSummaries(ids: ids)
                guard self.pendingReadMutations[key]?.id == id else { return }
                self.pendingReadMutations[key] = nil
                let restored = summaries.map { Dictionary($0.map { ($0.id, $0.displayMessage.isRead) }, uniquingKeysWith: { _, last in last }) } ?? originals
                self.cacheReadStates(restored, modifiedAt: Date())
                self.error = error.localizedDescription
            }
        }
        pendingReadMutations[key]?.task = task
        return task
    }
}
