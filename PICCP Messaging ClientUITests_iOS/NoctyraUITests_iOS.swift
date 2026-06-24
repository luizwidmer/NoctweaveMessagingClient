import XCTest

final class NoctyraUITests_iOS: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments.append("UI_TESTING")
        app.launch()
    }

    func testSecureTypingEnabledByDefault() {
        openSettings()
        openPrivacySettings()
        let element = findSecureTypingElement()
        XCTAssertTrue(element.waitForExistence(timeout: 2))
        assertToggleOn(element)
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
        let tab = app.buttons["tab-settings"]
        if tab.waitForExistence(timeout: 2) {
            tab.tap()
            return
        }
        let settingsButton = app.buttons["sidebar-settings"]
        if settingsButton.waitForExistence(timeout: 1) {
            settingsButton.tap()
            return
        }
        let back = app.navigationBars.buttons.firstMatch
        if back.exists {
            back.tap()
        }
        if settingsButton.waitForExistence(timeout: 1) {
            settingsButton.tap()
            return
        }
        let fallback = app.staticTexts["Settings"]
        XCTAssertTrue(fallback.waitForExistence(timeout: 1))
        fallback.tap()
    }

    private func openContact() {
        if app.buttons["reveal-toggle"].exists || app.staticTexts["Hidden message"].exists {
            return
        }
        let chats = app.buttons["tab-chats"]
        if chats.waitForExistence(timeout: 1) {
            chats.tap()
        }
        let chatButton = app.buttons["chat-00000000-0000-0000-0000-000000000001"]
        if chatButton.waitForExistence(timeout: 1) {
            chatButton.tap()
            return
        }
        let contactButton = app.buttons["contact-00000000-0000-0000-0000-000000000001"]
        if contactButton.waitForExistence(timeout: 1) {
            contactButton.tap()
            return
        }
        let back = app.navigationBars.buttons.firstMatch
        if back.exists {
            back.tap()
        }
        if contactButton.waitForExistence(timeout: 1) {
            contactButton.tap()
            return
        }
        let fallback = app.staticTexts["UITest Contact"]
        XCTAssertTrue(fallback.waitForExistence(timeout: 1))
        fallback.tap()
    }

    private func openPrivacySettings() {
        let identified = app.buttons["settings-destination-privacy"]
        if identified.waitForExistence(timeout: 2) {
            identified.tap()
            return
        }
        let button = app.buttons["Privacy"]
        if button.waitForExistence(timeout: 2) {
            button.tap()
            return
        }
        let text = app.staticTexts["Privacy"]
        XCTAssertTrue(text.waitForExistence(timeout: 2))
        text.tap()
    }

    private func assertToggleOn(_ element: XCUIElement) {
        let value = element.value as? String
        if value == "1" || value == "true" || value == "On" {
            return
        }
        if let numeric = element.value as? Int, numeric == 1 {
            return
        }
        XCTAssertTrue(element.isSelected)
    }

    private func findSecureTypingElement() -> XCUIElement {
        for _ in 0..<3 {
            let candidates = [
                app.switches["secure-typing-toggle"],
                app.checkBoxes["secure-typing-toggle"],
                app.cells["secure-typing-toggle"],
                app.otherElements["secure-typing-toggle"]
            ]
            for element in candidates where element.exists {
                return element
            }
            scrollSettings()
        }
        return app.otherElements["secure-typing-toggle"]
    }

    private func scrollSettings() {
        if app.tables.firstMatch.exists {
            app.tables.firstMatch.swipeUp()
        } else if app.scrollViews.firstMatch.exists {
            app.scrollViews.firstMatch.swipeUp()
        } else {
            app.swipeUp()
        }
    }
}
