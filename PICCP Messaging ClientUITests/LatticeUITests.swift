import XCTest

final class LatticeUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.terminate()
        app.launchArguments.append("UI_TESTING")
        app.launch()
    }

    override func tearDown() {
        app.terminate()
        super.tearDown()
    }

    func testSecureTypingEnabledByDefault() {
        openSettings()
        let toggle = app.switches["secure-typing-toggle"]
        if toggle.waitForExistence(timeout: 2) {
            assertToggleOn(toggle)
            return
        }
        let checkbox = app.checkBoxes["secure-typing-toggle"]
        XCTAssertTrue(checkbox.waitForExistence(timeout: 2))
        assertToggleOn(checkbox)
    }

    func testRevealToggleShowsMessage() {
        openContact()
        XCTAssertTrue(app.staticTexts["Hidden message"].waitForExistence(timeout: 2))
        let revealButton = app.buttons["reveal-toggle"]
        XCTAssertTrue(revealButton.waitForExistence(timeout: 2))
        revealButton.tap()
        XCTAssertTrue(app.staticTexts["Secret message"].waitForExistence(timeout: 2))
    }

    func testRevealResetsWhenLeavingConversation() {
        openContact()
        let revealButton = app.buttons["reveal-toggle"]
        XCTAssertTrue(revealButton.waitForExistence(timeout: 2))
        revealButton.tap()
        XCTAssertTrue(app.staticTexts["Secret message"].waitForExistence(timeout: 2))
        openSettings()
        openContact()
        XCTAssertTrue(app.staticTexts["Hidden message"].waitForExistence(timeout: 2))
    }

    private func openSettings() {
        let settingsButton = app.buttons["sidebar-settings"]
        if settingsButton.waitForExistence(timeout: 1) {
            settingsButton.tap()
            return
        }
        let fallback = app.staticTexts["Settings"]
        XCTAssertTrue(fallback.waitForExistence(timeout: 1))
        fallback.tap()
    }

    private func openContact() {
        let contactButton = app.buttons["contact-00000000-0000-0000-0000-000000000001"]
        if contactButton.waitForExistence(timeout: 1) {
            contactButton.tap()
            return
        }
        let fallback = app.staticTexts["UITest Contact"]
        XCTAssertTrue(fallback.waitForExistence(timeout: 1))
        fallback.tap()
    }

    private func assertToggleOn(_ element: XCUIElement) {
        let value = element.value as? String
        if value == "1" || value == "true" {
            return
        }
        if let numeric = element.value as? Int, numeric == 1 {
            return
        }
        XCTAssertTrue(element.isSelected)
    }
}
