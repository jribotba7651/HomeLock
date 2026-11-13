//
//  InstallGuard.swift
//  HomeLock
//
//  The PIN hash and auth settings live in the Keychain, which survives an
//  uninstall; UserDefaults does not. Without this guard, deleting and
//  reinstalling the app (the documented "forgot my PIN" fix) still asks for
//  the old PIN and locks the user out.
//
//  Rule, run once per launch before the PIN screen:
//  - `installMarkerKey` present            -> normal relaunch: do nothing.
//  - marker missing, but any key that earlier builds already write to
//    UserDefaults is present (see `legacyKeys`) -> update from a build that
//    predates the marker: keep the PIN, just set the marker.
//  - marker missing and no legacy key      -> fresh install (or reinstall):
//    wipe HomeLock's Keychain auth items, then set the marker.
//
//  `appLaunchCount` is the main legacy signal: RootView increments it ~1.2s
//  after every launch since the first paywall build (Jan 2026), before any
//  PIN could be set, so anyone who has a PIN from an earlier build has it.
//  The other keys are extra safety nets.
//

import Foundation

nonisolated enum InstallGuard {
    enum InstallState: Equatable {
        case freshInstall
        case updateFromPreMarkerBuild
        case relaunch
    }

    static let installMarkerKey = "HomeLock_InstallMarker_v1"

    /// UserDefaults keys earlier builds already write. Any of them present
    /// means this is not a fresh install.
    static let legacyKeys = [
        "appLaunchCount",              // RootView, every launch
        "HomeLock_ActiveLocks",        // LockManager lock cache
        "HomeLock_ActiveScheduleLocks",// ScheduleManager
        "appearanceMode",              // Settings
        "ignoreLutronDevices",         // HomeKitService.ignoreLutronDefaultsKey
        "lockEndMode",                 // HomeKitService.lockEndModeKey
    ]

    /// Pure classification (no side effects).
    static func classify(_ defaults: UserDefaults) -> InstallState {
        if defaults.object(forKey: installMarkerKey) != nil { return .relaunch }
        if legacyKeys.contains(where: { defaults.object(forKey: $0) != nil }) {
            return .updateFromPreMarkerBuild
        }
        return .freshInstall
    }

    /// Classifies, wipes Keychain auth items on a fresh install, and sets the
    /// marker. Call before anything reads the PIN (AuthenticationManager).
    @discardableResult
    static func run(defaults: UserDefaults = .standard,
                    wipeKeychainAuth: () -> Void = { KeychainManager.shared.deleteAllAuthItems() }) -> InstallState {
        let state = classify(defaults)
        switch state {
        case .relaunch:
            break
        case .updateFromPreMarkerBuild:
            defaults.set(true, forKey: installMarkerKey)
        case .freshInstall:
            wipeKeychainAuth()
            defaults.set(true, forKey: installMarkerKey)
        }
        print("🔐 [InstallGuard] \(state)")
        return state
    }
}
