import Testing
import Foundation
@testable import HomeLock

struct ScheduleOwnershipTests {
    let windowEnd = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func testFreeAccessoryIsLocked() {
        #expect(ScheduleManager.activationDecision(isAccessoryLocked: false, skippedWindowEnd: nil, windowEnd: windowEnd) == .lock)
    }

    @Test func testExistingLockIsNotAdoptedAndLoggedOnce() {
        #expect(ScheduleManager.activationDecision(isAccessoryLocked: true, skippedWindowEnd: nil, windowEnd: windowEnd) == .skipExistingLock(log: true))
        // Same window already skipped: don't log again
        #expect(ScheduleManager.activationDecision(isAccessoryLocked: true, skippedWindowEnd: windowEnd, windowEnd: windowEnd) == .skipExistingLock(log: false))
    }

    @Test func testNewWindowLogsAgain() {
        let previous = windowEnd.addingTimeInterval(-86_400)
        #expect(ScheduleManager.activationDecision(isAccessoryLocked: true, skippedWindowEnd: previous, windowEnd: windowEnd) == .skipExistingLock(log: true))
    }

    @Test func testManualLockEndedDuringWindowLocks() {
        #expect(ScheduleManager.activationDecision(isAccessoryLocked: false, skippedWindowEnd: windowEnd, windowEnd: windowEnd) == .lock)
    }
}
