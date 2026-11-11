//
//  Build13Tests.swift
//  HomeLockTests
//
//  Build 13: daily-repeat cleanup, notification authorization, free-tier
//  limit before the trigger, trigger count, notification actions.
//

import Testing
import Foundation
import UserNotifications
@testable import HomeLock

struct DailyRepeatCleanupTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test @MainActor func yesterdaysTriggerIsRemovedBeforeItsWindowRepeats() {
        // A time-of-day trigger from a lock that ended yesterday must be
        // removed, or its window would enforce again today.
        let ended = now.addingTimeInterval(-23 * 3600)
        let name = HomeKitService.buildTriggerName(accessoryUUID: UUID(), expiresAt: ended)
        let expiresAt = HomeKitService.parseTriggerName(name)?.expiresAt
        #expect(HomeKitService.isOrphanedTrigger(chainResolved: true, expiresAt: expiresAt, now: now))
    }

    @Test @MainActor func runningTimedLockIsKept() {
        let name = HomeKitService.buildTriggerName(accessoryUUID: UUID(), expiresAt: now.addingTimeInterval(600))
        let expiresAt = HomeKitService.parseTriggerName(name)?.expiresAt
        #expect(!HomeKitService.isOrphanedTrigger(chainResolved: true, expiresAt: expiresAt, now: now))
    }
}

struct NotificationAuthorizationTests {
    @Test func statusesThatAllowTheExpiryNotification() {
        #expect(NotificationManager.allowsAlerts(.authorized))
        #expect(NotificationManager.allowsAlerts(.provisional))
        #expect(NotificationManager.allowsAlerts(.ephemeral))
    }

    @Test func statusesThatDontAllowIt() {
        #expect(!NotificationManager.allowsAlerts(.denied))
        #expect(!NotificationManager.allowsAlerts(.notDetermined))
    }
}

struct LockLimitTests {
    @Test func freeTierAllowsTwoLocks() {
        #expect(LockManager.freeLockLimit == 2)
        #expect(LockManager.allowsNewLock(isPro: false, activeLocks: 0))
        #expect(LockManager.allowsNewLock(isPro: false, activeLocks: 1))
        #expect(!LockManager.allowsNewLock(isPro: false, activeLocks: 2))
    }

    @Test func proIsUnlimited() {
        #expect(LockManager.allowsNewLock(isPro: true, activeLocks: 50))
    }

    @Test func overTheLimitThrowsBeforeAnyTrigger() {
        #expect(throws: LockManagerError.self) {
            try LockManager.checkLockLimit(isPro: false, activeLocks: 2)
        }
        #expect(throws: Never.self) {
            try LockManager.checkLockLimit(isPro: false, activeLocks: 1)
            try LockManager.checkLockLimit(isPro: true, activeLocks: 2)
        }
    }

    @Test func limitErrorIsClear() {
        let message = LockManagerError.lockLimitReached.localizedDescription
        #expect(message.contains("2"))
        #expect(message.contains("HomeLock Pro"))
    }
}

struct TriggerCountTests {
    @Test func countsLockTriggersOnly() {
        let id = UUID().uuidString
        let names = ["HomeLock_\(id)_exp1800000000", "HomeLock_Revert_\(id)", "Good Night", "HomeLock_\(UUID().uuidString)_expNONE"]
        #expect(HomeKitService.countHomeLockTriggers(named: names) == 2)
    }

    @Test func noTriggersIsZero() {
        #expect(HomeKitService.countHomeLockTriggers(named: []) == 0)
        #expect(HomeKitService.countHomeLockTriggers(named: ["Morning"]) == 0)
    }
}

struct NotificationActionTests {
    @Test func onlyReleaseLockReleases() {
        #expect(NotificationDelegate.releasesLock(actionIdentifier: "RELEASE_LOCK"))
    }

    @Test func keepLockedNeverReleases() {
        #expect(!NotificationDelegate.releasesLock(actionIdentifier: "KEEP_LOCKED"))
    }

    @Test func tappingTheBodyDoesNotRelease() {
        #expect(!NotificationDelegate.releasesLock(actionIdentifier: UNNotificationDefaultActionIdentifier))
        #expect(!NotificationDelegate.releasesLock(actionIdentifier: UNNotificationDismissActionIdentifier))
    }
}
