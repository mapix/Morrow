import XCTest
import MLX
import Darwin
@testable import MorrowCore

final class EmbeddingNAXRegressionTests: XCTestCase {
    private func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.phys_footprint : 0
    }

    func testVariedHistoryKeepsMemoryBounded() async throws {
        try enableLiveMetal()
        let model = ProcessInfo.processInfo.environment["MORROW_MEMORY_MODEL"] ?? "/Applications/Morrow.app/Contents/Resources/embeddinggemma-2"
        let index = EmbeddingIndex()
        // Two simultaneous callers must not retain duplicate model loads.
        async let first: Void = index.load(directory: model)
        async let second: Void = index.load(directory: model)
        _ = try await (first, second)
        var maximumFootprint: UInt64 = 0
        let started = Date()
        for i in 0..<96 {
            let length = 32 + (i * 173) % 2200
            let text = String(repeating: i.isMultiple(of: 2) ? "delivery " : "会议 ", count: length)
            let vector = try await index.embed(text, query: i.isMultiple(of: 3))
            XCTAssertEqual(vector.count, 768)
            XCTAssertTrue(vector.allSatisfy(\.isFinite))
            let memory = await index.memoryDiagnostics()
            XCTAssertLessThanOrEqual(memory.cachedBytes, EmbeddingIndex.cacheBudget)
            XCTAssertLessThan(memory.activeBytes, EmbeddingIndex.workingBudget)
            maximumFootprint = max(maximumFootprint, footprint())
            // Fail while still far below the user's 40GB incident.
            XCTAssertLessThan(maximumFootprint, 3 * 1024 * 1024 * 1024)
            if maximumFootprint >= 3 * 1024 * 1024 * 1024 { break }
            if i.isMultiple(of: 16) { print("BOUNDED_HISTORY step=\(i) active=\(memory.activeBytes) cache=\(memory.cachedBytes) footprint=\(footprint())") }
        }
        let long = try await index.embed(String(repeating: "meeting delivery 项目 ", count: 2000))
        XCTAssertEqual(long.count, 768)
        let final = await index.memoryDiagnostics()
        XCTAssertLessThanOrEqual(final.maximumWindowTokens, EmbeddingIndex.maximumWindowTokens)
        XCTAssertGreaterThanOrEqual(final.completedEmbeddings, 96)
        print("BOUNDED_HISTORY_DONE embeddings=\(final.completedEmbeddings) maxFootprint=\(maximumFootprint) active=\(final.activeBytes) cache=\(final.cachedBytes) peakActive=\(final.peakActiveBytes) seconds=\(Date().timeIntervalSince(started))")
    }
    private func enableLiveMetal() throws {
        #if !os(macOS)
        throw XCTSkip("The NAX regression runs on an actual Mac Metal device.")
        #else
        guard ProcessInfo.processInfo.environment["MORROW_LIVE_NAX"] == "1",
              let shader = ProcessInfo.processInfo.environment["MORROW_TEST_METALLIB"] else {
            throw XCTSkip("Set MORROW_LIVE_NAX=1 and MORROW_TEST_METALLIB for the actual Metal regression.")
        }
        GPU.metallib = URL(fileURLWithPath: shader)
        #endif
    }

    func testBFloat16WideHeadMaskedAttention() throws {
        try enableLiveMetal()
        // qL=64 selects full attention, headDim=256 selects NAX dsplit on this
        // supported Mac, and the boolean mask matches the failing live kernel.
        let queries = MLXArray.zeros([1, 1, 64, 256], dtype: .bfloat16)
        let keys = MLXArray.zeros([1, 1, 64, 256], dtype: .bfloat16)
        let values = MLXArray.ones([1, 1, 64, 256], dtype: .bfloat16)
        let mask = MLXArray.ones([64, 64], dtype: .bool)
        let output = MLXFast.scaledDotProductAttention(
            queries: queries, keys: keys, values: values, scale: 1,
            mask: .array(mask), forceFused: true, stream: .gpu)
        try MLX.checkedEval(output)
        XCTAssertEqual(output.dtype, .bfloat16)
        XCTAssertEqual(output.shape, [1, 1, 64, 256])
        let result = output.asArray(Float.self)
        XCTAssertTrue(result.allSatisfy { $0.isFinite && abs($0 - 1) < 0.01 })
        print("NAX_BF16_REGRESSION: qL=64 headDim=256 mask=bool dtype=bfloat16 finite=true")
    }

    func testLongSyntheticMailCompletesCurrentCheckpointIndex() async throws {
        try enableLiveMetal()
        let modelPath = ProcessInfo.processInfo.environment["MORROW_MEMORY_MODEL"]
            ?? "/Applications/Morrow.app/Contents/Resources/embeddinggemma-2"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("morrow-nax-mail-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MailStore(root: root)
        let index = EmbeddingIndex()
        try await index.load(directory: modelPath)

        let paragraph = "The project team reviewed delivery milestones, acceptance criteria and the documentation plan. Please confirm the next review date and retain the test results. 项目组正在核对交付标准、评审日期和测试记录。\n"
        let text = String(repeating: paragraph, count: 20)
        let mail = MailMessage(
            accountID: "synthetic-nax-regression",
            from: .init(name: "Synthetic Project Team", email: "team@example.invalid"),
            subject: "Synthetic delivery review", text: text)
        XCTAssertGreaterThan(EmbeddingIndex.chunks(text).count, 1)
        try await store.upsert(mail)
        let started = Date()
        let indexed = try await index.index(mail, store: store, attachments: false)
        XCTAssertTrue(indexed)
        let coverage = try await index.searchCoverage(store: store)
        XCTAssertEqual(coverage.modelIdentity, EmbeddingIndex.checkpoint)
        XCTAssertEqual(coverage.eligibleCount, 1)
        XCTAssertEqual(coverage.indexedCount, 1)
        XCTAssertTrue(coverage.isComplete)
        let unchanged = try await index.index(mail, store: store, attachments: false)
        XCTAssertFalse(unchanged)

        let vector = try await index.embed(String(text.prefix(1200)))
        XCTAssertEqual(vector.count, 768)
        XCTAssertTrue(vector.allSatisfy(\.isFinite))
        XCTAssertEqual(vector.reduce(Float(0)) { $0 + $1 * $1 }, 1, accuracy: 0.01)
        print("NAX_MAIL_REGRESSION: syntheticCharacters=\(text.count) chunks=\(EmbeddingIndex.chunks(text).count) indexed=1/1 dimension=\(vector.count) normalized=true seconds=\(Date().timeIntervalSince(started))")
    }
}
