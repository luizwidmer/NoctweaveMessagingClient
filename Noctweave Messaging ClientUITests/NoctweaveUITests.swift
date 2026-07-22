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

    func testPairingSeparatesRelayAndDirectOfflineFlows() {
        let button = app.buttons["Add Contact"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()

        XCTAssertTrue(app.buttons["pairing.method.qr"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["pairing.method.nearby"].exists)
        XCTAssertTrue(app.buttons["pairing.method.file"].exists)
        XCTAssertTrue(app.buttons["pairing.method.link"].exists)

        app.buttons["Direct / Offline"].tap()
        app.scrollViews.firstMatch.swipeUp()
        XCTAssertTrue(app.buttons["Begin Direct Pairing"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["pairing.method.link"].exists)
        XCTAssertTrue(app.staticTexts["Pair directly between devices"].exists)
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

    func testSettingsRowsNavigateAndAppSecuritySetupOpens() {
        app.buttons["Settings"].tap()

        let appearance = app.buttons["settings.appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 3))
        attachScreenshot(named: "macOS Settings Root")
        appearance.tap()
        XCTAssertTrue(app.staticTexts["Choose a palette"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Make it yours"].exists)
        app.buttons["Back"].tap()

        app.buttons["settings.privacy"].tap()
        XCTAssertTrue(app.staticTexts["Local protections with clear limits"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Hide when unfocused"].exists)
        app.buttons["Back"].tap()

        app.buttons["settings.appSecurity"].tap()
        XCTAssertTrue(app.staticTexts["Control access to local conversations"].waitForExistence(timeout: 2))
        app.buttons["settings.appSecurity.configure"].tap()
        XCTAssertTrue(app.staticTexts["UNLOCK METHOD"].waitForExistence(timeout: 2))
        attachScreenshot(named: "macOS App Security Setup")
        app.buttons["Close"].tap()
        app.buttons["Back"].tap()

        app.buttons["settings.storage"].tap()
        XCTAssertTrue(app.staticTexts["Encrypted at rest"].waitForExistence(timeout: 2))
        app.buttons["Back"].tap()

        app.buttons["settings.legal"].tap()
        XCTAssertTrue(app.staticTexts["Privacy Policy"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Terms of Use"].exists)
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
