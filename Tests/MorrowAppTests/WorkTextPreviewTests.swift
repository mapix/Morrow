import XCTest
@testable import MorrowApp

final class WorkTextPreviewTests: XCTestCase {
    func testIndexExcerptUsesFirstParagraphWithoutMarkdownSyntaxAndKeepsSource() {
        let source = "## 核对结果\r\n\r\n范围已**核对**，请查看[原邮件](https://example.invalid/source)。\r\n\r\n后续段落保持在原件。"
        XCTAssertEqual(WorkTextPreview.text(source, role: .brief), "范围已核对，请查看原邮件。")
        XCTAssertTrue(source.contains("**核对**")); XCTAssertTrue(source.contains("后续段落"))
        XCTAssertEqual(WorkTextPreview.text("范围已*核对*，状态__已确认__，_说明_保留。", role: .brief), "范围已核对，状态已确认，说明保留。")
        let literal = "计算 2*3、2**3 与 2 * 3；文件 *.pdf、**/*.png、*report*.pdf 和 file_name；代码 `*args*`。"
        XCTAssertEqual(WorkTextPreview.text(literal, role: .artifact), literal.replacingOccurrences(of: "`", with: ""))
    }
    func testExcerptSkipsFencedCodeAndTableAlignmentRows() {
        let source = "# 标题\n```swift\nsecretFixtureCode()\n```\n\n| 项目 | 现状 |\n| --- | --- |\n| 交付 | 已核对 |"
        XCTAssertEqual(WorkTextPreview.text(source, role: .artifact), "项目 / 现状 交付 / 已核对")
    }
    func testUnicodeExcerptIsBoundedAndTrailingUninspectedContentDoesNotLeak() {
        let glyph = "🧑🏽‍💻"
        let prefix = String(repeating: glyph, count: WorkTextPreview.maximumSourceCharacters)
        let a = WorkTextPreview.text(prefix + "tail-A", role: .brief, limit: 300)
        let b = WorkTextPreview.text(prefix + "tail-B", role: .brief, limit: 300)
        XCTAssertEqual(a, b); XCTAssertEqual(a.count, 300); XCTAssertTrue(a.hasSuffix("…"))
        XCTAssertFalse(a.contains("tail")); XCTAssertEqual(String(a.dropLast()), String(repeating: glyph, count: 299))
    }
    func testHeadingOnlyContentStillHasAUsefulBoundedLabel() {
        XCTAssertEqual(WorkTextPreview.text("# **标题**\n\n---", role: .brief), "标题")
    }
}
