import Testing
import Foundation
@testable import HomeLock

/// Lock/unlock policy for Lutron accessories, driven by "Ignore Lutron devices".
struct LutronLockPolicyTests {

    // Setting OFF: Lutron behaves like any other device.
    @Test func testSettingOffAllowsLockAndUnlockOfLutron() throws {
        #expect(HomeKitService.allowsLock(isLutron: true, ignoreLutron: false))
        #expect(HomeKitService.allowsUnlock(isLutron: true, ignoreLutron: false))
        try LockManager.checkLockAllowed(isLutron: true, ignoreLutron: false)
    }

    // Setting ON (default): locking Lutron is blocked with lutronNotSupported.
    @Test func testSettingOnBlocksLockOfLutron() {
        #expect(!HomeKitService.allowsLock(isLutron: true, ignoreLutron: true))
        #expect(throws: LockManagerError.self) {
            try LockManager.checkLockAllowed(isLutron: true, ignoreLutron: true)
        }
        do {
            try LockManager.checkLockAllowed(isLutron: true, ignoreLutron: true)
            Issue.record("Expected lutronNotSupported")
        } catch LockManagerError.lutronNotSupported {
            // expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    // Setting ON keeps today's behavior: unlocking is never blocked, so an
    // existing Lutron lock can always be released.
    @Test func testSettingOnStillAllowsUnlockOfLutron() {
        #expect(HomeKitService.allowsUnlock(isLutron: true, ignoreLutron: true))
    }

    // Non-Lutron devices are never affected by the setting.
    @Test func testNonLutronUnaffectedBySetting() throws {
        for ignore in [true, false] {
            #expect(HomeKitService.allowsLock(isLutron: false, ignoreLutron: ignore))
            #expect(HomeKitService.allowsUnlock(isLutron: false, ignoreLutron: ignore))
            try LockManager.checkLockAllowed(isLutron: false, ignoreLutron: ignore)
        }
    }

    // The default (no stored value) blocks Lutron locks.
    @Test func testDefaultSettingBlocksLutronLock() throws {
        let suite = "LutronLockPolicyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let ignore = HomeKitService.isLutronIsolated(in: defaults)
        #expect(!HomeKitService.allowsLock(isLutron: true, ignoreLutron: ignore))
    }
}
