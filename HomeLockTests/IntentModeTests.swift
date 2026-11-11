//
//  IntentModeTests.swift
//  HomeLockTests
//
//  HomeKit fails with HMError 80 "Missing entitlement for API" for an app in
//  the background, so intents that write to HomeKit must open the app.
//

import Testing
import AppIntents
@testable import HomeLock

struct IntentModeTests {
    @Test func lockIntentRunsInTheForeground() {
        #expect(LockDeviceIntent.supportedModes == .foreground(.immediate))
        #expect(!LockDeviceIntent.supportedModes.contains(.background))
    }

    @Test func unlockIntentRunsInTheForeground() {
        #expect(UnlockDeviceIntent.supportedModes == .foreground(.immediate))
        #expect(!UnlockDeviceIntent.supportedModes.contains(.background))
    }
}
