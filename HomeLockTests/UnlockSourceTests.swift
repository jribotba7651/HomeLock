import Testing
@testable import HomeLock

/// Release Lock from a notification must never leave the device locked on a
/// HomeKit error (regression from 60cf31d); in-app unlocks keep it for retry.
struct UnlockSourceTests {

    @Test func testNotificationReleaseNeverKeepsLock() {
        #expect(LockManager.keepsLocalLockOnFailure(.notification) == false)
    }

    @Test func testInAppUnlockKeepsLockOnFailure() {
        #expect(LockManager.keepsLocalLockOnFailure(.inApp) == true)
    }
}
