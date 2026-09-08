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
        if name.contains("testHidden") || name.contains("testDuress") {
            let all = name.contains("testHiddenAll") || name.contains("testDuress")
            let mode = all ? "biometricsPinAndSecurityKey" : name.contains("PINCan") ? "pinOnly" : "securityKeyAndPin"
            let hidden = all ? "biometrics,pin,securityKey" : name.contains("PINCan") ? "pin" : "securityKey"
            app.launchArguments += ["UI_TESTING_LOCK_FIXTURE", mode, "UI_TESTING_HIDDEN_UNLOCK_FACTORS", hidden]
            if name.contains("KeyAttachment") { app.launchArguments += ["UI_TESTING_ATTACHED_KEY_FIXTURE"] }
            if name.contains("testDuress") {
                app.launchArguments += ["UI_TESTING_PRODUCT_FIXTURE", "UI_TESTING_DURESS_FIXTURE",
                    name.contains("ReadOnly") ? "showChatsAndDestroyLocalKeys" : name.contains("Wipe") ? "wipeLocalData" : name.contains("DestroyKeys") ? "destroyLocalKeys" : "decoy"]
            }
        }
        if name.contains("testConfigureDuress") {
            app.launchArguments += ["UI_TESTING_LOCK_FIXTURE", "pinOnly"]
        }
        app.launch()
        app.activate()
        ensurePrimaryWindow()
    }

    func testHiddenKeyKeepsPINVisibleWithoutAllowingPINBypass() {
        XCTAssertTrue(app.staticTexts["Noctweave is locked"].waitForExistence(timeout: 10))
        let pin = app.secureTextFields["unlock.pin"]
        XCTAssertTrue(pin.exists)
        XCTAssertFalse(app.buttons["Verify Security Key"].exists)
        XCTAssertFalse(app.staticTexts["Every selected check is required"].exists)
        pin.tap(); pin.typeText("123456")
        app.buttons["unlock.submitPIN"].tap()
        XCTAssertTrue(app.staticTexts["Unable to unlock. Try again."].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Noctweave is locked"].exists)
        XCTAssertFalse(app.buttons["You"].exists)
        attachScreenshot(named: "macOS Hidden Key With Visible PIN")
    }

    func testHiddenAllMethodsKeepPINWithoutAdvertisingAdditionalChecks() {
        XCTAssertTrue(app.staticTexts["Noctweave is locked"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.secureTextFields["unlock.pin"].exists)
        XCTAssertFalse(app.buttons["Verify Biometrics"].exists)
        XCTAssertFalse(app.buttons["Verify Security Key"].exists)
        XCTAssertFalse(app.secureTextFields["securityKey.pin"].exists)
        XCTAssertFalse(app.buttons["unlock.options"].exists)
        XCTAssertFalse(app.staticTexts["Every selected check is required"].exists)
        attachScreenshot(named: "macOS Concealed Key And Biometrics")
    }

    func testHiddenPINCanNoLongerConcealTheOrdinaryPINField() {
        XCTAssertTrue(app.staticTexts["Noctweave is locked"].waitForExistence(timeout: 10))
        let pin = app.secureTextFields["unlock.pin"]
        XCTAssertTrue(pin.exists)
        XCTAssertFalse(app.buttons["unlock.options"].exists)
        pin.tap(); pin.typeText("123456")
        app.buttons["unlock.submitPIN"].tap()
        XCTAssertTrue(app.buttons["You"].waitForExistence(timeout: 8))
    }

    func testDuressDecoyRunsBeforeKeyAndBiometrics() {
        enterDuressPassword()
        XCTAssertTrue(app.staticTexts["No conversations yet"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Fixture message"].exists)
        XCTAssertFalse(app.buttons["Verify Security Key"].exists)
        XCTAssertFalse(app.buttons["You"].exists)
        attachScreenshot(named: "macOS Separate Local View")
    }

    func testDuressKeyAttachmentReplacesPINUntilCancelled() {
        XCTAssertTrue(app.secureTextFields["securityKey.pin"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.secureTextFields["unlock.pin"].exists)
        XCTAssertFalse(app.buttons["unlock.submitPIN"].exists)
        XCTAssertFalse(app.buttons["Verify Biometrics"].exists)
        XCTAssertFalse(app.buttons["You"].exists)
        attachScreenshot(named: "macOS Key Flow Without Waiting PIN")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.secureTextFields["unlock.pin"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.secureTextFields["securityKey.pin"].exists)
        enterDuressPassword()
        XCTAssertTrue(app.staticTexts["No conversations yet"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["You"].exists)
    }

    func testDuressReadOnlyChatsRunBeforeKeyAndBiometrics() {
        enterDuressPassword()
        XCTAssertTrue(app.staticTexts.matching(identifier: "Fixture message").firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["You"].exists)
        XCTAssertFalse(app.buttons["Send"].isEnabled)
        XCTAssertFalse(app.buttons["Verify Biometrics"].exists)
        attachScreenshot(named: "macOS Temporary Chat View")
    }

    func testConfigureDuressPasswordAndUseAfterRelaunch() {
        XCTAssertTrue(app.secureTextFields["unlock.pin"].waitForExistence(timeout: 10))
        app.secureTextFields["unlock.pin"].tap()
        app.secureTextFields["unlock.pin"].typeText("123456")
        app.buttons["unlock.submitPIN"].tap()
        XCTAssertTrue(app.buttons["You"].waitForExistence(timeout: 8))
        app.buttons["You"].tap()
        app.buttons["you.settings"].tap()
        app.buttons["settings.appSecurity"].tap()
        app.buttons["settings.appSecurity.configure"].tap()
        XCTAssertTrue(app.staticTexts["Confirm it is you"].waitForExistence(timeout: 3))
        enterSetupPIN()
        app.buttons["Continue"].tap()
        let label = app.textFields["duress.label"]
        XCTAssertTrue(revealInsideSetup(label, attempts: 12))
        label.tap(); for character in "Test" { label.typeText(String(character)) }
        let password = app.secureTextFields["duress.password"]
        XCTAssertTrue(revealInsideSetup(password))
        password.tap(); for character in "876543" { password.typeText(String(character)) }
        let confirmation = app.secureTextFields["duress.confirmation"]
        XCTAssertTrue(revealInsideSetup(confirmation))
        confirmation.tap(); for character in "876543" { confirmation.typeText(String(character)) }
        let add = app.buttons["duress.add"]
        XCTAssertTrue(revealInsideSetup(add))
        add.tap()
        XCTAssertTrue(app.staticTexts["Test"].waitForExistence(timeout: 5))
        attachScreenshot(named: "macOS Duress Plan Configuration")
        let next = app.buttons["Continue to PIN"]
        XCTAssertTrue(revealInsideSetup(next, attempts: 12))
        next.tap(); enterSetupPIN(); app.buttons["Continue"].tap()
        enterSetupPIN(); app.buttons["Save Protection"].tap()
        XCTAssertTrue(app.staticTexts["Control access to local conversations"].waitForExistence(timeout: 8))
        app.terminate()
        app.launchArguments.removeAll { $0 == "UI_TESTING_RESET_STATE" }
        app.launch(); app.activate(); ensurePrimaryWindow()
        XCTAssertTrue(app.secureTextFields["unlock.pin"].waitForExistence(timeout: 10))
        app.secureTextFields["unlock.pin"].tap()
        app.secureTextFields["unlock.pin"].typeText("876543")
        app.buttons["unlock.submitPIN"].tap()
        XCTAssertTrue(app.staticTexts["No conversations yet"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["You"].exists)
    }

    private func enterSetupPIN() {
        for digit in ["1", "2", "3", "4", "5", "6"] {
            let button = app.buttons[digit]
            XCTAssertTrue(revealInsideSetup(button))
            button.tap()
        }
    }

    private func revealInsideSetup(_ element: XCUIElement, attempts: Int = 12) -> Bool {
        let sheet = app.sheets.firstMatch
        let scroll = sheet.scrollViews.firstMatch
        for _ in 0..<attempts {
            if element.exists, scroll.exists {
                let visible = CGRect(x: sheet.frame.minX, y: sheet.frame.minY + 90,
                    width: sheet.frame.width, height: sheet.frame.height - 110)
                if element.isHittable, visible.contains(element.frame) { return true }
                scroll.scroll(byDeltaX: 0, deltaY: element.frame.midY > visible.midY ? -220 : 220)
            } else {
                scroll.scroll(byDeltaX: 0, deltaY: -220)
            }
        }
        return false
    }

    func testDuressWipeRunsBeforeKeyAndBiometrics() {
        enterDuressPassword()
        XCTAssertTrue(app.staticTexts["No conversations yet"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Fixture message"].exists)
        XCTAssertFalse(app.buttons["You"].exists)
    }

    func testDuressDestroyKeysRunsBeforeKeyAndBiometrics() {
        enterDuressPassword()
        XCTAssertTrue(app.staticTexts["No conversations yet"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Fixture message"].exists)
        XCTAssertFalse(app.buttons["You"].exists)
    }

    private func enterDuressPassword() {
        XCTAssertTrue(app.staticTexts["Noctweave is locked"].waitForExistence(timeout: 10))
        let pin = app.secureTextFields["unlock.pin"]
        pin.tap(); pin.typeText("654321")
        app.buttons["unlock.submitPIN"].tap()
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
