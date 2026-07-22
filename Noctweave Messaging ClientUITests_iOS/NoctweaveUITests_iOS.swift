import XCTest

final class NoctweaveUITests_iOS: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["UI_TESTING", "UI_TESTING_READY_STATE"]
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
        XCTAssertTrue(app.staticTexts["Choose a relay"].waitForExistence(timeout: 3))

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

    func testSettingsRowsNavigateAndAppSecuritySetupOpens() {
        app.buttons["Settings"].tap()

        let appearance = app.buttons["settings.appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 3))
        attachScreenshot(named: "iPhone Settings Root")
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
        attachScreenshot(named: "iPhone App Security Setup")
        app.buttons["Close"].tap()
        app.buttons["Back"].tap()

        app.buttons["settings.storage"].tap()
        XCTAssertTrue(app.staticTexts["Encrypted at rest"].waitForExistence(timeout: 2))
        app.buttons["Back"].tap()

        app.buttons["settings.legal"].tap()
        XCTAssertTrue(app.staticTexts["Privacy Policy"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Terms of Use"].exists)
    }

    func testFreshInstallCannotBypassLegalOrPersonaOnboarding() {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = ["UI_TESTING"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Welcome to Noctweave"].waitForExistence(timeout: 5))
        assertOnboardingIsHorizontallyCentered()
        let legalContinue = app.buttons["onboarding.legal.continue"]
        XCTAssertTrue(legalContinue.exists)
        XCTAssertFalse(legalContinue.isEnabled)

        app.switches["onboarding.acceptPrivacy"].tap()
        app.switches["onboarding.acceptTerms"].tap()
        XCTAssertTrue(waitUntilEnabled(legalContinue))
        legalContinue.tap()

        XCTAssertTrue(app.staticTexts["Create your first persona"].waitForExistence(timeout: 3))
        let personaName = app.textFields["onboarding.persona.name"]
        XCTAssertTrue(personaName.exists)
        XCTAssertFalse(app.buttons["onboarding.persona.continue"].isEnabled)
        personaName.tap()
        personaName.typeText("Fresh Test")
        XCTAssertTrue(app.buttons["onboarding.persona.continue"].isEnabled)
    }

    private func assertOnboardingIsHorizontallyCentered(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let container = app.otherElements["onboarding.container"]
        XCTAssertTrue(container.waitForExistence(timeout: 3), file: file, line: line)
        XCTAssertEqual(container.frame.midX, app.frame.midX, accuracy: 2, file: file, line: line)
    }

    private func waitUntilEnabled(_ element: XCUIElement, timeout: TimeInterval = 2) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
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
