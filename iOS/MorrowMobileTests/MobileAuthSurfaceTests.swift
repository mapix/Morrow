import XCTest

final class MobileAuthSurfaceTests: XCTestCase {
    let app = XCUIApplication()
    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchArguments = ["--demo", "--ui-qa"]
        app.launch()
        XCTAssertTrue(app.buttons["settings.open"].waitForExistence(timeout: 20))
        app.buttons["settings.open"].tap()
    }
    func testGmailConnectionUsesGoogleFlowWithoutPasswordForm() {
        let connect = app.buttons["mailbox.gmail.connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 5)); connect.tap()
        XCTAssertTrue(app.buttons["mailbox.gmail.authorize"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.secureTextFields.count, 0)
        let capture = XCTAttachment(screenshot: app.screenshot()); capture.name = "native-gmail-connect-surface"; capture.lifetime = .keepAlways; add(capture)
    }
    func testChatGPTProviderShowsNativeContinueButton() {
        for _ in 0..<3 where !app.buttons["settings.provider"].isHittable { app.swipeUp() }
        let picker = app.buttons["settings.provider"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5)); picker.tap()
        app.buttons["ChatGPT"].tap()
        for _ in 0..<3 where !app.buttons["chatgpt.connect"].isHittable { app.swipeUp() }
        XCTAssertTrue(app.buttons["chatgpt.connect"].waitForExistence(timeout: 5))
        let capture = XCTAttachment(screenshot: app.screenshot()); capture.name = "native-chatgpt-connect-surface"; capture.lifetime = .keepAlways; add(capture)
    }
}
