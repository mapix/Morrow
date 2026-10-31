import XCTest
import MLX
@testable import MorrowCore

final class LiveMemoryIndexTests: XCTestCase {
    func testActualEmbeddingGemmaMemoryVectors() async throws {
        guard ProcessInfo.processInfo.environment["MORROW_LIVE_MEMORY"] == "1" else { throw XCTSkip("Set MORROW_LIVE_MEMORY for actual memory vector inference") }
        if let shader = ProcessInfo.processInfo.environment["MORROW_TEST_METALLIB"] { GPU.metallib = URL(fileURLWithPath:shader) }
        let path = ProcessInfo.processInfo.environment["MORROW_MEMORY_MODEL"] ?? "/Applications/Morrow.app/Contents/Resources/embeddinggemma-2"
        let index = EmbeddingIndex(); try await index.load(directory:path)
        var contract = AgentMemory(content:"林舟负责协议中的验收工作，正在与合作方核对交付标准和服务费用。")
        contract.embedding = try await index.embed(contract.content)
        var other = AgentMemory(content:"每周阅读产品设计和新闻订阅，整理文章摘要。")
        other.embedding = try await index.embed(other.content)
        let vector = try await index.embed("合同交付条款要找谁跟进",query:true)
        XCTAssertEqual(vector.count,768); XCTAssertEqual(contract.embedding?.count,768)
        let hits = MemoryRanking.search([other,contract],query:"合同交付条款要找谁跟进",vector:vector,sessionID:nil,contactEmail:nil)
        print("MEMORY_VECTOR_TOP: " + (hits.first?.memory.content ?? "none")); XCTAssertEqual(hits.first?.id,contract.id)
    }
}
