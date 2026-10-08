import XCTest

final class QuickAskUITests: XCTestCase {
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
        XCTAssertTrue(application.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Explain this function")).firstMatch.exists)
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
