import XCTest
@testable import MorrowCore

final class BoundedFileReaderTests: XCTestCase {
    func testExactLimitAndRejectOversizedFileOrDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bounded-file-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("fixture.bin")
        let bytes = Data(repeating: 23, count: 4096); try bytes.write(to: file)
        XCTAssertEqual(try BoundedFileReader.read(file, maximumBytes: 4096), bytes)
        XCTAssertThrowsError(try BoundedFileReader.read(file, maximumBytes: 4095))
        XCTAssertThrowsError(try BoundedFileReader.read(root, maximumBytes: 4096))
    }
}
