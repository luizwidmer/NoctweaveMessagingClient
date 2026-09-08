import XCTest

final class NoctweaveUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "UI_TESTING",
            "UI_TESTING_READY_STATE",
            "UI_TESTING_RESET_STATE",
            "-ApplePersistenceIgnoreState",
            "YES",
            "-NSQuitAlwaysKeepsWindows",
            "NO"
        ]
        app.launch()
        app.activate()
        ensurePrimaryWindow()
    }

    override func tearDown() {
        app.terminate()
        super.tearDown()
    }

    func testMatureShellRestoresProductNavigation() {
        XCTAssertTrue(app.staticTexts["Noctweave"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Secure chat"].exists)
        XCTAssertTrue(app.buttons["People"].exists)
        XCTAssertTrue(app.buttons["You"].exists)
        XCTAssertFalse(app.buttons["Identity Management"].exists)
        XCTAssertFalse(app.staticTexts["Local organization only"].exists)
    }

    func testTopHeaderIsInsetInsteadOfRenderingAsAFullWidthSlab() {
        let header = app.descendants(matching: .any)
            .matching(identifier: "navigation.header")
            .firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 5))

        let window = app.windows.firstMatch
        XCTAssertTrue(window.exists)
        XCTAssertLessThanOrEqual(header.frame.maxX, window.frame.maxX - 8)
    }

    func testDeliveryReceiptsDoNotReplaceTheMessagePreviewOrCreateBubbles() {
        app.terminate()
        app.launchArguments += ["UI_TESTING_PRODUCT_FIXTURE"]
        app.launch()
        app.activate()
        ensurePrimaryWindow()

        let conversation = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Fixture message")).firstMatch
        XCTAssertTrue(conversation.waitForExistence(timeout: 5))
        conversation.tap()
        let message = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@", "Fixture message", "Fixture message"
        )).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@", "Secure message", "Secure message"
        )).firstMatch.exists)
        XCTAssertTrue(app.buttons["Check for Messages"].exists)
        attachScreenshot(named: "macOS Conversation Receipts Hidden")
    }

    func testEncryptedReadyStateSurvivesSignedRelaunch() {
        XCTAssertTrue(app.staticTexts["Noctweave"].waitForExistence(timeout: 5))
        app.terminate()

        app = XCUIApplication()
        app.launchArguments = [
            "UI_TESTING",
            "UI_TESTING_READY_STATE",
            "-ApplePersistenceIgnoreState",
            "YES",
            "-NSQuitAlwaysKeepsWindows",
            "NO"
        ]
        app.launch()
        app.activate()
        ensurePrimaryWindow()

        XCTAssertTrue(app.staticTexts["Noctweave"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["State integrity check stopped startup"].exists)
        XCTAssertFalse(app.buttons["boot.resetLocalData"].exists)
    }

    func testPairingKeepsTheCommonInviteFlowSimple() {
        let button = app.buttons["Add Contact"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()

        XCTAssertTrue(app.descendants(matching: .any)["pairing.name.toggle"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["pairing.relay.settings"].exists)
        XCTAssertTrue(app.buttons["Create Invitation"].exists)
        XCTAssertFalse(app.buttons["pairing.mode.relay"].exists)
        XCTAssertFalse(app.buttons["pairing.mode.direct"].exists)
        XCTAssertFalse(app.buttons["pairing.lobby.visible"].exists)
        XCTAssertFalse(app.buttons["pairing.method.qr"].exists)

        pairingDirection(named: "Join").tap()
        XCTAssertTrue(app.buttons["pairing.method.qr"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["pairing.method.file"].exists)
        XCTAssertTrue(app.buttons["pairing.method.link"].exists)
        XCTAssertFalse(app.buttons["pairing.method.nearby"].exists)

        let advanced = app.buttons["pairing.advanced.disclosure"]
        XCTAssertTrue(revealHittableByScrolling(advanced))
        advanced.tap()
        XCTAssertTrue(app.buttons["pairing.mode.relay"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["pairing.mode.direct"].exists)

        let lobby = app.buttons["pairing.lobby.disclosure"]
        XCTAssertTrue(revealHittableByScrolling(lobby))
        lobby.tap()
        XCTAssertTrue(revealByScrolling(app.buttons["pairing.lobby.visible"]))
        XCTAssertTrue(app.buttons["pairing.lobby.find"].exists)
        XCTAssertFalse(app.staticTexts["Relationship-local presentation"].exists)
        XCTAssertFalse(app.staticTexts["Temporary rendezvous relay"].exists)
    }

    func testLibraryDestinationsOpenFromSidebar() {
        app.buttons["You"].tap()
        app.buttons["you.relays"].tap()
        XCTAssertTrue(app.staticTexts["Choose a relay"].waitForExistence(timeout: 3))
        app.buttons["Back"].tap()

        app.buttons["you.persona"].tap()
        XCTAssertTrue(app.staticTexts["Identity Book"].waitForExistence(timeout: 3))
        app.buttons["Back"].tap()

        app.buttons["you.settings"].tap()
        XCTAssertTrue(app.buttons["settings.appSecurity"].waitForExistence(timeout: 3))
    }

    func testSettingsRowsNavigateAndAppSecuritySetupOpens() {
        app.buttons["You"].tap()
        app.buttons["you.settings"].tap()

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

    func testSecurityKeyProtectionRequiresVerifiedRegistration() {
        app.buttons["You"].tap()
        app.buttons["you.settings"].tap()
        app.buttons["settings.appSecurity"].tap()
        app.buttons["settings.appSecurity.configure"].tap()
        let method = app.buttons["appLock.method.securityKey"]
        XCTAssertTrue(method.waitForExistence(timeout: 3))
        method.tap()
        XCTAssertTrue(app.staticTexts["Your security keys"].waitForExistence(timeout: 3))
        let save = app.buttons["Save Protection"]
        XCTAssertTrue(save.exists)
        XCTAssertFalse(save.isEnabled, "A key method must not be enabled before registration and proof of possession")
        XCTAssertTrue(app.secureTextFields["securityKey.pin"].exists)
        XCTAssertTrue(app.switches["securityKey.keepConnected"].exists || app.checkBoxes["securityKey.keepConnected"].exists)
        attachScreenshot(named: "macOS Security Key Setup")
        for (mode, button) in [("securityKeyAndPin", "Continue to PIN"),
                               ("biometricsAndSecurityKey", "Save Protection"),
                               ("biometricsPinAndSecurityKey", "Continue to PIN")] {
            let choice = app.buttons["appLock.method.\(mode)"]
            XCTAssertTrue(choice.exists)
            if choice.isEnabled {
                choice.tap()
                XCTAssertFalse(app.buttons[button].isEnabled, "Every key combination requires a verified key")
            }
        }
        attachScreenshot(named: "macOS Combined Key Protection")
        app.buttons["Close"].tap()
        app.buttons["settings.appSecurity.configure"].tap()
        XCTAssertTrue(app.buttons["appLock.method.off"].waitForExistence(timeout: 3))
        attachScreenshot(named: "macOS Security Key Setup Cancelled")
    }

    func testFreshInstallCannotBypassLegalOrPersonaOnboarding() {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = [
            "UI_TESTING",
            "UI_TESTING_RESET_STATE",
            "-ApplePersistenceIgnoreState",
            "YES"
        ]
        app.launch()
        app.activate()
        ensurePrimaryWindow()

        XCTAssertTrue(app.staticTexts["Welcome to Noctweave"].waitForExistence(timeout: 5))
        assertOnboardingIsHorizontallyCentered()
        XCTAssertEqual(app.buttons.matching(identifier: "window.close").count, 1)
        XCTAssertEqual(app.buttons.matching(identifier: "window.minimize").count, 1)
        XCTAssertEqual(app.buttons.matching(identifier: "window.zoom").count, 1)
        let legalContinue = app.buttons["onboarding.legal.continue"]
        XCTAssertTrue(legalContinue.exists)
        XCTAssertFalse(legalContinue.isEnabled)

        acceptanceControl("onboarding.acceptPrivacy").tap()
        acceptanceControl("onboarding.acceptTerms").tap()
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
        let window = app.windows.firstMatch
        XCTAssertTrue(window.exists, file: file, line: line)
        XCTAssertEqual(container.frame.midX, window.frame.midX, accuracy: 2, file: file, line: line)
    }

    private func ensurePrimaryWindow() {
        guard !app.windows.firstMatch.waitForExistence(timeout: 1) else { return }
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 3))
    }

    private func revealByScrolling(_ element: XCUIElement, attempts: Int = 4) -> Bool {
        if element.exists { return true }
        for _ in 0..<attempts {
            swipeUpInCurrentSurface()
            if element.waitForExistence(timeout: 0.5) { return true }
        }
        return false
    }

    private func revealHittableByScrolling(_ element: XCUIElement, attempts: Int = 4) -> Bool {
        if element.exists, element.isHittable { return true }
        for _ in 0..<attempts {
            swipeUpInCurrentSurface()
            if element.waitForExistence(timeout: 0.5), element.isHittable { return true }
        }
        return false
    }

    private func swipeUpInCurrentSurface() {
        let sheetScrollView = app.sheets.firstMatch.scrollViews.firstMatch
        if sheetScrollView.exists {
            sheetScrollView.swipeUp()
        } else {
            app.swipeUp()
        }
    }

    private func pairingDirection(named name: String) -> XCUIElement {
        let radioButton = app.radioButtons[name]
        return radioButton.exists ? radioButton : app.buttons[name]
    }

    private func waitUntilEnabled(_ element: XCUIElement, timeout: TimeInterval = 2) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func acceptanceControl(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: identifier)
            .firstMatch
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
