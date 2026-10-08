import XCTest

final class QuickAskUITests: XCTestCase {
    @MainActor
    func testGuideDemoPreservesPauseAndManualProvenance() {
        let application = XCUIApplication()
        application.launchArguments = ["--clicky-ui-test", "--clicky-guide-demo"]
        application.launch()
        XCTAssertTrue(application.staticTexts["Guide demo · no AI"].waitForExistence(timeout: 5))
        XCTAssertTrue(application.staticTexts["Open the example panel."].exists)
        application.buttons["Next"].click()
        XCTAssertTrue(application.staticTexts["Enter 12 in the example field, then press Return."].waitForExistence(timeout: 5))
        application.buttons["Pause"].click()
        XCTAssertTrue(application.buttons["Resume"].waitForExistence(timeout: 5))
        application.buttons["Resume"].click()
        application.buttons["Next"].click()
        application.buttons["Next"].click()
        XCTAssertTrue(application.staticTexts["Demo finished manually · no verification"].waitForExistence(timeout: 5))
        XCTAssertFalse(application.buttons["Next"].exists)
    }
    @MainActor
    private func launchPreview() -> XCUIApplication {
        let application = XCUIApplication()
        application.launchArguments = ["--clicky-ui-test"]
        application.launch()
        XCTAssertTrue(application.textViews["quickAskEditor"].waitForExistence(timeout: 5))
        return application
    }

    @MainActor
    func testEnterSubmitsTypedPreview() {
        let application = launchPreview()
        let editor = application.textViews["quickAskEditor"]
        editor.click()
        editor.typeText("Explain this function")
        editor.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(application.staticTexts["Preview complete · no AI request"].waitForExistence(timeout: 5))
        let response = application.staticTexts["quickAskResponse"]
        XCTAssertTrue(response.waitForExistence(timeout: 5))
        XCTAssertTrue(response.label.contains("Explain this function") || (response.value as? String ?? "").contains("Explain this function"))
    }

    @MainActor
    func testShiftEnterPreservesMultilinePrompt() {
        let application = launchPreview()
        let editor = application.textViews["quickAskEditor"]
        editor.click()
        editor.typeText("first line")
        editor.typeKey(.return, modifierFlags: .shift)
        editor.typeText("second line")
        XCTAssertEqual(editor.value as? String, "first line\nsecond line")
        XCTAssertFalse(application.staticTexts["Preview complete · no AI request"].exists)
        application.buttons["quickAskSend"].click()
        XCTAssertTrue(application.staticTexts["Preview complete · no AI request"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testBlankPromptCannotSubmit() {
        let application = launchPreview()
        XCTAssertFalse(application.buttons["quickAskSend"].isEnabled)
        let editor = application.textViews["quickAskEditor"]
        editor.click()
        editor.typeText("   ")
        XCTAssertFalse(application.buttons["quickAskSend"].isEnabled)
    }

    @MainActor
    func testEscapeDismissesWithoutSending() {
        let application = launchPreview()
        let editor = application.textViews["quickAskEditor"]
        editor.click()
        editor.typeText("Do not submit")
        editor.typeKey(.escape, modifierFlags: [])
        let dismissed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: editor)
        wait(for: [dismissed], timeout: 5)
    }
}
