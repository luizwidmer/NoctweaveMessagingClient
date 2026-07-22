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
        XCTAssertTrue(app.staticTexts["Welcome to Noctweave"].waitForExistence(timeout: 5))
        for title in ["Chats", "Contacts", "Code", "Relays", "Identity", "Settings"] {
            XCTAssertTrue(app.buttons[title].exists, "Missing bottom navigation item: \(title)")
            assertFitsScreen(app.buttons[title])
        }
        XCTAssertFalse(app.staticTexts["Local Persona"].exists)
    }

    func testPairingOffersOfflineHandoffMethods() {
        let button = app.buttons["Add Contact"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()

        XCTAssertTrue(app.buttons["pairing.method.qr"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["pairing.method.nearby"].exists)
        XCTAssertTrue(app.buttons["pairing.method.file"].exists)
        XCTAssertTrue(app.staticTexts["AirDrop or Share"].exists)
        XCTAssertTrue(app.staticTexts["Protected File"].exists)

        let remoteLink = app.buttons["pairing.method.link"]
        if !remoteLink.exists { app.swipeUp() }
        XCTAssertTrue(remoteLink.waitForExistence(timeout: 2))

        app.swipeDown()
        app.swipeDown()
        let receive = app.buttons["Receive Invitation"]
        XCTAssertTrue(receive.waitForExistence(timeout: 2))
        receive.tap()

        XCTAssertTrue(app.staticTexts["Scan QR"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Open Protected File"].exists)
        XCTAssertTrue(app.staticTexts["Paste Link"].exists)
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
