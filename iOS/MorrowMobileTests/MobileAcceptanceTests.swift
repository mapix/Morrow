import XCTest

final class MobileAcceptanceTests: XCTestCase {
    let app = XCUIApplication()
    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchArguments = ["--demo", "--session-scale", "--ui-qa", "--agent-qa"]
        app.launch()
        XCTAssertTrue(app.buttons["partner.open"].waitForExistence(timeout: 20))
    }
    func capture(_ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image)
    }
    func test01ReadToolsFeedSecondPlanningRound() {
        app.buttons["partner.open"].tap()
        let input = app.textFields["chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap(); input.typeText("NATIVE_QA_STATS: Count the whole mailbox.")
        app.buttons["chat.submit"].tap()
        XCTAssertTrue(app.staticTexts["Actual captured mailbox contains 4 messages."].waitForExistence(timeout: 15))
        capture("native-agent-tool-synthesis")
    }
    func test02UnsavedDraftIsVisibleAndUpdatedByChat() {
        XCTAssertTrue(app.tabBars.buttons["邮件"].waitForExistence(timeout: 5)); app.tabBars.buttons["邮件"].tap()
        app.staticTexts["请确认周五发布前的接口材料"].tap()
        app.buttons["mail.reply"].tap()
        let body = app.textViews["draft.body"]
        XCTAssertTrue(body.waitForExistence(timeout: 5)); body.tap(); body.typeText("UNSAVED_NATIVE_DRAFT")
        app.swipeUp()
        app.buttons["委托给 Morrow"].tap()
        let input = app.textFields["chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap(); input.typeText("NATIVE_QA_EDIT: Replace the marker in the current unsaved draft.")
        app.buttons["chat.submit"].tap()
        XCTAssertTrue(app.staticTexts["Native draft update completed."].waitForExistence(timeout: 15))
        app.buttons["完成"].tap()
        XCTAssertTrue(body.waitForExistence(timeout: 5)); XCTAssertTrue((body.value as? String ?? "").contains("AI_UPDATED_NATIVE_DRAFT"))
        capture("native-live-draft-ai-update")
    }
    func testMailReaderDraftAndUnread() {
        app.tabBars.buttons["邮件"].tap()
        let subject = app.staticTexts["请确认周五发布前的接口材料"]
        XCTAssertTrue(subject.waitForExistence(timeout: 5)); subject.tap()
        XCTAssertTrue(app.staticTexts["mail.subject"].waitForExistence(timeout: 5))
        if app.buttons["标记未读"].exists { app.buttons["标记未读"].tap() }
        XCTAssertTrue(app.staticTexts["未读"].waitForExistence(timeout: 5))
        app.buttons["标记已读"].tap()
        XCTAssertTrue(app.staticTexts["已读"].waitForExistence(timeout: 5))
        app.buttons["mail.reply"].tap()
        let body = app.textViews["draft.body"]
        XCTAssertTrue(body.waitForExistence(timeout: 5)); body.tap(); body.typeText("Reviewed in native iPhone draft.")
        app.buttons["draft.save"].tap()
        XCTAssertTrue(app.buttons["mail.reply"].waitForExistence(timeout: 5))
        capture("native-reader-read-state")
    }
    func testSessionScaleAndInputIsolation() {
        app.buttons["partner.open"].tap()
        XCTAssertTrue(app.textFields["chat.input"].waitForExistence(timeout: 5))
        app.buttons["对话"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("43")
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "QA Session 43")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
        let input = app.textFields["chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5)); XCTAssertEqual(input.value as? String, "Draft input 43")
        capture("native-session-scale-filter")
        input.tap(); input.typeText(" persisted marker")
        let expectedInput = input.value as? String ?? ""
        XCTAssertTrue(expectedInput.contains("persisted marker"))
        app.buttons["对话"].tap()
        app.buttons["创建对话"].tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5)); XCTAssertFalse((input.value as? String ?? "").contains("persisted marker"))
        app.buttons["对话"].tap()
        let repeated = app.searchFields.firstMatch; repeated.tap(); repeated.typeText("43")
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
        XCTAssertEqual(input.value as? String, expectedInput)
    }
}
