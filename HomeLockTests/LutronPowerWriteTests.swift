import Testing
import Foundation
import HomeKit
@testable import HomeLock

/// Lutron lock path: skip the power write when the device is already in the target state.
struct LutronPowerWriteTests {

    @Test func testSkipsWriteWhenAlreadyInTargetState() {
        #expect(HomeKitService.shouldSkipPowerWrite(currentState: false, target: false))
        #expect(HomeKitService.shouldSkipPowerWrite(currentState: true, target: true))
    }

    @Test func testWritesWhenStateDiffers() {
        #expect(!HomeKitService.shouldSkipPowerWrite(currentState: false, target: true))
        #expect(!HomeKitService.shouldSkipPowerWrite(currentState: true, target: false))
    }

    @Test func testWritesWhenStateUnknown() {
        // A failed fresh read never skips the write.
        #expect(!HomeKitService.shouldSkipPowerWrite(currentState: nil, target: false))
        #expect(!HomeKitService.shouldSkipPowerWrite(currentState: nil, target: true))
    }

    @Test func testErrorCodeTagForHomeKitError() {
        let underlying = NSError(domain: HMErrorDomain, code: 14)
        let error = NSError(domain: HMErrorDomain, code: 74, userInfo: [NSUnderlyingErrorKey: underlying])
        #expect(ErrorCodeTag.tag(for: NSError(domain: HMErrorDomain, code: 74)) == "(HMError 74)")
        #expect(ErrorCodeTag.tag(for: error) == "(HMError 74; underlying HMError 14)")
        #expect(ErrorCodeTag.tag(for: LockManagerError.unlockFailed(name: "X", underlying: error))
                == "(HMError 74; underlying HMError 14)")
        #expect(ErrorCodeTag.message("Could not lock", for: error) == "Could not lock\n\n(HMError 74; underlying HMError 14)")
    }

    @Test func testNoErrorCodeTagForNonHomeKitError() {
        #expect(ErrorCodeTag.tag(for: LockManagerError.alreadyLocked) == nil)
        #expect(ErrorCodeTag.message("Msg", for: LockManagerError.alreadyLocked) == "Msg")
    }
}
