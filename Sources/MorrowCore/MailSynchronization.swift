import Foundation

public struct MailSyncFlags: Codable, Sendable, Equatable {
    public var read: Bool
    public var starred: Bool
    public init(read: Bool, starred: Bool) { self.read = read; self.starred = starred }
}

/// Server inventory survives interrupted history downloads. The mod-sequence
/// advances only after its flag/deletion changes have been committed locally.
public struct MailFolderSyncCursor: Codable, Sendable {
    public var accountID: String
    public var folder: String
    public var accountFingerprint: String
    public var validity: UInt64
    public var highestModSequence: UInt64?
    public var uidNext: UInt64?
    public var knownUIDs: [UInt64]
    public var id: String { MailStore.hash(accountID + "\n" + folder) }
    public init(account: MailAccount, folder: String, validity: UInt64, highestModSequence: UInt64?, uidNext: UInt64?, knownUIDs: Set<UInt64>) {
        accountID = account.id; self.folder = folder; accountFingerprint = Self.fingerprint(account)
        self.validity = validity; self.highestModSequence = highestModSequence; self.uidNext = uidNext
        self.knownUIDs = knownUIDs.sorted()
    }
    public static func fingerprint(_ account: MailAccount) -> String {
        MailStore.hash([account.email, account.imapHost, String(account.imapPort), account.authMethod].joined(separator: "\n"))
    }
    public func matches(_ account: MailAccount, folder: String) -> Bool {
        accountID == account.id && self.folder == folder && accountFingerprint == Self.fingerprint(account)
            && validity > 0 && validity <= UInt64(UInt32.max)
            && knownUIDs.allSatisfy { $0 > 0 && $0 <= UInt64(UInt32.max) }
    }
}

public struct MailSyncInventory: Sendable {
    public var validity: UInt64
    public var flags: [UInt64: MailSyncFlags]
    public var presentUIDs: Set<UInt64>
    public var highestModSequence: UInt64?
    public var uidNext: UInt64?
    public var incremental: Bool
    public func cursor(account: MailAccount, folder: String) -> MailFolderSyncCursor {
        .init(account: account, folder: folder, validity: validity, highestModSequence: highestModSequence, uidNext: uidNext, knownUIDs: presentUIDs)
    }
}

/// A folder-local UID plan. A server cursor knows membership, not which bodies
/// have already reached local storage or the durable processing queue.
public struct MailSyncDownloadPlan: Sendable, Equatable {
    public var serverCount: Int
    public var savedCount: Int
    public var queuedCount: Int
    public var remainingUIDs: [UInt64]
    public var reusedCount: Int { savedCount + queuedCount }
    public init(presentUIDs: Set<UInt64>, savedUIDs: Set<UInt64>, queuedUIDs: Set<UInt64>) {
        let saved = savedUIDs.intersection(presentUIDs)
        let queued = queuedUIDs.intersection(presentUIDs).subtracting(saved)
        serverCount = presentUIDs.count; savedCount = saved.count; queuedCount = queued.count
        remainingUIDs = presentUIDs.subtracting(saved).subtracting(queued).sorted(by: >)
    }
}

extension MailStore {
    public func mailSyncCursor(account: MailAccount, folder: String) throws -> MailFolderSyncCursor? {
        let id = Self.hash(account.id + "\n" + folder)
        guard let cursor = try object(MailFolderSyncCursor.self, kind: "mail-sync-cursor", id: id), cursor.matches(account, folder: folder) else { return nil }
        return cursor
    }
    public func mailSyncDownloadPlan(account: MailAccount, folder: String, inventory: MailSyncInventory) throws -> MailSyncDownloadPlan {
        let saved = Set(try syncRecords(account: account.id, folder: folder).filter { $0.uidValidity == inventory.validity && $0.uid > 0 }.map(\.uid))
        let queued = Set(try queuedMailDownloads().filter { $0.accountID == account.id && $0.folder == folder && $0.validity == inventory.validity }.map(\.uid))
        return .init(presentUIDs: inventory.presentUIDs, savedUIDs: saved, queuedUIDs: queued)
    }
}

/// IDLE uses dedicated sockets, so listening never blocks downloads or STORE.
/// Incoming mail is watched in INBOX and, where available, the all-mail archive.
/// Other folders and servers without IDLE are covered by periodic sync.
public actor MailRealtimeMonitor {
    private struct Watch { var fingerprint: String; var task: Task<Void, Never> }
    private var watches: [String: Watch] = [:]
    public init() {}
    public func stop() { for watch in watches.values { watch.task.cancel() }; watches.removeAll() }
    public func update(accounts: [MailAccount], folders: [MailFolder], credential: @escaping @Sendable (MailAccount) async throws -> String,
                       onChange: @escaping @Sendable (String) async -> Void) {
        var desired: [String: (MailAccount, String)] = [:]
        for account in accounts where account.enabled && !account.isDemo && !account.usesPOP {
            let own = folders.filter { $0.accountID == account.id }
            let inbox = own.first(where: { $0.role == "inbox" })?.path ?? "INBOX"
            var paths = [inbox]
            if let archive = own.first(where: { $0.role == "archive" }), archive.path != inbox { paths.append(archive.path) }
            for path in paths { desired[account.id + "\n" + path] = (account, path) }
        }
        for key in Array(watches.keys) where desired[key] == nil { watches.removeValue(forKey: key)?.task.cancel() }
        for (key, value) in desired {
            let (account, folder) = value, fingerprint = MailFolderSyncCursor.fingerprint(value.0)
            if watches[key]?.fingerprint == fingerprint { continue }
            watches.removeValue(forKey: key)?.task.cancel()
            let task = Task {
                let client = IMAPConnection(); var retry: Double = 2
                while !Task.isCancelled {
                    do {
                        if !(await client.connected) {
                            let secret = try await credential(account)
                            try await client.connect(host: account.imapHost, port: account.imapPort, email: account.email, password: secret, oauth: account.authMethod == "oauth")
                            guard await client.supportsIdle else { await client.close(); return }
                            _ = try await client.select(folder)
                            // Catch changes during a disconnect or before IDLE starts.
                            await onChange(account.id)
                        }
                        let changed = try await client.waitForChange(folder: folder)
                        retry = 2
                        if changed { await onChange(account.id) }
                    } catch {
                        await client.close()
                        if Task.isCancelled { break }
                        do { try await Task.sleep(for: .seconds(retry)) } catch { break }
                        retry = min(60, retry * 2)
                    }
                }
                await client.close()
            }
            watches[key] = .init(fingerprint: fingerprint, task: task)
        }
    }
}
