//
//  FirstLaunchScreenshotTests.swift
//  HomeLockUITests
//
//  Walks the first-launch flow (paywall -> Set PIN -> Confirm PIN) and keeps
//  screenshots as test attachments. Needs a fresh install: delete the app and
//  reset the simulator keychain first (the PIN lives in the keychain), e.g.
//    xcrun simctl uninstall <udid> com.jibaroenlaluna.HomeLock
//    xcrun simctl keychain <udid> reset
//

import XCTest

final class FirstLaunchScreenshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testFirstLaunchPaywallAndPINSetup() throws {
        let app = XCUIApplication()
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

        // First launch shows the paywall.
        let proTitle = app.staticTexts["HomeLock Pro"]
        XCTAssertTrue(waitDismissingAlerts(for: proTitle, springboard: springboard, timeout: 20),
                      "Paywall did not appear on first launch")
        // The HomeKit permission prompt can land on top of the paywall.
        for _ in 0..<4 { dismissAlerts(springboard); sleep(1) }
        _ = app.staticTexts["One-time purchase"].waitForExistence(timeout: 5)
        keep(app, "1-paywall")

        app.buttons["Close"].tap()

        // PIN setup: exactly one keypad.
        let setTitle = app.staticTexts["Set Your PIN"]
        guard waitDismissingAlerts(for: setTitle, springboard: springboard, timeout: 10) else {
            throw XCTSkip("PIN already set — reset the simulator keychain for a first-launch run")
        }
        XCTAssertEqual(app.buttons.matching(identifier: "5").count, 1, "Expected exactly one keypad")
        keep(app, "2-set-pin")

        enter("123456", in: app)
        XCTAssertTrue(app.staticTexts["Confirm Your PIN"].waitForExistence(timeout: 5))
        enter("12", in: app)
        keep(app, "3-confirm-pin")
        enter("3456", in: app)

        // PIN accepted: setup screen goes away.
        XCTAssertTrue(waitForNonExistence(app.staticTexts["Confirm Your PIN"], timeout: 5))
        dismissAlerts(springboard)
        keep(app, "4-after-setup")

        // Unlock screen uses the same layout: background the app, come back.
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.staticTexts["Welcome Back"].waitForExistence(timeout: 10), "Unlock screen not shown")
        XCTAssertEqual(app.buttons.matching(identifier: "5").count, 1, "Expected exactly one keypad")
        enter("12", in: app)
        keep(app, "5-unlock-pin")
        enter("3456", in: app)
        XCTAssertTrue(waitForNonExistence(app.staticTexts["Welcome Back"], timeout: 5), "PIN unlock failed")

        // With a PIN set, reopen the paywall (RootView shows it on every 5th launch).
        var paywallShown = false
        for _ in 0..<6 where !paywallShown {
            app.terminate()
            app.launch()
            if app.staticTexts["Welcome Back"].waitForExistence(timeout: 4) { enter("123456", in: app) }
            paywallShown = waitDismissingAlerts(for: proTitle, springboard: springboard, timeout: 6)
        }
        XCTAssertTrue(paywallShown, "Paywall did not reappear by launch 5")

        // Tapping Unlock Pro brings up a system purchase / sign-in sheet; the
        // app resigns active but must NOT lock.
        app.buttons["Unlock Pro"].tap()
        let systemSheet = springboard.alerts.firstMatch
        XCTAssertTrue(systemSheet.waitForExistence(timeout: 15), "No system purchase sheet appeared")
        sleep(1)
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertFalse(app.staticTexts["Welcome Back"].exists, "App locked behind the purchase sheet")
        keep(XCUIScreen.main, "6-purchase-sheet-no-lock")
        systemSheet.buttons["Cancel"].firstMatch.tap()
        for _ in 0..<3 { dismissAlerts(springboard); sleep(1) }   // follow-up "sign in failed" alerts, if any
        if springboard.alerts.buttons["OK"].exists { springboard.alerts.buttons["OK"].tap() }
        XCTAssertTrue(proTitle.exists, "Paywall should still be showing after the sheet closes")
        XCTAssertFalse(app.staticTexts["Welcome Back"].exists, "App locked after the purchase sheet closed")

        // Control Center makes the app inactive (willResignActive) without
        // backgrounding it — the same transition a real purchase / Face ID
        // sheet causes on device. It must NOT lock.
        // Face ID phones: swipe down from the top-right corner (a top swipe on a
        // Home-button phone opens the Cover Sheet, which really backgrounds the app).
        // Home-button phones (iPhone SE): swipe up from the bottom edge.
        func drag(_ from: CGVector, _ to: CGVector) {
            springboard.coordinate(withNormalizedOffset: from)
                .press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: to))
        }
        let hasHomeButton = app.windows.firstMatch.frame.height < 700
        if hasHomeButton {
            drag(CGVector(dx: 0.5, dy: 0.995), CGVector(dx: 0.5, dy: 0.3))
        } else {
            drag(CGVector(dx: 0.95, dy: 0.005), CGVector(dx: 0.95, dy: 0.7))
        }
        sleep(2)
        keep(XCUIScreen.main, "6b-control-center")
        if hasHomeButton {
            drag(CGVector(dx: 0.5, dy: 0.05), CGVector(dx: 0.5, dy: 0.9))
        } else {
            drag(CGVector(dx: 0.5, dy: 0.98), CGVector(dx: 0.5, dy: 0.3))
        }
        sleep(2)
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertFalse(app.staticTexts["Welcome Back"].exists, "App locked after Control Center (inactive only)")
        XCTAssertTrue(proTitle.exists, "Paywall should still be showing after Control Center")

        // Going to the background DOES lock.
        app.buttons["Close"].tap()
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5) || app.wait(for: .runningBackgroundSuspended, timeout: 5))
        app.activate()
        XCTAssertTrue(app.staticTexts["Welcome Back"].waitForExistence(timeout: 10), "App did not lock after background")
        keep(app, "7-locked-after-background")
    }

    private func keep(_ screen: XCUIScreen, _ name: String) {
        let shot = XCTAttachment(screenshot: screen.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    // MARK: - Helpers

    private func enter(_ digits: String, in app: XCUIApplication) {
        for d in digits { app.buttons[String(d)].tap() }
    }

    private func keep(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func dismissAlerts(_ springboard: XCUIApplication) {
        // Without the local StoreKit file (xcodebuild test), StoreKit may ask to
        // sign in to a sandbox Apple Account. Cancel those; allow HomeKit access.
        let alert = springboard.alerts.firstMatch
        if alert.exists && alert.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Apple Account'")).count > 0 {
            alert.buttons["Cancel"].firstMatch.tap()
            return
        }
        for label in ["Allow", "Allow While Using App"] {
            let button = springboard.alerts.buttons[label].firstMatch
            if button.exists { button.tap() }
        }
    }

    private func waitDismissingAlerts(for element: XCUIElement, springboard: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists { return true }
            dismissAlerts(springboard)
            _ = element.waitForExistence(timeout: 1)
        }
        return element.exists
    }

    private func waitForNonExistence(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let p = NSPredicate(format: "exists == false")
        return XCTWaiter().wait(for: [expectation(for: p, evaluatedWith: element)], timeout: timeout) == .completed
    }
}
