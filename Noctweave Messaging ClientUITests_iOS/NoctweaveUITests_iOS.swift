import XCTest

final class NoctweaveUITests_iOS: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "UI_TESTING",
            "UI_TESTING_READY_STATE",
            "UI_TESTING_RESET_STATE"
        ]
        app.launch()
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        app.terminate()
        super.tearDown()
    }

    func testPhoneShellRestoresStableProductTabs() {
        XCTAssertTrue(app.staticTexts["Welcome to Noctweave"].waitForExistence(timeout: 5))
        let welcomeRegion = app.otherElements["chats.emptyWelcomeRegion"]
        let welcomeCard = app.otherElements["chats.emptyWelcomeCard"]
        XCTAssertTrue(welcomeRegion.exists)
        XCTAssertTrue(welcomeCard.exists)
        XCTAssertEqual(welcomeCard.frame.midX, welcomeRegion.frame.midX, accuracy: 2)
        XCTAssertEqual(welcomeCard.frame.midY, welcomeRegion.frame.midY, accuracy: 2)
        for title in ["Chats", "People", "You"] {
            XCTAssertTrue(app.buttons[title].exists, "Missing bottom navigation item: \(title)")
            assertFitsScreen(app.buttons[title])
        }
        let files = app.buttons["chats.files"]
        XCTAssertTrue(files.exists)
        assertFitsScreen(files)
        files.tap()
        XCTAssertTrue(app.staticTexts["Media and documents shared in chats"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts["Local Persona"].exists)
    }

    func testSecureRenderingExposesOneInteractiveTabSet() {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = ["UI_TESTING", "UI_TESTING_READY_STATE", "SECURE_RENDERING_TEST"]
        app.launch()

        let chats = app.buttons["tab.chats"]
        XCTAssertTrue(chats.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "tab.chats").count, 1)
        XCTAssertEqual(app.buttons.matching(identifier: "tab.people").count, 1)
        XCTAssertEqual(app.buttons.matching(identifier: "tab.you").count, 1)
        XCTAssertEqual(app.buttons.matching(identifier: "chats.files").count, 1)
        XCTAssertEqual(app.buttons.matching(identifier: "tab.files").count, 0)
        XCTAssertEqual(app.buttons.matching(identifier: "tab.relays").count, 0)
        XCTAssertEqual(app.buttons.matching(identifier: "tab.identity").count, 0)
        XCTAssertEqual(app.buttons.matching(identifier: "tab.settings").count, 0)
        XCTAssertTrue(chats.isHittable)
        assertFitsScreen(chats)
        XCTAssertFalse(app.staticTexts["Screenshot detected"].isHittable)
    }

    func testPairingOffersOfflineHandoffMethods() {
        let button = app.buttons["Add Contact"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()

        XCTAssertTrue(app.buttons["pairing.lobby.visible"].exists)
        XCTAssertTrue(app.buttons["pairing.lobby.find"].exists)
        XCTAssertTrue(revealByScrolling(app.buttons["pairing.method.qr"]))
        XCTAssertTrue(revealByScrolling(app.buttons["pairing.method.nearby"]))
        XCTAssertTrue(revealByScrolling(app.buttons["pairing.method.file"]))
        XCTAssertTrue(revealByScrolling(app.staticTexts["AirDrop or Share"]))
        XCTAssertTrue(revealByScrolling(app.staticTexts["Protected File"]))

        let remoteLink = app.buttons["pairing.method.link"]
        XCTAssertTrue(revealByScrolling(remoteLink))

        app.swipeDown()
        app.swipeDown()
        let receive = app.buttons["I Have an Invitation"]
        XCTAssertTrue(receive.waitForExistence(timeout: 2))
        receive.tap()

        XCTAssertTrue(app.staticTexts["Scan QR"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Open Protected File"].exists)
        XCTAssertTrue(app.staticTexts["Paste Link"].exists)
        app.buttons["pairing.method.link"].tap()
        XCTAssertTrue(app.buttons["pairing.pasteAndPair"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts["Relationship-local presentation"].exists)
    }

    func testPrimaryTabsOpenExpectedDestinations() {
        app.buttons["People"].tap()
        XCTAssertTrue(app.staticTexts["Secure relationships and invitations"].waitForExistence(timeout: 3))

        app.buttons["You"].tap()
        app.buttons["you.relays"].tap()
        XCTAssertTrue(app.staticTexts["Choose a relay"].waitForExistence(timeout: 3))
        app.buttons["Back"].tap()

        app.buttons["you.persona"].tap()
        XCTAssertTrue(app.staticTexts["Identity Book"].waitForExistence(timeout: 3))
        app.buttons["Back"].tap()

        app.buttons["you.settings"].tap()
        XCTAssertTrue(app.staticTexts["App Security"].waitForExistence(timeout: 3))
    }

    private func revealByScrolling(_ element: XCUIElement, attempts: Int = 5) -> Bool {
        if element.exists { return true }
        for _ in 0..<attempts {
            app.swipeUp()
            if element.waitForExistence(timeout: 0.5) { return true }
        }
        return false
    }

    func testShellFitsPortraitAndLandscape() {
        let chats = app.buttons["Chats"]
        XCTAssertTrue(chats.waitForExistence(timeout: 5))
        assertFitsScreen(chats)

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(chats.waitForExistence(timeout: 3))
        assertFitsScreen(chats)
        assertFitsScreen(app.buttons["You"])
    }

    func testSettingsRowsNavigateAndAppSecuritySetupOpens() {
        app.buttons["You"].tap()
        app.buttons["you.settings"].tap()

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
        app.launchArguments = ["UI_TESTING", "UI_TESTING_RESET_STATE"]
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
