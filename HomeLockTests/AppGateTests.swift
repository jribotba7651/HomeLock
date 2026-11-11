import Testing
@testable import HomeLock

/// Root gate: "Release Lock" from a notification replaces the PIN screen with
/// the release status screen; the main content still requires the PIN.
struct AppGateTests {

    @Test func testNotificationReleaseReplacesPIN() {
        #expect(AppGate.decide(isPINSetup: true, isAuthenticated: false, notificationReleaseActive: true) == .notificationRelease)
    }

    @Test func testNormalOpenShowsPIN() {
        #expect(AppGate.decide(isPINSetup: true, isAuthenticated: false, notificationReleaseActive: false) == .pin)
    }

    @Test func testNotificationReleaseNeverShowsContentWhenLocked() {
        #expect(AppGate.decide(isPINSetup: true, isAuthenticated: false, notificationReleaseActive: true) != .content)
    }

    @Test func testAuthenticatedShowsContent() {
        #expect(AppGate.decide(isPINSetup: true, isAuthenticated: true, notificationReleaseActive: false) == .content)
        #expect(AppGate.decide(isPINSetup: true, isAuthenticated: true, notificationReleaseActive: true) == .content)
    }

    @Test func testNoPINSetupShowsSetup() {
        #expect(AppGate.decide(isPINSetup: false, isAuthenticated: false, notificationReleaseActive: false) == .pinSetup)
        #expect(AppGate.decide(isPINSetup: false, isAuthenticated: false, notificationReleaseActive: true) == .pinSetup)
    }
}
