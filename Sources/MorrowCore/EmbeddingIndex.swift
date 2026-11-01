import Foundation
import MLX
import MLXEmbedders
import MLXLMCommon
import Tokenizers
import PDFKit
import Darwin

private struct LocalTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer { TokenizerBridge(try await AutoTokenizer.from(modelFolder: directory)) }
}
private struct TokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer
    init(_ upstream: any Tokenizers.Tokenizer) { self.upstream = upstream }
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { upstream.encode(text: text, addSpecialTokens: addSpecialTokens) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens) }
    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }; var eosToken: String? { upstream.eosToken }; var unknownToken: String? { upstream.unknownToken }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?, additionalContext: [String: any Sendable]?) throws -> [Int] { try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext) }
}

public enum MailSearchStrategy: String, Codable, CaseIterable, Sendable {
    case semantic, keyword, hybrid
}

public struct MailSearchCoverage: Sendable {
    public var eligibleCount: Int
    public var indexedCount: Int
    public var modelIdentity: String
    public var isLoaded: Bool
    public var isComplete: Bool { isLoaded && indexedCount == eligibleCount }
}

/// Numeric diagnostics only; never contains message text or identifiers.
public struct EmbeddingMemoryDiagnostics: Codable, Sendable {
    public var completedEmbeddings: Int
    public var maximumWindowTokens: Int
    public var activeBytes: Int
    public var cachedBytes: Int
    public var peakActiveBytes: Int
    public var cacheBudgetBytes: Int
    public var workingBudgetBytes: Int
    public var processFootprintBytes: UInt64
    public var systemMemoryPressure: IndexSystemMemoryPressure?
}

