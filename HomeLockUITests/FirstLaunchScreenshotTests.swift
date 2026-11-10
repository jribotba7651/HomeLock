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
