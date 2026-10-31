import XCTest
@testable import MorrowCore

final class IndexMemoryPolicyTests: XCTestCase {
    func testChunkingPreservesGraphemeCoverageAndOverlapWithoutCharacterExpansion() {
        let text = String(repeating: "A邮件👨‍👩‍👧‍👦e\u{301}Z", count: 7)
        let characters = Array(text), size = 9, overlap = 3
        var expected: [String] = [], start = 0
        while start < characters.count {
            let end = min(characters.count, start + size); expected.append(String(characters[start..<end]))
            if end == characters.count { break }; start = end - overlap
        }
        XCTAssertEqual(EmbeddingIndex.chunks(text, size: size, overlap: overlap), expected)
        XCTAssertEqual(EmbeddingIndex.chunks(text, size: size, overlap: -1), [])
        XCTAssertEqual(EmbeddingIndex.chunks(text, size: 0, overlap: 0), [])
    }
    func testActualSystemPressurePausesRegardlessOfSmallProcessFootprint() {
        for pressure in [IndexSystemMemoryPressure.warning, .critical] {
            XCTAssertTrue(IndexMemoryPolicy.shouldPause(pressure: pressure, activeGPUBytes: 100, workingBudget: 1000, processFootprint: 100))
        }
    }
    func testNormalPressureDoesNotPauseMacAtHistoricalHeapSizeButGPUIsBounded() {
        XCTAssertFalse(IndexMemoryPolicy.shouldPause(pressure: .normal, activeGPUBytes: 600, workingBudget: 1000, processFootprint: 4 * 1024 * 1024 * 1024))
        XCTAssertTrue(IndexMemoryPolicy.shouldPause(pressure: .normal, activeGPUBytes: 1001, workingBudget: 1000, processFootprint: 100))
    }
    func testIOSRetainsExplicitProcessBudgetAndNormalEventCanResume() {
        XCTAssertTrue(IndexMemoryPolicy.shouldPause(pressure: .normal, activeGPUBytes: 500, workingBudget: 1000, processFootprint: 1500, processBudget: 1500))
        XCTAssertFalse(IndexMemoryPolicy.shouldPause(pressure: .normal, activeGPUBytes: 500, workingBudget: 1000, processFootprint: 1499, processBudget: 1500))
    }
}
