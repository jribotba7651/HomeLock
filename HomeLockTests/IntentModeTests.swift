//
//  IntentModeTests.swift
//  HomeLockTests
//
//  HomeKit fails with HMError 80 "Missing entitlement for API" for an app in
//  the background, so intents that write to HomeKit must open the app.
//

import Testing
import AppIntents
import Foundation
import HomeKit
@testable import HomeLock

// TODO(1.1): re-enable with the Shortcuts intents (HOMELOCK_SHORTCUTS).
#if HOMELOCK_SHORTCUTS
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
#endif

/// v1 ships without Shortcuts/Siri actions (owner decision, build 17).
struct NoShortcutsInV1Tests {
    @Test func appExposesNoAppIntents() {
        // Every compiled AppIntent is listed in Metadata.appintents.
        let metadata = Bundle.main.bundleURL.appendingPathComponent("Metadata.appintents/extract.actionsdata")
        let data = (try? Data(contentsOf: metadata)) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        for intent in ["LockDeviceIntent", "UnlockDeviceIntent", "CheckLockStatusIntent"] {
            #expect(!text.contains(intent))
        }
    }

    @Test func noSiriUsageString() {
        #expect(Bundle.main.object(forInfoDictionaryKey: "NSSiriUsageDescription") == nil)
    }

    @Test func homeKitUsageStringStays() {
        #expect(Bundle.main.object(forInfoDictionaryKey: "NSHomeKitUsageDescription") != nil)
    }
}

/// Readiness/retry helpers kept from build 16 (used by unlock and the 1.1 Shortcuts path).
struct ReadWriteRetryTests {
    @Test func readWriteFailureIsDetected() {
        #expect(HomeKitService.isReadWriteFailure(HMError(.readWriteFailure)))
        #expect(HomeKitService.isReadWriteFailure(NSError(domain: HMErrorDomain, code: 74)))
        #expect(!HomeKitService.isReadWriteFailure(HMError(.accessoryIsBusy)))
        #expect(!HomeKitService.isReadWriteFailure(NSError(domain: "Other", code: 74)))
    }

    @Test @MainActor func retriesOnceOnReadWriteFailureThenSucceeds() async throws {
        var attempts = 0
        let value = try await HomeKitService.retryingOnceOnReadWriteFailure(delay: 0) {
            attempts += 1
            if attempts == 1 { throw HMError(.readWriteFailure) }
            return 7
        }
        #expect(value == 7)
        #expect(attempts == 2)
    }

    @Test @MainActor func retriesOnlyOnce() async {
        var attempts = 0
        await #expect(throws: HMError.self) {
            try await HomeKitService.retryingOnceOnReadWriteFailure(delay: 0) {
                attempts += 1
                throw HMError(.readWriteFailure)
            }
        }
        #expect(attempts == 2)
    }

    @Test @MainActor func otherErrorsAreNotRetried() async {
        var attempts = 0
        await #expect(throws: HMError.self) {
            try await HomeKitService.retryingOnceOnReadWriteFailure(delay: 0) {
                attempts += 1
                throw HMError(.accessoryNotReachable)
            }
        }
        #expect(attempts == 1)
    }

    @Test func noOpWriteIsSkippedForEveryDevice() {
        #expect(HomeKitService.shouldSkipPowerWrite(currentState: false, target: false))
        #expect(!HomeKitService.shouldSkipPowerWrite(currentState: true, target: false))
        #expect(!HomeKitService.shouldSkipPowerWrite(currentState: nil, target: false))
    }

    @Test @MainActor func failureMessageCarriesTheHomeKitCode() {
        let underlying = NSError(domain: HMErrorDomain, code: 14)
        let error = NSError(domain: HMErrorDomain, code: 74, userInfo: [NSUnderlyingErrorKey: underlying, NSLocalizedDescriptionKey: "Read/write operation failed."])
        let message = ErrorCodeTag.message(error.localizedDescription, for: error)
        #expect(message.contains("Read/write operation failed."))
        #expect(message.contains("(HMError 74; underlying HMError 14)"))
    }

    @Test @MainActor func unlockFailureMessageCarriesTheCode() {
        let error = LockManagerError.unlockFailed(name: "Lamp", underlying: NSError(domain: HMErrorDomain, code: 74))
        #expect(ErrorCodeTag.message(error.localizedDescription, for: error).contains("(HMError 74)"))
    }
}
