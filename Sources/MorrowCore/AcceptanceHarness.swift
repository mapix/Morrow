import Foundation
import CloudKit

/// Opt-in, synthetic-only acceptance operations. Normal application startup never calls this service.
public enum AcceptanceMode: String, Codable, Sendable, CaseIterable {
    case gemma
    case cloudPublish = "cloud-publish"
    case cloudReceive = "cloud-receive"
    case cloudUpdate = "cloud-update"
    case cloudVerifyUpdate = "cloud-verify-update"
    case cloudDelete = "cloud-delete"
    case cloudVerifyDelete = "cloud-verify-delete"
}

public struct AcceptanceRequest: Sendable {
    public var mode: AcceptanceMode
    public var id: UUID
    public var peerBinding: String?
    public var modelDirectory: URL?

    public static func parse(arguments: [String] = ProcessInfo.processInfo.arguments) throws -> Self? {
        guard arguments.contains("--acceptance-mode") else { return nil }
        func value(_ flag: String) throws -> String? {
            let positions = arguments.indices.filter { arguments[$0] == flag }
            guard positions.count <= 1 else { throw MailError.message("Duplicate acceptance argument: " + flag) }
            guard let position = positions.first else { return nil }
            guard position + 1 < arguments.count, !arguments[position + 1].hasPrefix("--") else { throw MailError.message("Missing acceptance argument: " + flag) }
            return arguments[position + 1]
        }
        guard let rawMode = try value("--acceptance-mode"), let mode = AcceptanceMode(rawValue: rawMode) else { throw MailError.message("Unknown acceptance mode.") }
        guard let rawID = try value("--acceptance-id"), let id = UUID(uuidString: rawID) else { throw MailError.message("Acceptance requires a UUID identifier.") }
        let peer = try value("--acceptance-peer-binding")
        if let peer { guard peer.count == 64, peer.allSatisfy(\.isHexDigit) else { throw MailError.message("Acceptance peer binding must be a SHA-256 hash.") } }
        if mode != .gemma && mode != .cloudPublish && peer == nil { throw MailError.message("This cloud phase requires the publishing device's acceptance account binding.") }
        return Self(mode: mode, id: id, peerBinding: peer, modelDirectory: try value("--acceptance-model-directory").map { URL(fileURLWithPath: $0) })
    }

    public func workspace(in parent: URL) -> URL { parent.appendingPathComponent("acceptance-" + id.uuidString.lowercased(), isDirectory: true) }
}

public struct AcceptanceCheck: Codable, Sendable {
    public var name: String
    public var passed: Bool
    public var detail: String
}

public struct AcceptanceQueryProof: Codable, Sendable {
    public var query: String
    public var dimension: Int
    public var finite: Bool
    public var norm: Double
    public var vectorHash: String
    public var expectedMailID: String
    public var firstMailID: String
    public var cosine: Float
    public var method: String
}

/// This proof contains only test identifiers, public model metadata and synthetic fixture results.
public struct AcceptanceProof: Codable, Sendable {
    public var schemaVersion = 1
    public var acceptanceID: String
    public var mode: String
    public var platform: String
    public var startedAt: Date
    public var finishedAt: Date?
    public var finished = false
    public var passed = false
    public var phase = "starting"
    public var checkpoint: String?
    public var modelBytes: Int?
    public var cloudZone: String?
    public var accountBinding: String?
    public var importedRevision: Int?
    public var pendingRecords: Int?
    public var checks: [AcceptanceCheck] = []
    public var queries: [AcceptanceQueryProof] = []
    public var error: String?
}

