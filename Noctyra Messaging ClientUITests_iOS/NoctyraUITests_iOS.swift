import XCTest

final class NoctyraUITests_iOS: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["UI_TESTING"]
        app.launch()
    }

    override func tearDown() {
        app.terminate()
        super.tearDown()
    }

    func testCleanV1ShellUsesLocalPersonaBoundary() {
        XCTAssertTrue(app.staticTexts["Local Persona"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Local organization only"].exists)
        XCTAssertTrue(app.buttons["New Relationship"].exists)
        XCTAssertFalse(app.staticTexts["Inbox"].exists)
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
}
