import Testing
import Foundation
@testable import HomeLock

/// v1: Lutron locking is compiled out (FeatureFlags.lutronLockingEnabled /
/// HOMELOCK_LUTRON). TODO(1.1): update when Lutron locking is re-enabled.
struct LutronV1ExclusionTests {

    @Test func testLutronLockingFlagIsOffInV1() {
        #expect(FeatureFlags.lutronLockingEnabled == false)
    }

    // With the flag off, Lutron is ignored even if the stored setting says OFF.
    @Test func testEffectiveIgnoreForcedOnWhenLutronDisabled() {
        #expect(HomeKitService.effectiveIgnoreLutron(stored: false, lutronEnabled: false))
        #expect(HomeKitService.effectiveIgnoreLutron(stored: true, lutronEnabled: false))
    }

    // With the flag on (1.1), the stored setting decides again.
    @Test func testEffectiveIgnoreFollowsSettingWhenLutronEnabled() {
        #expect(!HomeKitService.effectiveIgnoreLutron(stored: false, lutronEnabled: true))
        #expect(HomeKitService.effectiveIgnoreLutron(stored: true, lutronEnabled: true))
    }

    // A stale "Ignore Lutron = OFF" from an earlier build can't re-enable locking.
    @Test func testStaleSettingOffStillBlocksLutronLock() throws {
        let key = HomeKitService.ignoreLutronDefaultsKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.set(false, forKey: key)
        #expect(HomeKitService.shouldIgnoreLutron == true)
        #expect(throws: LockManagerError.self) {
            try LockManager.checkLockAllowed(isLutron: true, ignoreLutron: HomeKitService.shouldIgnoreLutron)
        }
        // Non-Lutron devices still lock.
        try LockManager.checkLockAllowed(isLutron: false, ignoreLutron: HomeKitService.shouldIgnoreLutron)
    }

    @Test @MainActor func testIgnoreToggleCannotBeTurnedOffInV1() {
        let key = HomeKitService.ignoreLutronDefaultsKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let service = HomeKitService()
        service.ignoreLutronDevices = false
        #expect(service.ignoreLutronDevices == true)
    }

    // Lutron is excluded from lockable outlets (and listed as not supported).
    @Test func testLutronHiddenFromOutletsInV1() {
        let ignore = HomeKitService.effectiveIgnoreLutron(stored: false, lutronEnabled: false)
        #expect(HomeKitService.hidesLutron(isLutron: true, ignoreLutron: ignore))
        #expect(!HomeKitService.hidesLutron(isLutron: false, ignoreLutron: ignore))
    }

    // Launch purge removes only HomeLock automations targeting Lutron.
    @Test func testPurgeRuleTargetsOnlyHomeLockLutronAutomations() {
        #expect(HomeKitService.shouldPurgeLutronAutomation(name: "HomeLock_ABC_exp1700000000", isLutron: true, lutronEnabled: false))
        #expect(HomeKitService.shouldPurgeLutronAutomation(name: "HomeLock_Revert_ABC", isLutron: true, lutronEnabled: false))
        #expect(!HomeKitService.shouldPurgeLutronAutomation(name: "HomeLock_ABC", isLutron: false, lutronEnabled: false))
        #expect(!HomeKitService.shouldPurgeLutronAutomation(name: "Evening Lights", isLutron: true, lutronEnabled: false))
        #expect(!HomeKitService.shouldPurgeLutronAutomation(name: "HomeLock_ABC", isLutron: true, lutronEnabled: true))
    }
}
