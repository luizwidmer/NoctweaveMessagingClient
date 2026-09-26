import XCTest

final class NoctweaveUITests_iOS: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "UI_TESTING", "UI_TESTING_AUTOMATED_PROFILE",
            "UI_TESTING_READY_STATE",
            "UI_TESTING_RESET_STATE"
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
        if name.contains("testPINCooldown") {
            app.launchArguments += ["UI_TESTING_LOCK_FIXTURE", "pinOnly"]
        }
        app.launch()
    }

    func testPINCooldownSurvivesRelaunch() {
        let pin = app.secureTextFields["unlock.pin"]
        XCTAssertTrue(pin.waitForExistence(timeout: 10))
        for _ in 0..<5 {
            pin.tap(); pin.typeText("000000")
            app.buttons["unlock.submitPIN"].tap()
            XCTAssertTrue(app.staticTexts["Noctweave is locked"].exists)
        }
        app.terminate()
        app.launchArguments.removeAll { $0 == "UI_TESTING_RESET_STATE" }
        app.launch()
        let relaunchPIN = app.secureTextFields["unlock.pin"]
        XCTAssertTrue(relaunchPIN.waitForExistence(timeout: 10))
        relaunchPIN.tap(); relaunchPIN.typeText("123456")
        app.buttons["unlock.submitPIN"].tap()
        XCTAssertTrue(app.staticTexts["Noctweave is locked"].exists,
            "Restarting Noctweave must not clear the retry delay.")
        XCTAssertFalse(app.buttons["You"].exists)
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
        attachScreenshot(named: "iPhone Hidden Key With Visible PIN")
    }

    func testHiddenAllMethodsKeepPINWithoutAdvertisingAdditionalChecks() {
        XCTAssertTrue(app.staticTexts["Noctweave is locked"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.secureTextFields["unlock.pin"].exists)
        XCTAssertFalse(app.buttons["Verify Biometrics"].exists)
        XCTAssertFalse(app.buttons["Verify Security Key"].exists)
        XCTAssertFalse(app.secureTextFields["securityKey.pin"].exists)
        XCTAssertFalse(app.buttons["unlock.options"].exists)
        XCTAssertFalse(app.staticTexts["Every selected check is required"].exists)
        attachScreenshot(named: "iPhone Concealed Key And Biometrics")
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
        XCTAssertTrue(app.buttons["You"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts.matching(identifier: "Fixture message").firstMatch.exists)
        XCTAssertFalse(app.staticTexts["Unselected message"].exists)
        XCTAssertFalse(app.buttons["Verify Security Key"].exists)
        attachScreenshot(named: "Usable retained chats")
        relaunchAfterDuressAndUnlock()
        XCTAssertTrue(app.buttons["You"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.matching(identifier: "Fixture message").firstMatch.exists)
        XCTAssertFalse(app.staticTexts["Unselected message"].exists)
    }

    func testDuressKeyAttachmentReplacesPINUntilCancelled() {
        XCTAssertTrue(app.secureTextFields["securityKey.pin"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.secureTextFields["unlock.pin"].exists)
        XCTAssertFalse(app.buttons["unlock.submitPIN"].exists)
        XCTAssertFalse(app.buttons["Verify Biometrics"].exists)
        XCTAssertFalse(app.buttons["You"].exists)
        attachScreenshot(named: "iPhone Key Flow Without Waiting PIN")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.secureTextFields["unlock.pin"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.secureTextFields["securityKey.pin"].exists)
        enterDuressPassword()
        XCTAssertTrue(app.buttons["You"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts.matching(identifier: "Fixture message").firstMatch.exists)
    }

    func testDuressReadOnlyChatsRunBeforeKeyAndBiometrics() {
        enterDuressPassword()
        XCTAssertTrue(app.buttons["Send"].waitForExistence(timeout: 20))
        if app.buttons["Chats"].exists { app.buttons["Chats"].tap() }
        let chat = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Fixture local contact")).firstMatch
        if chat.exists { chat.tap() }
        XCTAssertTrue(app.staticTexts.matching(identifier: "Fixture message").firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["You"].exists)
        XCTAssertFalse(app.buttons["Send"].isEnabled)
        XCTAssertFalse(app.buttons["Verify Biometrics"].exists)
        attachScreenshot(named: "iPhone Temporary Chat View")
    }

    func testDuressWipeRunsBeforeKeyAndBiometrics() {
        enterDuressPassword()
        XCTAssertTrue(app.staticTexts["Finish your onboarding"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.staticTexts["Fixture message"].exists)
        XCTAssertFalse(app.buttons["You"].exists)
        attachScreenshot(named: "Finish onboarding after erase")
        app.buttons["onboarding.resume"].tap()
        XCTAssertTrue(app.buttons["onboarding.legal.continue"].waitForExistence(timeout: 5))
        relaunchAfterDuressAndUnlock()
        XCTAssertTrue(app.staticTexts["Finish your onboarding"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Fixture message"].exists)
        XCTAssertFalse(app.buttons["onboarding.lock.continue"].exists)
    }

    func testDuressDestroyKeysRunsBeforeKeyAndBiometrics() {
        enterDuressPassword()
        XCTAssertTrue(app.staticTexts["Finish your onboarding"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.staticTexts["Fixture message"].exists)
        XCTAssertFalse(app.buttons["You"].exists)
        attachScreenshot(named: "Finish onboarding after erase")
        app.buttons["onboarding.resume"].tap()
        XCTAssertTrue(app.buttons["onboarding.legal.continue"].waitForExistence(timeout: 5))
        relaunchAfterDuressAndUnlock()
        XCTAssertTrue(app.staticTexts["Finish your onboarding"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Fixture message"].exists)
        XCTAssertFalse(app.buttons["onboarding.lock.continue"].exists)
    }

    private func relaunchAfterDuressAndUnlock(password: String = "654321") {
        app.terminate()
        app.launchArguments.removeAll { $0 == "UI_TESTING_RESET_STATE" }
        app.launch()
        let input = app.secureTextFields["unlock.pin"]
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        XCTAssertEqual(input.placeholderValue, "PIN")
        input.tap(); input.typeText("123456")
        app.buttons["unlock.submitPIN"].tap()
        XCTAssertTrue(app.staticTexts["Unable to unlock. Try again."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Verify Security Key"].exists)
        XCTAssertFalse(app.buttons["Verify Biometrics"].exists)
        input.tap(); input.typeText(password)
        app.buttons["unlock.submitPIN"].tap()
    }

    private func enterDuressPassword() {
        XCTAssertTrue(app.staticTexts["Noctweave is locked"].waitForExistence(timeout: 10))
        let pin = app.secureTextFields["unlock.pin"]
        pin.tap(); pin.typeText("654321")
        app.buttons["unlock.submitPIN"].tap()
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        app.terminate()
        super.tearDown()
    }

    func testSecurityKeySetupFitsPhoneAndRequiresVerification() {
        app.buttons["You"].tap()
        app.buttons["you.settings"].tap()
        app.buttons["settings.appSecurity"].tap()
        app.buttons["settings.appSecurity.configure"].tap()
        let keyMethod = app.buttons["appLock.method.securityKey"]
        XCTAssertTrue(keyMethod.waitForExistence(timeout: 3))
        for _ in 0..<4 where !keyMethod.isHittable || keyMethod.frame.maxY > app.frame.maxY - 40 { app.swipeUp() }
        XCTAssertTrue(keyMethod.isHittable)
        assertFitsScreen(keyMethod)
        keyMethod.tap()
        let register = app.buttons["securityKey.submit"]
        for _ in 0..<6 where !register.isHittable || register.frame.maxY > app.frame.maxY - 40 { app.swipeUp() }
        XCTAssertTrue(register.isHittable)
        assertFitsScreen(register)
        XCTAssertFalse(app.secureTextFields["securityKey.pin"].exists,
                       "New iOS registrations collect the key PIN only in the system sheet")
        let localHint = app.staticTexts["securityKey.localFlow"]
        XCTAssertTrue(localHint.exists)
        assertFitsScreen(localHint)
        XCTAssertFalse(app.switches["securityKey.keepConnected"].exists,
                       "NFC and iOS must not advertise continuous USB presence")
        XCTAssertFalse(app.buttons["Save Protection"].isEnabled)
        attachScreenshot(named: "iPhone Security Key Setup")
        app.buttons["Close"].tap()
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

    func testTopHeaderIsInsetInsteadOfRenderingAsAFullWidthSlab() {
        let header = app.otherElements["navigation.header"]
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(header.frame.minX, app.frame.minX + 8)
        XCTAssertLessThanOrEqual(header.frame.maxX, app.frame.maxX - 8)
    }

    func testSecureRenderingExposesOneInteractiveTabSet() {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = ["UI_TESTING", "UI_TESTING_AUTOMATED_PROFILE", "UI_TESTING_READY_STATE", "SECURE_RENDERING_TEST"]
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

    func testPairingProgressivelyRevealsAlternateHandoffMethods() {
        let button = app.buttons["Add Contact"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()

        XCTAssertTrue(app.descendants(matching: .any)["pairing.name.toggle"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["pairing.relay.settings"].exists)
        XCTAssertTrue(app.buttons["Create Invitation"].exists)
        XCTAssertFalse(app.buttons["pairing.mode.relay"].exists)
        XCTAssertFalse(app.buttons["pairing.lobby.visible"].exists)
        XCTAssertFalse(app.buttons["pairing.method.qr"].exists)

        app.buttons["Join"].tap()
        XCTAssertTrue(app.buttons["pairing.method.qr"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["pairing.method.file"].exists)
        XCTAssertTrue(app.buttons["pairing.method.link"].exists)
        XCTAssertFalse(app.buttons["pairing.method.nearby"].exists)
        app.buttons["pairing.method.link"].tap()
        XCTAssertTrue(app.buttons["pairing.pasteAndPair"].waitForExistence(timeout: 2))

        let advanced = app.buttons["pairing.advanced.disclosure"]
        XCTAssertTrue(revealHittableByScrolling(advanced))
        advanced.tap()
        XCTAssertTrue(revealByScrolling(app.buttons["pairing.mode.relay"]))
        XCTAssertTrue(app.buttons["pairing.mode.direct"].exists)

        let lobby = app.buttons["pairing.lobby.disclosure"]
        XCTAssertTrue(revealHittableByScrolling(lobby))
        lobby.tap()
        XCTAssertTrue(revealByScrolling(app.buttons["pairing.lobby.visible"]))
        XCTAssertTrue(app.buttons["pairing.lobby.find"].exists)
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
            swipeUpInCurrentSurface()
            if element.waitForExistence(timeout: 0.5) { return true }
        }
        return false
    }

    private func revealHittableByScrolling(_ element: XCUIElement, attempts: Int = 5) -> Bool {
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
        app.launchArguments = ["UI_TESTING", "UI_TESTING_AUTOMATED_PROFILE", "UI_TESTING_RESET_STATE"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Welcome to Noctweave"].waitForExistence(timeout: 5))
        assertOnboardingIsHorizontallyCentered()
        XCTAssertFalse(app.buttons["onboarding.legal.continue"].exists)
        app.buttons["onboarding.lock.method.off"].tap()
        let securityContinue = app.buttons["onboarding.lock.continue"]
        for _ in 0..<8 where !securityContinue.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(securityContinue.isHittable)
        attachScreenshot(named: "Security first onboarding")
        securityContinue.tap()
        XCTAssertTrue(app.buttons["onboarding.legal.continue"].waitForExistence(timeout: 5))
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

    func testFreshInstallCreatesSixDigitPINAndRequiresItAfterRelaunch() {
        app.terminate()
        app.launchArguments = ["UI_TESTING", "UI_TESTING_AUTOMATED_PROFILE", "UI_TESTING_RESET_STATE"]
        app.launch()
        XCTAssertTrue(app.buttons["onboarding.lock.method.pinOnly"].waitForExistence(timeout: 10))
        app.buttons["onboarding.lock.method.pinOnly"].tap()
        let pin = app.secureTextFields["onboarding.lock.pin"]
        let confirmation = app.secureTextFields["onboarding.lock.confirmation"]
        let next = app.buttons["onboarding.lock.continue"]
        for _ in 0..<6 where !pin.isHittable { app.swipeUp() }
        XCTAssertEqual(pin.placeholderValue, "PIN")
        pin.tap(); pin.typeText("01234")
        XCTAssertFalse(next.isEnabled)
        XCTAssertTrue(app.staticTexts["Use exactly six digits."].exists)
        pin.typeText("5")
        confirmation.tap(); confirmation.typeText("01234")
        XCTAssertFalse(next.isEnabled)
        confirmation.typeText("5")
        XCTAssertTrue(waitUntilEnabled(next))
        attachScreenshot(named: "iPhone Numeric PIN Setup")
        for _ in 0..<6 where !next.isHittable { app.swipeUp() }
        next.tap()
        XCTAssertTrue(app.buttons["onboarding.legal.continue"].waitForExistence(timeout: 10))
        app.terminate()
        app.launchArguments.removeAll { $0 == "UI_TESTING_RESET_STATE" }
        app.launch()
        let unlock = app.secureTextFields["unlock.pin"]
        XCTAssertTrue(unlock.waitForExistence(timeout: 10))
        XCTAssertEqual(unlock.placeholderValue, "PIN")
        unlock.tap(); unlock.typeText("012345")
        app.buttons["unlock.submitPIN"].tap()
        XCTAssertTrue(app.buttons["onboarding.legal.continue"].waitForExistence(timeout: 10))
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
