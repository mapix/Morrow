import Foundation
import CloudKit
import Security

private struct CloudIncomingFailure: Codable, Sendable, Identifiable {
    var id: String
    var reason: String
}

public struct CloudSyncStatus: Sendable {
    public var enabled = false
    public var busy = false
    public var message = "iCloud sync is off."
    public var lastSync: Date?
    public var importedRevision = 0
    public init() {}
}

/// There is no CKContainer, engine or cloud request until start() is explicitly called.
public actor CloudSyncService: CKSyncEngineDelegate {
    private let store: MailStore
    private let zoneID: CKRecordZone.ID
    private var engine: CKSyncEngine?
    private var current = CloudSyncStatus()
    private var syncing = false
    private var stateURL: URL { store.root.appendingPathComponent("icloud-engine-state.json") }
    private var recordCache: [String: CKRecord] = [:]
    private var stagedFiles: [String: [URL]] = [:]
    private var blockedRecords: [String: String] = [:]
    private var lifecycle = 0
    public init(store: MailStore, zoneName: String = "SmailWorkspaceV1") { self.store = store; self.zoneID = CKRecordZone.ID(zoneName: zoneName) }
    public func status() -> CloudSyncStatus { current }

    public static func configuredContainer() -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "MorrowCloudKitContainer") as? String, !value.isEmpty else { return nil }
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil), let entries = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil) as? [String], entries.contains(value) else { return nil }
        #endif
        return value
    }
    public func start() async throws {
        guard engine == nil else { return }
        lifecycle += 1; let attempt = lifecycle
        guard let identifier = Self.configuredContainer() else { throw MailError.message("This build has no signed iCloud container. Sync remains off.") }
        let container = CKContainer(identifier: identifier)
        guard try await container.accountStatus() == .available else { throw MailError.message("Sign in to iCloud in System Settings before enabling sync.") }
        try Task.checkCancellation(); guard lifecycle == attempt else { throw CancellationError() }
        let account = try await container.userRecordID().recordName
        try Task.checkCancellation(); guard lifecycle == attempt else { throw CancellationError() }
        let accountKey = MailStore.hash(account)
        let bindingURL = store.root.appendingPathComponent("icloud-account-binding.txt")
        if let previous = try? String(contentsOf: bindingURL, encoding: .utf8), previous != accountKey {
            throw MailError.message("The iCloud account changed. Use a separate local workspace to keep the two accounts separate.")
        }
        try privateWrite(Data(accountKey.utf8), to: bindingURL)
        let serialization = (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
        var configuration = CKSyncEngine.Configuration(database: container.privateCloudDatabase, stateSerialization: serialization, delegate: self)
        configuration.automaticallySync = false
        let created = CKSyncEngine(configuration); engine = created
        current.enabled = true; current.message = "iCloud sync is ready."
        created.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
        try await store.seedCloudJournal()
        try Task.checkCancellation(); guard lifecycle == attempt, engine === created else { throw CancellationError() }
        try await sync()
        try Task.checkCancellation(); guard lifecycle == attempt, engine === created else { throw CancellationError() }
    }
    public func stop() async {
        lifecycle += 1
        let previous = engine; engine = nil
        current.enabled = false; current.busy = false; current.message = "iCloud sync is off."
        await previous?.cancelOperations()
        recordCache.removeAll(); cleanupFiles()
    }
    public func sync() async throws {
        guard let active = engine, !syncing else { return }
        syncing = true; current.busy = true; current.message = "Synchronizing iCloud…"
        defer { syncing = false; current.busy = false }
        do {
            blockedRecords.removeAll()
            try await retryIncoming(active)
            // Fetch first so optimistic writes include the most recent server change tag.
            try await active.fetchChanges(CKSyncEngine.FetchChangesOptions(scope: .zoneIDs([zoneID])))
            guard engine === active else { return }
            let pending = try await store.cloudChanges().map { CKSyncEngine.PendingRecordZoneChange.saveRecord(CKRecord.ID(recordName: $0.id, zoneID: zoneID)) }
            active.state.add(pendingRecordZoneChanges: pending)
            try await active.sendChanges(CKSyncEngine.SendChangesOptions(scope: .zoneIDs([zoneID])))
            guard engine === active else { return }
            current.lastSync = Date()
            let remaining = try await store.cloudChanges().count
            let incoming = try await store.load(CloudIncomingFailure.self, kind: "cloud-incoming-failure")
            let total = remaining + incoming.count
            current.message = total == 0 ? "iCloud synchronized." : "iCloud has \(total) pending records. " + (blockedRecords.values.first ?? incoming.first?.reason ?? "They will retry during the next sync.")
        } catch {
            current.message = "iCloud sync paused: " + error.localizedDescription
            throw error
        }
    }

    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard engine === syncEngine else { return }
        do {
            switch event {
            case .stateUpdate(let update): try privateWrite(JSONEncoder().encode(update.stateSerialization), to: stateURL)
            case .accountChange(let change):
                switch change.changeType {
                case .signIn: break
                case .signOut, .switchAccounts:
                    await stop(); current.message = "The iCloud account changed. Sync is off to protect this workspace."
                @unknown default: await stop()
                }
            case .fetchedRecordZoneChanges(let changes):
                for modification in changes.modifications {
                    guard engine === syncEngine else { return }
                    do {
                        try await accept(modification.record)
                        try await store.remove(kind: "cloud-incoming-failure", id: modification.record.recordID.recordName)
                    } catch {
                        let failure = CloudIncomingFailure(id: modification.record.recordID.recordName, reason: error.localizedDescription)
                        try await store.save(failure, kind: "cloud-incoming-failure", id: failure.id)
                        current.message = "iCloud incoming record is pending: " + error.localizedDescription
                    }
                }
                // Our deletes are durable tombstone records. An external zone/record deletion is never an instruction to purge local data.
                if !changes.deletions.isEmpty { current.message = "Cloud records were removed externally. Local work has been retained." }
            case .sentRecordZoneChanges(let changes):
                for record in changes.savedRecords {
                    recordCache[record.recordID.recordName] = record
                    try await cacheSystemFields(record)
                    if let acknowledged = try decodeChange(record) { try await store.acknowledgeCloudChange(acknowledged) }
                    cleanupFiles(record.recordID.recordName)
                }
                for failure in changes.failedRecordSaves {
                    if failure.error.code == .serverRecordChanged, let server = failure.error.serverRecord { try await accept(server) }
                    else if failure.error.code == .zoneNotFound { syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))]) }
                    else { current.message = "iCloud save pending: " + failure.error.localizedDescription }
                }
            case .fetchedDatabaseChanges(let changes):
                if changes.deletions.contains(where: { $0.zoneID == zoneID }) { await stop(); current.message = "The iCloud workspace was removed. Local work has been retained; sync is off." }
            default: break
            }
        } catch { current.message = "iCloud data could not be applied: " + error.localizedDescription }
    }
    public func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard engine === syncEngine else { return nil }
        do {
            let allowed = Set(syncEngine.state.pendingRecordZoneChanges.compactMap { change -> String? in if case .saveRecord(let id) = change { return id.recordName }; return nil })
            let changes = try await store.cloudChanges().filter { allowed.contains($0.id) }
            var records: [CKRecord] = []
            for change in changes {
                guard records.count < 50 else { break }
                do { records.append(try await makeRecord(change)); blockedRecords.removeValue(forKey: change.id) }
                catch { blockedRecords[change.id] = error.localizedDescription; cleanupFiles(change.id) }
            }
            return records.isEmpty ? nil : CKSyncEngine.RecordZoneChangeBatch(recordsToSave: records)
        } catch { current.message = "iCloud upload pending: " + error.localizedDescription; return nil }
    }
    private func makeRecord(_ change: CloudWorkspaceChange) async throws -> CKRecord {
        let id = CKRecord.ID(recordName: change.id, zoneID: zoneID)
        let savedFields = try await store.object(Data.self, kind: "cloud-record-state", id: change.id)
        let record: CKRecord
        if let cached = recordCache[change.id] { record = try copySystemFields(cached) }
        else if let savedFields { record = try restoreSystemFields(savedFields) }
        else { record = CKRecord(recordType: "WorkspaceObject", recordID: id) }
        record["kind"] = change.kind; record["objectID"] = change.objectID
        record["clock"] = NSNumber(value: change.clock); record["device"] = change.deviceID
        record["deleted"] = NSNumber(value: change.payload == nil)
        cleanupFiles(change.id)
        if let raw = change.payload {
            let prepared = try CloudWorkspacePolicy.preparedPayload(raw, kind: change.kind)
            let (payload, assets, names) = try prepareMaterials(prepared, kind: change.kind, recordID: change.id)
            let url = try stagingURL(change.id + "-payload")
            try privateWrite(payload, to: url); stagedFiles[change.id, default: []].append(url)
            record["payload"] = CKAsset(fileURL: url)
            record["materials"] = assets as NSArray; record["materialNames"] = names as NSArray
        } else { record["payload"] = nil; record["materials"] = nil; record["materialNames"] = nil }
        return record
    }
    private func retryIncoming(_ active: CKSyncEngine) async throws {
        let failures = try await store.load(CloudIncomingFailure.self, kind: "cloud-incoming-failure")
        for failure in failures.prefix(50) {
            guard engine === active else { return }
            do {
                let record = try await active.database.record(for: CKRecord.ID(recordName: failure.id, zoneID: zoneID))
                guard engine === active else { return }
                try await accept(record)
                try await store.remove(kind: "cloud-incoming-failure", id: failure.id)
            } catch let error as CKError where error.code == .unknownItem {
                // The source was removed externally; retain local work without retrying forever.
                try await store.remove(kind: "cloud-incoming-failure", id: failure.id)
            } catch {
                try await store.save(CloudIncomingFailure(id: failure.id, reason: error.localizedDescription), kind: "cloud-incoming-failure", id: failure.id)
            }
        }
    }
    private func prepareMaterials(_ payload: Data, kind: String, recordID: String) throws -> (Data, [CKAsset], [String]) {
        guard kind == "chat" || kind == "chat-session" else { return (payload, [], []) }
        guard var object = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else { throw MailError.message("Invalid iCloud chat payload.") }
        var materials = object["materials"] as? [[String: Any]] ?? []
        var assets: [CKAsset] = [], names: [String] = []
        for i in materials.indices {
            guard let path = materials[i]["path"] as? String, let identity = materials[i]["id"] as? String else { throw MailError.message("Invalid chat material.") }
            let file = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            let root = store.root.resolvingSymlinksInPath().path + "/"
            guard file.path.hasPrefix(root) else { throw MailError.message("A chat file must be copied into the local workspace before iCloud sync.") }
            let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
            guard ((attrs[.size] as? NSNumber)?.intValue ?? Int.max) <= CloudWorkspacePolicy.maximumAssetBytes else { throw MailError.message("Chat files larger than 50 MB stay on this device.") }
            let name = MailStore.hash(identity + ":" + MailStore.hash(try Data(contentsOf: file)))
            let destination = try stagingURL(recordID + "-" + name)
            try FileManager.default.copyItem(at: file, to: destination)
            stagedFiles[recordID, default: []].append(destination)
            materials[i]["path"] = "cloud-material:" + name
            names.append(name); assets.append(CKAsset(fileURL: destination))
        }
        object["materials"] = materials
        return (try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), assets, names)
    }
    private func decodeChange(_ record: CKRecord) throws -> CloudWorkspaceChange? {
        guard record.recordType == "WorkspaceObject", record.recordID.zoneID == zoneID,
              let kind = record["kind"] as? String, CloudWorkspacePolicy.kinds.contains(kind), let id = record["objectID"] as? String,
              let clock = record["clock"] as? NSNumber, let device = record["device"] as? String else { return nil }
        let deleted = (record["deleted"] as? NSNumber)?.boolValue ?? false
        let payload = deleted ? nil : try (record["payload"] as? CKAsset)?.fileURL.map { try Data(contentsOf: $0) }
        guard deleted || payload != nil else { throw MailError.message("iCloud payload is missing; local data was retained.") }
        let change = CloudWorkspaceChange(kind: kind, objectID: id, payload: payload, clock: clock.int64Value, deviceID: device, dirty: false)
        guard change.id == record.recordID.recordName else { throw MailError.message("iCloud record identity mismatch.") }
        return change
    }
    private func accept(_ record: CKRecord) async throws {
        guard var change = try decodeChange(record) else { return }
        recordCache[record.recordID.recordName] = record; try await cacheSystemFields(record)
        if let payload = change.payload, change.kind == "chat" || change.kind == "chat-session" {
            guard var object = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else { throw MailError.message("Invalid iCloud chat payload.") }
            var materials = object["materials"] as? [[String: Any]] ?? []
            let names = record["materialNames"] as? [String] ?? [], assets = record["materials"] as? [CKAsset] ?? []
            guard names.count == assets.count else { throw MailError.message("Incomplete iCloud chat files.") }
            for i in materials.indices {
                guard let path = materials[i]["path"] as? String, path.hasPrefix("cloud-material:") else { throw MailError.message("Untrusted iCloud material path.") }
                let name = String(path.dropFirst("cloud-material:".count))
                guard name.count == 64, name.allSatisfy({ $0.isHexDigit }), let position = names.firstIndex(of: name), let source = assets[position].fileURL else { throw MailError.message("An iCloud chat file is missing.") }
                let data = try Data(contentsOf: source)
                guard data.count <= CloudWorkspacePolicy.maximumAssetBytes else { throw MailError.message("iCloud chat file exceeds 50 MB.") }
                let destination = store.root.appendingPathComponent("cloud-materials/" + name)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try privateWrite(data, to: destination); materials[i]["path"] = destination.path
            }
            object["materials"] = materials; change.payload = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }
        if try await store.importCloudChange(change) { current.importedRevision += 1 }
    }
    private func stagingURL(_ name: String) throws -> URL {
        let directory = store.root.appendingPathComponent("cloud-staging")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return directory.appendingPathComponent(name + "-" + UUID().uuidString)
    }
    private func privateWrite(_ data: Data, to url: URL) throws { try data.write(to: url, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
    private func cacheSystemFields(_ record: CKRecord) async throws {
        let coder = NSKeyedArchiver(requiringSecureCoding: true); record.encodeSystemFields(with: coder); coder.finishEncoding()
        try await store.save(coder.encodedData, kind: "cloud-record-state", id: record.recordID.recordName)
    }
    private func copySystemFields(_ record: CKRecord) throws -> CKRecord {
        let coder = NSKeyedArchiver(requiringSecureCoding: true); record.encodeSystemFields(with: coder); coder.finishEncoding()
        return try restoreSystemFields(coder.encodedData)
    }
    private func restoreSystemFields(_ data: Data) throws -> CKRecord {
        let decoder = try NSKeyedUnarchiver(forReadingFrom: data); decoder.requiresSecureCoding = true
        defer { decoder.finishDecoding() }
        guard let record = CKRecord(coder: decoder) else { throw MailError.message("Invalid saved iCloud record metadata.") }
        return record
    }
    private func cleanupFiles(_ id: String? = nil) {
        for key in id.map({ [$0] }) ?? Array(stagedFiles.keys) { for file in stagedFiles.removeValue(forKey: key) ?? [] { try? FileManager.default.removeItem(at: file) } }
    }
}
