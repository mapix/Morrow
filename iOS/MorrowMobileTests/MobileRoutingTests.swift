import XCTest

final class MobileRoutingTests: XCTestCase {
    let app = XCUIApplication()
    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchArguments = ["--demo", "--ui-qa", "--agent-qa"]
        app.launch(); XCTAssertTrue(app.buttons["partner.open"].waitForExistence(timeout: 20))
    }
    func ask(_ instruction: String) {
        app.buttons["partner.open"].tap()
        let input = app.textFields["chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap(); input.typeText(instruction)
        app.buttons["chat.submit"].tap()
    }
    func capture(_ name: String) { let value = XCTAttachment(screenshot: app.screenshot()); value.name = name; value.lifetime = .keepAlways; add(value) }
    func testAgentSelectActuallyOpensOtherMailboxMailAndKeepsCapturedScope() {
        ask("NATIVE_ROUTE_MAIL: Open my booking email, then report the captured mailbox count.")
        let subject = app.staticTexts["mail.subject"]
        XCTAssertTrue(subject.waitForExistence(timeout: 12)); XCTAssertEqual(subject.label, "你的入住安排")
        XCTAssertTrue(app.tabBars.buttons["邮件"].isSelected)
        app.buttons["partner.open"].tap()
        XCTAssertTrue(app.staticTexts["Route kept captured mailbox count 4."].waitForExistence(timeout: 12))
        XCTAssertEqual(app.staticTexts["chat.scope"].label, "你的入住安排")
        capture("native-mail-route-and-origin-scope")
    }
    func testAgentSelectContactActuallyOpensProfile() {
        ask("NATIVE_ROUTE_CONTACT: Open Lin's contact profile and report the captured count.")
        XCTAssertTrue(app.staticTexts["contact.email"].waitForExistence(timeout: 12)); XCTAssertEqual(app.staticTexts["contact.email"].label, "lin@example.com")
        XCTAssertTrue(app.tabBars.buttons["联系人"].isSelected)
        capture("native-agent-contact-route")
    }
    func testAgentSelectAttachmentUsesActualListedID() {
        ask("NATIVE_ROUTE_ATTACHMENT: Find the delivery attachment and open it.")
        XCTAssertTrue(app.staticTexts["attachment.title"].waitForExistence(timeout: 12)); XCTAssertEqual(app.staticTexts["attachment.title"].label, "交付清单.md")
        XCTAssertTrue(app.tabBars.buttons["附件"].isSelected)
        capture("native-agent-attachment-route")
    }
    func testAgentNavigateActuallyOpensNativeSettings() {
        ask("NATIVE_ROUTE_SETTINGS: Open settings.")
        XCTAssertTrue(app.otherElements["settings.language"].waitForExistence(timeout: 10) || app.buttons["settings.language"].exists)
        XCTAssertTrue(app.navigationBars["设置"].exists)
    }
    func testComposerCloseRestoresVisibleMailContext() {
        app.tabBars.buttons["邮件"].tap(); app.staticTexts["请确认周五发布前的接口材料"].tap(); app.buttons["mail.reply"].tap()
        XCTAssertTrue(app.textViews["draft.body"].waitForExistence(timeout: 5)); app.buttons["取消"].tap()
        XCTAssertTrue(app.buttons["mail.reply"].waitForExistence(timeout: 5)); app.buttons["partner.open"].tap()
        XCTAssertTrue(app.staticTexts["chat.scope"].waitForExistence(timeout: 5)); XCTAssertEqual(app.staticTexts["chat.scope"].label, "请确认周五发布前的接口材料")
        capture("native-composer-context-restored")
    }
}
