import XCTest
@testable import MorrowCore

final class BriefDocumentTests: XCTestCase {
    func testStructuredBriefValidatesAndSurvivesCloudPayload() throws {
        let data = Data(#"{"summary":"One renewal needs attention","status":"in_progress","coverage":"One provider checked","findings":["Annual renewal"],"actions":["Verify expiry"],"uncertainties":["Other providers pending"],"tables":[{"title":"Renewals","columns":["Domain","Expiry"],"rows":[["example.invalid","2026-11-04"]]}]}"#.utf8)
        let document = try JSONDecoder().decode(BriefDocument.self, from: data).validated()
        XCTAssertTrue(document.markdown.contains("| Domain | Expiry |")); XCTAssertTrue(document.markdown.contains("Other providers pending"))
        var artifact = AgentArtifact(runID: "sdk-chat:s", title: "Renewals", kind: .report, content: document.markdown)
        artifact.sessionID = "s"; artifact.sourceChatID = "human"; artifact.briefDocument = document
        let prepared = try CloudWorkspacePolicy.preparedPayload(JSONEncoder().encode(artifact), kind: "agent-artifact")
        let restored = try JSONDecoder().decode(AgentArtifact.self, from: prepared)
        XCTAssertEqual(restored.sessionID, "s"); XCTAssertEqual(restored.sourceChatID, "human"); XCTAssertEqual(restored.briefDocument?.tables.first?.rows.first?.first, "example.invalid")
        XCTAssertEqual(restored.briefDocument?.status, .inProgress)
        let editedProjection = BriefDocument.legacy(document.markdown, title: "Renewals")
        XCTAssertEqual(editedProjection.summary, document.summary); XCTAssertEqual(editedProjection.coverage, document.coverage)
        XCTAssertTrue(editedProjection.actions.joined().contains("Verify expiry"))
    }
    func testInvalidTableIsRejectedAndLegacyParagraphsAreRetained() throws {
        var document = BriefDocument(); document.summary = "Summary"; document.tables = [.init(title: "Invalid", columns: ["A", "B"], rows: [["one"]])]
        XCTAssertThrowsError(try document.validated())
        let original = "## Report\n\n未完成的工作记录：还没有检查全部邮件。\n\nObserved fact, exact original wording.\n\n后续：继续检查来源。"
        let legacy = BriefDocument.legacy(original, title: "Report")
        XCTAssertEqual(legacy.coverage, "未完成的工作记录：还没有检查全部邮件。"); XCTAssertEqual(legacy.findings, ["Observed fact, exact original wording."]); XCTAssertEqual(legacy.actions, ["后续：继续检查来源。"])
    }
}
