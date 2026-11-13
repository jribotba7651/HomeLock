import Testing
import Foundation
@testable import HomeLock

/// Keychain (PIN) survives uninstall; UserDefaults doesn't. InstallGuard must
/// clear the PIN only on a fresh install.
struct InstallGuardTests {

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "InstallGuardTests.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    @Test func testFreshInstallClearsPIN() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var wiped = 0
        let state = InstallGuard.run(defaults: defaults) { wiped += 1 }
        #expect(state == .freshInstall)
        #expect(wiped == 1)
        #expect(defaults.object(forKey: InstallGuard.installMarkerKey) != nil)
    }

    @Test func testUpdateFromPreMarkerBuildKeepsPIN() throws {
        for key in InstallGuard.legacyKeys {
            let (defaults, suite) = try makeDefaults()
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(3, forKey: key) // written by an earlier build, no marker
            var wiped = 0
            let state = InstallGuard.run(defaults: defaults) { wiped += 1 }
            #expect(state == .updateFromPreMarkerBuild, "key \(key)")
            #expect(wiped == 0, "key \(key)")
            #expect(defaults.object(forKey: InstallGuard.installMarkerKey) != nil)
        }
    }

    @Test func testNormalRelaunchKeepsPIN() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var wiped = 0
        InstallGuard.run(defaults: defaults) { wiped += 1 } // first launch
        #expect(wiped == 1)
        for _ in 0..<3 {
            #expect(InstallGuard.run(defaults: defaults) { wiped += 1 } == .relaunch)
        }
        #expect(wiped == 1)
    }

    // Real Keychain: the fresh-install wipe removes the PIN; restores any
    // existing PIN blob afterwards.
    @Test func testDeleteAllAuthItemsRemovesPINFromKeychain() throws {
        let keychain = KeychainManager.shared
        let pinKey = "HomeLock_PIN_Hash_v2"
        let saved = keychain.load(key: pinKey)
        defer {
            if let saved { _ = keychain.save(key: pinKey, data: saved) }
            else { _ = keychain.delete(key: pinKey) }
        }
        try #require(keychain.savePIN("123456"))
        #expect(keychain.isPINSet())
        keychain.deleteAllAuthItems()
        #expect(!keychain.isPINSet())
        #expect(!keychain.verifyPIN("123456"))
    }
}