public actor EmbeddingIndex {
    public static let checkpoint = "mlx-community/embeddinggemma-2-bf16@1a4ffddb7905d3f63486748deabe091a01fb6201"
    private var container: EmbedderModelContainer?
    private var loadedPath: String = ""
    private var modelIdentity = EmbeddingIndex.checkpoint
    private var completedEmbeddings = 0
    private var maximumTokenCount = 0
    private var lastDiagnosticsWrite = Date.distantPast
    private var lastDiagnosticEmbeddingCount = -1
    private let loadingLock = EmbeddingLoadLock()
    // MLX defaults its recycling pool to a large fraction of physical RAM.
    // Mail history contains many tensor shapes, so that default retains tens
    // of GB on large Macs even though the text model is only about 542 MB.
    public static let cacheBudget = 64 * 1024 * 1024
    #if os(iOS)
    public static let workingBudget = 1024 * 1024 * 1024
    public static let processBudget: UInt64 = 1536 * 1024 * 1024
    #else
    public static let workingBudget = 2 * 1024 * 1024 * 1024
    public static let processBudget: UInt64 = 3 * 1024 * 1024 * 1024
    #endif
    public static let maximumWindowTokens = 1024
    private static func releaseCompletedBuffers() {
        // Metal completion handlers can return buffers to MLX after host
        // values are available. Drain the queue before purging that pool.
        Stream.gpu.synchronize()
        Memory.clearCache()
    }
    private static func processFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.phys_footprint : 0
    }
    public init() { _ = IndexMemoryPressureMonitor.shared; if let shader = Bundle.main.url(forResource: "mlx", withExtension: "metallib") { GPU.metallib = shader } }
    private static func hasMemoryPressure() -> Bool {
        #if os(iOS)
        let processLimit: UInt64? = processBudget
        #else
        let processLimit: UInt64? = nil
        #endif
        return IndexMemoryPolicy.shouldPause(pressure: IndexMemoryPressureMonitor.shared.current, activeGPUBytes: Memory.activeMemory, workingBudget: workingBudget, processFootprint: processFootprint(), processBudget: processLimit)
    }
    public func load(directory: String) async throws {
        // Actor methods can reenter while the factory awaits model/tokenizer
        // loading. The mail and memory index must share one loaded model.
        await loadingLock.acquire()
        do { try await loadSerially(directory: directory); await loadingLock.release() }
        catch { await loadingLock.release(); throw error }
    }
    private func loadSerially(directory: String) async throws {
        #if targetEnvironment(simulator)
        // MLX0.33 requires shared Metal heaps and a hardware architecture name,
        // neither provided by MTLSimDevice. Avoid upstream fatal assertions.
        throw MailError.message("MLX Metal 后端尚不支持 iOS 模拟器。请在真机使用 EmbeddingGemma 2；模拟器可以选择关键词检索。")
        #else
        if container != nil, directory == loadedPath { return }
        let url = URL(fileURLWithPath: directory)
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("model.safetensors").path) else { throw MailError.message("EmbeddingGemma 2 模型尚未安装，请在设置中选择模型文件夹。") }
        let configData = try Data(contentsOf: url.appendingPathComponent("config.json"))
        let config = try JSONSerialization.jsonObject(with: configData) as? [String: Any]
        guard ["embedding_gemma2", "embedding_gemma2_text"].contains(config?["model_type"] as? String ?? "") else { throw MailError.message("所选目录不是 EmbeddingGemma 2 模型。") }
        let identity: String
        if let manifestData = try? Data(contentsOf: url.appendingPathComponent("smail-manifest.json")),
           let manifest = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
           manifest["repo"] as? String == "mlx-community/embeddinggemma-2-bf16", manifest["revision"] as? String == "1a4ffddb7905d3f63486748deabe091a01fb6201" {
            identity = Self.checkpoint
        } else {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.appendingPathComponent("model.safetensors").path)
            identity = "embeddinggemma-2-local:" + MailStore.hash(directory + configData.base64EncodedString() + String(describing: attributes[.size]) + String(describing: attributes[.modificationDate]))
        }
        Memory.cacheLimit = Self.cacheBudget
        // This is MLX's allocation/scheduling threshold, not a process RSS cap.
        Memory.memoryLimit = Self.workingBudget
        Memory.clearCache()
        // Exclude media encoders to keep the mail text index resident and bounded.
        var resolved = ResolvedModelConfiguration(directory: url); resolved.excludedComponents = [.vision, .audio]
        let context = try await EmbedderModelFactory.shared._load(configuration: resolved, tokenizerLoader: LocalTokenizerLoader())
        container = EmbedderModelContainer(context: context); loadedPath = directory; modelIdentity = identity
        #endif
    }
    public func embed(_ text: String, query: Bool = false) async throws -> [Float] {
        guard let container else { throw MailError.message("向量模型尚未加载。") }
        return try await embed(text, query: query, using: container)
    }
    private func embed(_ text: String, query: Bool = false, using container: EmbedderModelContainer) async throws -> [Float] {
        let prefixed = query ? "task: search result | query: " + text : "title: none | text: " + text
        try Task.checkCancellation()
        guard !Self.hasMemoryPressure() else {
            Memory.clearCache()
            throw MailError.message("本地向量引擎超过内存预算，已暂停索引。请稍后重试。")
        }
        // Return host floats before clearing the cache: all local MLXArrays
        // and autoreleased Metal objects must leave scope first.
        defer { Self.releaseCompletedBuffers() }
        let result = try await container.perform { context -> ([Float], Int, Int) in
            let tokens = context.tokenizer.encode(text: prefixed)
            let prefixTokens = context.tokenizer.encode(text: query ? "task: search result | query: " : "title: none | text: ")
            let windowSize = max(1, Self.maximumWindowTokens - prefixTokens.count)
            var sum: [Float] = []; var totalWeight: Float = 0; var windows = 0
            // Long queries/memories are covered in bounded windows instead of
            // constructing an 8192-token attention graph or truncating content.
            for start in stride(from: 0, to: tokens.count, by: windowSize) {
                try Task.checkCancellation()
                guard !Self.hasMemoryPressure() else {
                    Memory.clearCache()
                    throw MailError.message("本地索引已因内存压力暂停；邮件同步和浏览仍可使用。")
                }
                let end = min(tokens.count, start + windowSize)
                let window = (start == 0 ? [] : prefixTokens) + Array(tokens[start..<end])
                let floats: [Float] = try autoreleasepool {
                    let output = context.model(MLXArray(window)[.newAxis], positionIds: nil, tokenTypeIds: nil, attentionMask: nil)
                    let pooled = context.pooling(output, normalize: true)
                    try MLX.checkedEval(pooled)
                    return pooled.asArray(Float.self)
                }
                guard !floats.isEmpty, floats.allSatisfy(\.isFinite), sum.isEmpty || sum.count == floats.count else { throw MailError.message("向量模型返回了无效结果。") }
                if sum.isEmpty { sum = Array(repeating: 0, count: floats.count) }
                let weight = Float(end - start)
                for i in sum.indices { sum[i] += floats[i] * weight }
                totalWeight += weight; windows += 1
                Self.releaseCompletedBuffers()
            }
            guard totalWeight > 0 else { throw MailError.message("没有可索引的文字。") }
            let norm = sqrt(sum.reduce(Float(0)) { $0 + $1 * $1 })
            guard norm.isFinite, norm > 0 else { throw MailError.message("向量模型返回了无效结果。") }
            return (sum.map { $0 / norm }, min(tokens.count, Self.maximumWindowTokens), windows)
        }
        completedEmbeddings += result.2; maximumTokenCount = max(maximumTokenCount, result.1)
        return result.0
    }
    public func memoryDiagnostics() -> EmbeddingMemoryDiagnostics {
        EmbeddingMemoryDiagnostics(completedEmbeddings: completedEmbeddings, maximumWindowTokens: maximumTokenCount,
            activeBytes: container == nil ? 0 : Memory.activeMemory, cachedBytes: container == nil ? 0 : Memory.cacheMemory, peakActiveBytes: container == nil ? 0 : Memory.peakMemory,
            cacheBudgetBytes: Self.cacheBudget, workingBudgetBytes: Self.workingBudget, processFootprintBytes: Self.processFootprint(), systemMemoryPressure: IndexMemoryPressureMonitor.shared.current)
    }
    private func writeMemoryDiagnostics(to root: URL) {
        guard container != nil else { return }
        let now = Date()
        guard completedEmbeddings != lastDiagnosticEmbeddingCount || now.timeIntervalSince(lastDiagnosticsWrite) >= 1 else { return }
        guard let bytes = try? JSONEncoder().encode(memoryDiagnostics()) else { return }
        let url = root.appendingPathComponent("embedding-runtime.json")
        try? bytes.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        lastDiagnosticsWrite = now; lastDiagnosticEmbeddingCount = completedEmbeddings
    }
    public static func chunks(_ text: String, size: Int = 1200, overlap: Int = 150) -> [String] {
        guard !text.isEmpty, size > 0, overlap >= 0, size > overlap else { return [] }
        var out: [String] = [], start = text.startIndex
        // Walk grapheme boundaries without expanding the entire string into
        // an Array<Character>, which greatly amplifies large-body memory.
        while start < text.endIndex {
            let end = text.index(start, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            out.append(String(text[start..<end]))
            if end == text.endIndex { break }
            start = text.index(end, offsetBy: -overlap)
        }
        return out
    }
    public func pendingMessageIDs(_ summaries: [MailMessage], store: MailStore, attachments: Bool) async throws -> [String] {
        let verified = try await store.verifiedIndexInputs(model: modelIdentity, ids: Set(summaries.map(\.id)))
        var pending: [String] = []
        for mail in summaries {
            try Task.checkCancellation()
            if let key = MailIndexInput.key(for: mail, attachments: attachments), verified[mail.id] == key { continue }
            pending.append(mail.id)
        }
        return pending
    }
    public func index(_ message: MailMessage, store: MailStore, attachments: Bool) async throws -> Bool {
        guard message.contentAvailability == nil || message.contentAvailability == .complete else { throw MailError.message("索引需要完整邮件正文，请先读取邮件。") }
        defer { writeMemoryDiagnostics(to: store.root) }
        var text = "主题：\(message.subject)\n发件人：\(message.from.display) <\(message.from.email)>\n日期：\(message.date.ISO8601Format())\n\(message.text)"
        if !message.note.isEmpty { text += "\n用户笔记：\n" + message.note }
        if !message.labels.isEmpty { text += "\n用户标签：" + message.labels.joined(separator: ", ") }
        var descriptor = MailEvidence.version + ":windows-v1-1024:" + text + ":attachments=" + String(attachments)
        if attachments { descriptor += ":extractor=" + AttachmentTextExtractor.version }
        if attachments {
            for a in message.attachments {
                // Retain the digest, never every attachment's bytes at once.
                let digest: String?
                if max(a.byteCount, a.data.count) > 32 * 1024 * 1024 { digest = nil }
                else if let revision = a.contentRevision { digest = revision }
                else { digest = (try? await store.attachmentData(a, maximumBytes: 32 * 1024 * 1024)).map(MailStore.hash) }
                descriptor += "\n" + a.name + ":" + a.mimeType + ":" + (digest ?? "unavailable:\(a.byteCount)")
            }
        }
        let hash = MailStore.hash(descriptor)
        guard let activeContainer = container else { throw MailError.message("向量模型尚未加载。") }
        let identity = modelIdentity
        if try await store.isIndexed(message.id, hash: hash, model: identity) {
            try await store.rememberIndexInput(message, attachments: attachments, model: identity, hash: hash); return false
        }
        if try await store.reuseVectors(canonical: message.canonicalID, targetID: message.id, model: identity, hash: hash) {
            try await store.rememberIndexInput(message, attachments: attachments, model: identity, hash: hash); return true
        }
        for attachment in (attachments ? message.attachments : []) {
            try Task.checkCancellation()
            let data = try? await store.attachmentData(attachment, maximumBytes: 32 * 1024 * 1024)
            text += "\n附件 \(attachment.name)：\n"
            if let data {
                let result = try await AttachmentTextExtractor.shared.extract(attachment, store: store, bytes: data)
                text += result.text.isEmpty ? (result.failure ?? "未找到可索引文字。") : result.text
                if result.truncated { text += "\n（附件文字提取达到限制，未覆盖完整附件）" }
            } else { text += "附件过大或本机文件不可用，尚未提取文字。" }
        }
        let chunks = Self.chunks(text); var vectors: [[Float]] = []
        for chunk in chunks { try Task.checkCancellation(); vectors.append(try await embed(chunk, using: activeContainer)) }
        try await store.putVectors(messageID: message.id, chunks: chunks, vectors: vectors, model: identity, hash: hash)
        try await store.rememberIndexInput(message, attachments: attachments, model: identity, hash: hash); return true
    }
    public func searchCoverage(store: MailStore, allowedIDs: Set<String>? = nil) async throws -> MailSearchCoverage {
        let identity = modelIdentity, isLoaded = container != nil
        let coverage = try await store.searchIndexCoverage(model: identity, allowedIDs: allowedIDs)
        return MailSearchCoverage(eligibleCount: coverage.eligibleCount, indexedCount: coverage.indexedCount, modelIdentity: identity, isLoaded: isLoaded)
    }
    public func search(_ query: String, store: MailStore, allowedIDs: Set<String>? = nil, strategy: MailSearchStrategy = .hybrid, limit: Int = 40, minimumSemanticScore: Float? = nil) async throws -> [SearchHit] {
        if allowedIDs?.isEmpty == true { return [] }
        let parsed = MailQuery(query)
        guard limit > 0, !parsed.text.isEmpty || parsed.hasFilters else { return [] }
        if strategy == .keyword || parsed.text.isEmpty { return try await store.keywordSearch(query, limit: limit, allowedIDs: allowedIDs) }
        guard let activeContainer = container else { throw MailError.message("语义向量模型尚未加载，未执行语义检索。") }
        let identity = modelIdentity
        let scopedIDs: Set<String>?
        if parsed.hasFilters {
            scopedIDs = Set(try await store.messageSummaries().filter { (allowedIDs?.contains($0.id) ?? true) && parsed.matches($0.displayMessage) }.map(\.id))
        } else { scopedIDs = allowedIDs }
        let coverage = try await store.searchIndexCoverage(model: identity, allowedIDs: scopedIDs)
        guard coverage.eligibleCount > 0 else { return [] }
        if coverage.indexedCount == 0 {
            if strategy == .semantic { throw MailError.message("当前范围的\(coverage.eligibleCount)封邮件尚无当前模型的有效向量索引，未执行语义检索。请等待索引完成或选择关键词检索。") }
            return try await store.keywordSearch(query, limit: limit, allowedIDs: scopedIDs)
        }
        let vector = try await embed(parsed.text, query: true, using: activeContainer)
        let candidates = strategy == .semantic ? limit : max(limit, 60)
        let semantic = try await store.vectorSearch(vector, model: identity, limit: candidates, allowedIDs: scopedIDs, minimumScore: minimumSemanticScore)
        if strategy == .semantic { return semantic }
        let lexical = try await store.keywordSearch(query, limit: candidates, allowedIDs: scopedIDs)
        return Self.fusedResults(semantic: semantic, lexical: lexical, limit: limit)
    }
    static func fusedResults(semantic: [SearchHit], lexical: [SearchHit], limit: Int) -> [SearchHit] {
        // Reciprocal rank fusion avoids mixing incomparable cosine and lexical scales.
        var scores: [String: Float] = [:]; var messages: [String: MailMessage] = [:]; var snippets: [String: String] = [:]
        let semanticIDs = Set(semantic.map { $0.message.canonicalID }), lexicalIDs = Set(lexical.map { $0.message.canonicalID })
        for list in [semantic, lexical] {
            var seen = Set<String>()
            for (i, hit) in list.enumerated() {
                let canonical = hit.message.canonicalID
                if seen.insert(canonical).inserted { scores[canonical, default: 0] += 1 / Float(60 + i + 1) }
                if messages[canonical] == nil || hit.message.folder == "INBOX" { messages[canonical] = hit.message }
                if !hit.snippet.isEmpty && snippets[canonical] == nil { snippets[canonical] = hit.snippet }
            }
        }
        return scores.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            let firstDate = messages[$0.key]?.date ?? .distantPast, secondDate = messages[$1.key]?.date ?? .distantPast
            return firstDate == secondDate ? $0.key < $1.key : firstDate > secondDate
        }.prefix(max(0, limit)).compactMap { id, score in
            messages[id].map { message in
                let method = semanticIDs.contains(id) ? (lexicalIDs.contains(id) ? "语义与关键词" : "语义（EmbeddingGemma 2）") : "关键词"
                return SearchHit(message: message, score: score, method: method, snippet: snippets[id] ?? "")
            }
        }
    }
}

private actor EmbeddingLoadLock {
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func acquire() async {
        if !held { held = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        if waiters.isEmpty { held = false } else { waiters.removeFirst().resume() }
    }
}
