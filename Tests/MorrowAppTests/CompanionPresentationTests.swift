import XCTest
import MorrowCore
@testable import MorrowApp

final class CompanionPresentationTests: XCTestCase {
    func testCollapsedChatConsumesNoPaneAndReopeningRestoresPreferredWidth() {
        let expanded = CompanionPaneLayout.resolve(available: 1230, preferredChat: 400, expanded: true)
        XCTAssertEqual(expanded.chat, 400)
        XCTAssertEqual(expanded.workspace + expanded.chat + CompanionPaneLayout.divider, 1230)
        let collapsed = CompanionPaneLayout.resolve(available: 1230, preferredChat: 400, expanded: false)
        XCTAssertEqual(collapsed.chat, 0)
        XCTAssertEqual(collapsed.workspace, 1230)
        XCTAssertEqual(CompanionPaneLayout.resolve(available: 1230, preferredChat: 400, expanded: true), expanded)
    }
    func testDraggingAndSmallWindowsRespectBothContentMinimums() {
        for preferred: CGFloat in [-100, 340, 400, 1000] {
            let layout = CompanionPaneLayout.resolve(available: 970, preferredChat: preferred, expanded: true)
            XCTAssertGreaterThanOrEqual(layout.workspace, 600)
            XCTAssertGreaterThanOrEqual(layout.chat, 340)
            XCTAssertLessThanOrEqual(layout.chat, 500)
            XCTAssertEqual(layout.workspace + layout.chat + 1, 970)
        }
        let measuredEarly = CompanionPaneLayout.resolve(available: 0, preferredChat: 400, expanded: true)
        XCTAssertEqual(measuredEarly.workspace, 600)
        XCTAssertEqual(measuredEarly.chat, 340)
    }
    func testCurrentAndOtherSessionActivityUsesActualSidebarTaskOwnership() {
        let current = CompanionActivity.resolve(activeSessionID: "first", executingSessionID: "first", sidebarRunning: true, executingRunIDs: [], runs: [])
        XCTAssertEqual(current?.kind, .currentConversation)
        XCTAssertEqual(current?.sessionID, "first")
        let other = CompanionActivity.resolve(activeSessionID: "second", executingSessionID: "first", sidebarRunning: true, executingRunIDs: [], runs: [])
        XCTAssertEqual(other?.kind, .otherConversation)
        XCTAssertEqual(other?.sessionID, "first")
        XCTAssertNil(CompanionActivity.resolve(activeSessionID: "second", executingSessionID: "first", sidebarRunning: false, executingRunIDs: [], runs: []))
    }
    func testSavedWorkingPhaseDoesNotPretendToRunWithoutHostExecutionID() {
        var stale = AgentRun(title: "Stale fixture", instruction: "", phase: .working); stale.id = "stale"
        var actual = AgentRun(title: "Running fixture", instruction: "", phase: .reading); actual.id = "actual"
        XCTAssertNil(CompanionActivity.resolve(activeSessionID: "session", executingSessionID: nil, sidebarRunning: false, executingRunIDs: [], runs: [stale]))
        let activity = CompanionActivity.resolve(activeSessionID: "session", executingSessionID: nil, sidebarRunning: false, executingRunIDs: ["actual"], runs: [stale, actual])
        XCTAssertEqual(activity?.kind, .work)
        XCTAssertEqual(activity?.runID, "actual")
        actual.phase = .paused
        XCTAssertNil(CompanionActivity.resolve(activeSessionID: "session", executingSessionID: nil, sidebarRunning: false, executingRunIDs: ["actual"], runs: [actual]))
    }
}
