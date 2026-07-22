import XCTest

final class NoctweaveUITests_iOS: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["UI_TESTING"]
        app.launch()
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        app.terminate()
        super.tearDown()
    }

    func testPhoneShellRestoresStableProductTabs() {
        XCTAssertTrue(app.staticTexts["Welcome to Noctyra"].waitForExistence(timeout: 5))
        for title in ["Chats", "Contacts", "Code", "Relays", "Identity", "Settings"] {
            XCTAssertTrue(app.buttons[title].exists, "Missing bottom navigation item: \(title)")
            assertFitsScreen(app.buttons[title])
        }
        XCTAssertFalse(app.staticTexts["Local Persona"].exists)
    }

    func testPairingUsesConsumerLanguage() {
        let button = app.buttons["Add Contact"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()

        XCTAssertTrue(app.navigationBars["Add Contact"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Share Invitation"].exists)
        XCTAssertTrue(app.buttons["Enter Invitation"].exists)
        XCTAssertTrue(app.buttons["Create One-Use Invitation"].exists)
        XCTAssertFalse(app.staticTexts["Relationship-local presentation"].exists)
    }

    func testPrimaryTabsOpenExpectedDestinations() {
        app.buttons["Contacts"].tap()
        XCTAssertTrue(app.staticTexts["People you trust"].waitForExistence(timeout: 3))

        app.buttons["Relays"].tap()
        XCTAssertTrue(app.staticTexts["Preferred Relay"].waitForExistence(timeout: 3))

        app.buttons["Identity"].tap()
        XCTAssertTrue(app.staticTexts["Identity Book"].waitForExistence(timeout: 3))

        app.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["App Security"].waitForExistence(timeout: 3))
    }

    func testShellFitsPortraitAndLandscape() {
        let chats = app.buttons["Chats"]
        XCTAssertTrue(chats.waitForExistence(timeout: 5))
        assertFitsScreen(chats)

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(chats.waitForExistence(timeout: 3))
        assertFitsScreen(chats)
        assertFitsScreen(app.buttons["Settings"])
    }

    private func assertFitsScreen(
        _ element: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let screen = app.frame
        let frame = element.frame
        XCTAssertGreaterThanOrEqual(frame.minX, screen.minX - 1, file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxX, screen.maxX + 1, file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minY, screen.minY - 1, file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxY, screen.maxY + 1, file: file, line: line)
    }
}
