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
        XCTAssertTrue(app.staticTexts["Noctweave"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Post-quantum chat"].exists)
        XCTAssertTrue(app.buttons["Contact Book"].exists)
        XCTAssertTrue(app.buttons["My Code"].exists)
        XCTAssertTrue(app.buttons["Files"].exists)
        XCTAssertTrue(app.buttons["Relays"].exists)
        XCTAssertTrue(app.buttons["Identity Management"].exists)
        XCTAssertTrue(app.buttons["Settings"].exists)
        XCTAssertFalse(app.staticTexts["Local organization only"].exists)
    }

    func testPairingOffersOfflineHandoffMethodsAndHidesProtocolFields() {
        let button = app.buttons["Add Contact"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()

        XCTAssertTrue(app.buttons["pairing.method.qr"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["pairing.method.nearby"].exists)
        XCTAssertTrue(app.buttons["pairing.method.file"].exists)
        XCTAssertTrue(app.buttons["pairing.method.link"].exists)
        XCTAssertTrue(app.staticTexts["AirDrop or Share"].exists)
        XCTAssertTrue(app.staticTexts["Protected File"].exists)
        XCTAssertTrue(app.buttons["Create One-Use Invitation"].exists)

        app.buttons["Receive Invitation"].tap()
        XCTAssertTrue(app.staticTexts["Scan QR"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Open Protected File"].exists)
        XCTAssertTrue(app.staticTexts["Paste Link"].exists)
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
