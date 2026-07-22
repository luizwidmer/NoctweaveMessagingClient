import XCTest

final class NoctweaveUITests: XCTestCase {
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

    func testMatureShellRestoresProductNavigation() {
        XCTAssertTrue(app.staticTexts["Noctyra"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Post-quantum chat"].exists)
        XCTAssertTrue(app.buttons["Contact Book"].exists)
        XCTAssertTrue(app.buttons["My Code"].exists)
        XCTAssertTrue(app.buttons["Files"].exists)
        XCTAssertTrue(app.buttons["Relays"].exists)
        XCTAssertTrue(app.buttons["Identity Management"].exists)
        XCTAssertTrue(app.buttons["Settings"].exists)
        XCTAssertFalse(app.staticTexts["Local organization only"].exists)
    }

    func testPairingUsesConsumerLanguageAndHidesProtocolFields() {
        let button = app.buttons["Add Contact"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()

        XCTAssertTrue(app.navigationBars["Add Contact"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Share Invitation"].exists)
        XCTAssertTrue(app.buttons["Enter Invitation"].exists)
        XCTAssertTrue(app.buttons["Create One-Use Invitation"].exists)
        XCTAssertFalse(app.staticTexts["Relationship-local presentation"].exists)
        XCTAssertFalse(app.staticTexts["Temporary rendezvous relay"].exists)
    }

    func testLibraryDestinationsOpenFromSidebar() {
        app.buttons["Relays"].tap()
        XCTAssertTrue(app.staticTexts["Preferred Relay"].waitForExistence(timeout: 3))

        app.buttons["Identity Management"].tap()
        XCTAssertTrue(app.staticTexts["Identity Book"].waitForExistence(timeout: 3))

        app.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["App Security"].waitForExistence(timeout: 3))
    }
}