public actor AcceptanceHarness {
    public init() {}
    public static var platform: String {
        #if targetEnvironment(simulator)
        return "iOS simulator"
        #elseif os(iOS)
        return "iOS physical device"
        #elseif os(macOS)
        return "macOS physical device"
        #else
        return "unsupported"
        #endif
    }
    public static func proofURL(mode: AcceptanceMode, workspace: URL) -> URL { workspace.appendingPathComponent("proof-" + mode.rawValue + ".json") }
    public static func zoneName(id: UUID) -> String { "MorrowAcceptanceV1-" + id.uuidString.lowercased() }

    /// workspace must be the request's separate acceptance-ID directory, never a real MailStore root.
    public func run(mode: AcceptanceMode, id: UUID, workspace: URL, modelDir: URL?, peerBinding: String? = nil) async -> AcceptanceProof {
        var proof = AcceptanceProof(acceptanceID: id.uuidString.lowercased(), mode: mode.rawValue, platform: Self.platform, startedAt: Date())
        let destination = Self.proofURL(mode: mode, workspace: workspace)
        var activeCloud: CloudSyncService?
        do {
            let resolved = workspace.resolvingSymlinksInPath()
            let directLink = (try? workspace.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
            guard resolved.lastPathComponent == "acceptance-" + id.uuidString.lowercased(), !directLink else { throw MailError.message("Acceptance workspace must be an isolated acceptance-ID directory without a redirected directory link.") }
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let marker = workspace.appendingPathComponent("acceptance-id.txt")
            if let prior = try? String(contentsOf: marker, encoding: .utf8) { guard prior == id.uuidString.lowercased() else { throw MailError.message("Acceptance workspace identifier mismatch.") } }
            else { try Self.privateWrite(Data(id.uuidString.lowercased().utf8), to: marker) }
            try Self.write(proof, to: destination)
            let store = try MailStore(root: workspace)
            try await assertSyntheticStore(store, id: id)
            proof.checks.append(.init(name: "isolated-synthetic-workspace", passed: true, detail: "Separate acceptance store; no account, credentials or executable queues are loaded."))
            if mode == .gemma {
                proof.phase = "loading-bundled-gemma"; try Self.write(proof, to: destination)
                try await gemma(store: store, id: id, modelDir: modelDir, proof: &proof, destination: destination)
            } else {
                let zone = Self.zoneName(id: id); proof.cloudZone = zone
                proof.phase = "checking-icloud-account"; try Self.write(proof, to: destination)
                let binding = try await cloudBinding(id: id)
                proof.accountBinding = binding
                if mode != .cloudPublish { guard let peerBinding, peerBinding == binding else { throw MailError.message("Acceptance devices use different iCloud accounts, or the peer account binding is missing. No test records were synchronized.") } }
                proof.checks.append(.init(name: "same-icloud-account", passed: true, detail: peerBinding == nil ? "Publishing identity recorded as an acceptance-specific hash." : "Acceptance-specific account hash matches the publishing device."))
                let cloud = CloudSyncService(store: store, zoneName: zone); activeCloud = cloud
                try await cloudPhase(mode: mode, id: id, store: store, cloud: cloud, proof: &proof, destination: destination)
                await cloud.stop(); activeCloud = nil
            }
            proof.passed = !proof.checks.isEmpty && proof.checks.allSatisfy(\.passed)
            proof.phase = proof.passed ? "passed" : "failed"
        } catch {
            if let activeCloud { await activeCloud.stop() }
            proof.error = error.localizedDescription
            proof.checks.append(.init(name: "operation-completed", passed: false, detail: error.localizedDescription))
            proof.phase = "failed"
        }
        proof.finished = true; proof.finishedAt = Date()
        try? Self.write(proof, to: destination)
        return proof
    }

    private func assertSyntheticStore(_ store: MailStore, id: UUID) async throws {
        guard try await store.load(MailAccount.self, kind: "account").isEmpty else { throw MailError.message("Acceptance refuses a store containing mailbox accounts.") }
        let prefix = id.uuidString.lowercased() + "-"
        guard try await store.messages().allSatisfy({ $0.id.hasPrefix(prefix) }), try await store.cloudChanges(dirtyOnly: false).allSatisfy({ $0.objectID.hasPrefix(prefix) }) else { throw MailError.message("Acceptance refuses a store containing non-synthetic records.") }
    }

    private func gemma(store: MailStore, id: UUID, modelDir: URL?, proof: inout AcceptanceProof, destination: URL) async throws {
        #if targetEnvironment(simulator)
        throw MailError.message("Real Gemma acceptance requires a physical device; a simulator result cannot pass.")
        #else
        guard let modelDir else { throw MailError.message("The bundled EmbeddingGemma2-Text model directory was not found.") }
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: modelDir.appendingPathComponent("smail-manifest.json"))) as? [String: Any]
        guard manifest?["repo"] as? String == "mlx-community/embeddinggemma-2-bf16", manifest?["revision"] as? String == "1a4ffddb7905d3f63486748deabe091a01fb6201" else { throw MailError.message("Acceptance requires the pinned EmbeddingGemma 2 checkpoint.") }
        proof.checkpoint = EmbeddingIndex.checkpoint
        proof.modelBytes = (try FileManager.default.attributesOfItem(atPath: modelDir.appendingPathComponent("model.safetensors").path)[.size] as? NSNumber)?.intValue
        let index = EmbeddingIndex(); try await index.load(directory: modelDir.path)
        let prefix = id.uuidString.lowercased() + "-"
        let fixtures = [
            ("delivery", "发布准备", "周五发布前请核对接口材料。请回复你发现的问题，我们会根据反馈修改。附件是本次交付清单。"),
            ("invoice", "合作账单", "请核对合作项目账单，包括项目名称与开票信息。确认后我们再开票。"),
            ("hotel", "入住安排", "The room will be ready on Saturday at 3 pm. Bring an identity document to the hotel reception."),
            ("garden", "社区花园", "花园本周种植番茄和薄荷。请在清晨浇水，避免正午阳光照射新苗。")
        ]
        proof.phase = "indexing-synthetic-mail"; try Self.write(proof, to: destination)
        for (slot, fixture) in fixtures.enumerated() {
            var mail = MailMessage(accountID: prefix + "synthetic-account", from: .init(name: "Synthetic fixture", email: "fixture@example.invalid"), subject: fixture.1, text: fixture.2)
            mail.id = prefix + fixture.0; mail.messageID = "<" + mail.id + "@example.invalid>"; mail.date = Date(timeIntervalSince1970: 1_750_000_000 + Double(slot))
            if slot == 0 { mail.attachments = [.init(name: "synthetic-delivery.md", mimeType: "text/markdown", data: Data("接口清单：鉴权接口、账单查询；错误响应应包含请求 ID。".utf8))] }
            mail = try await store.upsert(mail); _ = try await index.index(mail, store: store, attachments: true)
        }
        let coverage = try await index.searchCoverage(store: store)
        proof.checks.append(.init(name: "complete-current-checkpoint-index", passed: coverage.isComplete && coverage.eligibleCount == 4 && coverage.modelIdentity == EmbeddingIndex.checkpoint, detail: "Indexed \(coverage.indexedCount)/\(coverage.eligibleCount) synthetic messages with the pinned checkpoint."))
        let queries = ["Find the request to inspect delivery documentation before software deployment", "上线之前有哪些接口材料需要审阅"]
        proof.phase = "running-semantic-inference"; try Self.write(proof, to: destination)
        for query in queries {
            let vector = try await index.embed(query, query: true)
            let hits = try await index.search(query, store: store, strategy: .semantic)
            let norm = sqrt(vector.reduce(0) { $0 + Double($1) * Double($1) })
            let hash = vector.withUnsafeBytes { MailStore.hash(Data($0)) }
            proof.queries.append(.init(query: query, dimension: vector.count, finite: vector.allSatisfy(\.isFinite), norm: norm, vectorHash: hash, expectedMailID: prefix + "delivery", firstMailID: hits.first?.id ?? "", cosine: hits.first?.score ?? 0, method: hits.first?.method ?? ""))
            try Self.write(proof, to: destination)
        }
        proof.checks.append(.init(name: "768-dimensional-real-inference", passed: proof.queries.allSatisfy { $0.dimension == 768 && $0.finite && abs($0.norm - 1) < 0.02 }, detail: "Both language queries produced normalized, finite 768-dimensional vectors."))
        proof.checks.append(.init(name: "bilingual-semantic-retrieval", passed: proof.queries.allSatisfy { $0.firstMailID == $0.expectedMailID && $0.cosine.isFinite && $0.cosine > 0 && !$0.method.isEmpty }, detail: "English and Chinese paraphrases ranked the synthetic delivery message first using semantic search."))
        proof.checks.append(.init(name: "distinct-nonliteral-queries", passed: Set(proof.queries.map(\.vectorHash)).count == queries.count && queries.allSatisfy { query in !fixtures.contains { $0.2.contains(query) } }, detail: "The fixture contains neither query verbatim; query vectors differ."))
        #endif
    }

    private func cloudBinding(id: UUID) async throws -> String {
        guard let identifier = CloudSyncService.configuredContainer() else { throw MailError.message("Acceptance build has no signed CloudKit container.") }
        let container = CKContainer(identifier: identifier)
        guard try await container.accountStatus() == .available else { throw MailError.message("Acceptance requires an available signed-in iCloud account on both devices.") }
        let account = try await container.userRecordID().recordName
        return MailStore.hash(id.uuidString.lowercased() + ":" + MailStore.hash(account))
    }

    private func cloudPhase(mode: AcceptanceMode, id: UUID, store: MailStore, cloud: CloudSyncService, proof: inout AcceptanceProof, destination: URL) async throws {
        let prefix = id.uuidString.lowercased() + "-"
        if mode == .cloudPublish { try await seedCloudFixture(store: store, prefix: prefix, revision: 1) }
        proof.phase = "starting-scoped-cksyncengine"; try Self.write(proof, to: destination)
        try await boundedCloud(cloud: cloud) { try await cloud.start() }
        if mode == .cloudUpdate {
            guard try await matchesFixture(store: store, prefix: prefix, revision: 1) else { throw MailError.message("Update requires the previously received publishing fixture.") }
            try await seedCloudFixture(store: store, prefix: prefix, revision: 2)
        } else if mode == .cloudDelete {
            guard try await matchesFixture(store: store, prefix: prefix, revision: 2) else { throw MailError.message("Deletion requires the bidirectionally updated synthetic fixture.") }
            for (kind, suffix) in [("agent-memory", "memory"), ("chat-session", "session"), ("chat", "chat")] { try await store.remove(kind: kind, id: prefix + suffix) }
        }
        proof.phase = "waiting-for-cloud-roundtrip"; try Self.write(proof, to: destination)
        var matched = false
        for attempt in 0..<12 {
            try Task.checkCancellation()
            try await boundedCloud(cloud: cloud) { try await cloud.sync() }
            let pending = try await store.cloudChanges().count; proof.pendingRecords = pending
            proof.importedRevision = await cloud.status().importedRevision
            switch mode {
            case .cloudPublish, .cloudReceive: matched = try await matchesFixture(store: store, prefix: prefix, revision: 1) && pending == 0
            case .cloudUpdate, .cloudVerifyUpdate: matched = try await matchesFixture(store: store, prefix: prefix, revision: 2) && pending == 0
            case .cloudDelete, .cloudVerifyDelete: matched = try await matchesDeletion(store: store, prefix: prefix) && pending == 0
            case .gemma: break
            }
            try Self.write(proof, to: destination)
            if matched { break }
            if attempt < 11 { try await Task.sleep(for: .seconds(3)) }
        }
        guard matched else { throw MailError.message("Synthetic CloudKit roundtrip did not reach the expected revision within the bounded acceptance window.") }
        proof.checks.append(.init(name: "cksyncengine-roundtrip", passed: true, detail: "Expected synthetic revision reached; all test journal records acknowledged."))
        let changes = try await store.cloudChanges(dirtyOnly: false)
        let cloudRecords = changes.filter { $0.objectID.hasPrefix(prefix) }
        proof.checks.append(.init(name: "only-synthetic-cloud-identities", passed: cloudRecords.count == 3 && changes.allSatisfy { $0.objectID.hasPrefix(prefix) }, detail: "Exactly three synthetic records in the acceptance zone."))
        let callback = try await store.object(OpenUIInteraction.self, kind: "openui-interaction", id: prefix + "callback")
        let publisherSide = mode == .cloudPublish || mode == .cloudDelete || mode == .cloudVerifyUpdate
        proof.checks.append(.init(name: "pending-callback-never-synchronized", passed: !changes.contains { $0.kind == "openui-interaction" } && (publisherSide ? callback != nil && callback?.completedAt == nil : callback == nil), detail: "Synthetic OpenUI callback remains local and unexecuted; no callback cloud journal record exists."))
        if mode == .cloudDelete || mode == .cloudVerifyDelete {
            proof.checks.append(.init(name: "durable-tombstones", passed: cloudRecords.allSatisfy { $0.payload == nil && !$0.dirty }, detail: "Three tombstones acknowledged; local synthetic objects removed."))
        } else {
            let memory = try await store.object(AgentMemory.self, kind: "agent-memory", id: prefix + "memory")
            // The local publishing copy may retain vectors; cloud payloads and received copies must not.
            let encodedMemory = cloudRecords.first { $0.kind == "agent-memory" }?.payload
            let prepared = try encodedMemory.map { try JSONDecoder().decode(AgentMemory.self, from: CloudWorkspacePolicy.preparedPayload($0, kind: "agent-memory")) }
            let receiverSide = mode == .cloudReceive || mode == .cloudVerifyUpdate
            proof.checks.append(.init(name: "memory-vectors-remain-local", passed: prepared?.embedding == nil && prepared?.embeddingModel == nil && (!receiverSide || memory?.embedding == nil), detail: "Cloud memory payload excludes local embedding vectors."))
            let session = try await store.object(ChatSession.self, kind: "chat-session", id: prefix + "session")
            let assetPath = session?.materials.first?.path ?? ""
            let assetBytes = try? Data(contentsOf: URL(fileURLWithPath: assetPath))
            let revision = mode == .cloudPublish || mode == .cloudReceive ? 1 : 2
            proof.checks.append(.init(name: "synthetic-asset-byte-equality", passed: assetPath.hasPrefix(store.root.path + "/") && assetBytes == Self.asset(prefix: prefix, revision: revision), detail: "Chat material bytes match the known synthetic fixture in the isolated workspace."))
            let acknowledged = try await cloudRecords.asyncAll { change in try await store.object(Data.self, kind: "cloud-record-state", id: change.id) != nil }
            proof.checks.append(.init(name: "server-record-metadata-persisted", passed: acknowledged, detail: "CKSyncEngine server record system fields persisted for all synthetic records."))
        }
        proof.phase = "restarting-persisted-sync-engine"; try Self.write(proof, to: destination)
        let prior = try await store.cloudChanges(dirtyOnly: false)
        await cloud.stop(); try await boundedCloud(cloud: cloud) { try await cloud.start() }
        let after = try await store.cloudChanges(dirtyOnly: false)
        proof.checks.append(.init(name: "restart-does-not-echo-or-resurrect", passed: FileManager.default.fileExists(atPath: store.root.appendingPathComponent("icloud-engine-state.json").path) && after.count == prior.count && after.allSatisfy { !$0.dirty } && after.map(\.clock) == prior.map(\.clock), detail: "Persisted engine restarted without resending unchanged objects or resurrecting tombstones."))
    }

    private func seedCloudFixture(store: MailStore, prefix: String, revision: Int) async throws {
        let data = Self.asset(prefix: prefix, revision: revision)
        let file = store.root.appendingPathComponent("synthetic-material-r\(revision).txt")
        try Self.privateWrite(data, to: file)
        var material = ChatMaterial(name: "synthetic-material.txt", mimeType: "text/plain", path: file.path, byteCount: data.count); material.id = prefix + "material-r\(revision)"
        var session = ChatSession(id: prefix + "session", title: "Morrow synthetic acceptance")
        session.input = "Synthetic unsent input revision \(revision)"; session.draftRevision = revision; session.materials = [material]
        try await store.save(session, kind: "chat-session", id: session.id)
        var memory = AgentMemory(content: "Morrow synthetic preference revision \(revision)", kind: .preference, scope: .session, scopeID: session.id)
        memory.id = prefix + "memory"; memory.confirmed = true; memory.source = "Synthetic acceptance fixture"; memory.embedding = [0.25, 0.75]; memory.embeddingModel = "synthetic-local-only"
        try await store.save(memory, kind: "agent-memory", id: memory.id)
        var chat = PartnerChat(role: "user", text: "Synthetic message revision \(revision)")
        chat.id = prefix + "chat"; chat.sessionID = session.id; chat.materials = []; chat.memoryIDs = [memory.id]
        try await store.save(chat, kind: "chat", id: chat.id)
        if revision == 1 {
            var callback = OpenUIInteraction(source: "root = Stack([TextContent(\"Synthetic pending callback\")])")
            callback.id = prefix + "callback"; callback.sessionID = session.id; callback.values = ["synthetic": .string("not executed")]
            try await store.save(callback, kind: "openui-interaction", id: callback.id)
        }
    }

    private static func asset(prefix: String, revision: Int) -> Data { Data("Morrow synthetic acceptance asset\n\(prefix)\nrevision=\(revision)\nNo private mail or credentials.\n".utf8) }

    private func matchesFixture(store: MailStore, prefix: String, revision: Int) async throws -> Bool {
        guard let memory = try await store.object(AgentMemory.self, kind: "agent-memory", id: prefix + "memory"), memory.content == "Morrow synthetic preference revision \(revision)",
              let session = try await store.object(ChatSession.self, kind: "chat-session", id: prefix + "session"), session.input == "Synthetic unsent input revision \(revision)", session.draftRevision == revision, session.materials.count == 1,
              let chat = try await store.object(PartnerChat.self, kind: "chat", id: prefix + "chat"), chat.text == "Synthetic message revision \(revision)" else { return false }
        let path = URL(fileURLWithPath: session.materials[0].path).resolvingSymlinksInPath()
        return path.path.hasPrefix(store.root.resolvingSymlinksInPath().path + "/") && (try? Data(contentsOf: path)) == Self.asset(prefix: prefix, revision: revision)
    }

    private func matchesDeletion(store: MailStore, prefix: String) async throws -> Bool {
        guard try await store.object(AgentMemory.self, kind: "agent-memory", id: prefix + "memory") == nil,
              try await store.object(ChatSession.self, kind: "chat-session", id: prefix + "session") == nil,
              try await store.object(PartnerChat.self, kind: "chat", id: prefix + "chat") == nil else { return false }
        let journal = try await store.cloudChanges(dirtyOnly: false)
        return journal.filter { $0.objectID.hasPrefix(prefix) && $0.payload == nil }.count == 3
    }

    private func boundedCloud(cloud: CloudSyncService, operation: @escaping @Sendable () async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(45)); await cloud.stop()
                throw MailError.message("CloudKit acceptance operation timed out after 45 seconds.")
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    private static func write(_ proof: AcceptanceProof, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try privateWrite(encoder.encode(proof), to: url)
    }
    private static func privateWrite(_ data: Data, to url: URL) throws { try data.write(to: url, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
}

private extension Array where Element: Sendable {
    func asyncAll(_ body: (Element) async throws -> Bool) async rethrows -> Bool { for element in self { if try await !body(element) { return false } }; return true }
}
