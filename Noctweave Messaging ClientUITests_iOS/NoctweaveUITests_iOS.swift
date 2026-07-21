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

    func testCleanV1ShellUsesLocalPersonaBoundary() {
        XCTAssertTrue(app.staticTexts["Local Persona"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["0 relationships · 0 groups"].exists)
        XCTAssertTrue(app.buttons["New Relationship"].exists)
        XCTAssertFalse(app.staticTexts["Inbox"].exists)
        assertFitsScreen(app.buttons["New Relationship"])
    }

    func testPairingSheetUsesOneUseRendezvous() {
        let button = app.buttons["New Relationship"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()

        XCTAssertTrue(app.staticTexts["Relationship-local presentation"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Create Invitation"].exists)
        XCTAssertTrue(app.buttons["Accept Invitation"].exists)
        XCTAssertTrue(app.buttons["Create One-Use Invitation"].exists)
        XCTAssertFalse(app.staticTexts["Linked Devices"].exists)
    }

    func testCompactShellFitsPortraitAndLandscape() {
        let relationshipButton = app.buttons["New Relationship"]
        XCTAssertTrue(relationshipButton.waitForExistence(timeout: 5))
        assertFitsScreen(relationshipButton)

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(relationshipButton.waitForExistence(timeout: 3))
        assertFitsScreen(relationshipButton)
    }

    private func assertFitsScreen(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let screen = app.frame
        let frame = element.frame
        XCTAssertGreaterThanOrEqual(frame.minX, screen.minX - 1, file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxX, screen.maxX + 1, file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minY, screen.minY - 1, file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxY, screen.maxY + 1, file: file, line: line)
    }
}
