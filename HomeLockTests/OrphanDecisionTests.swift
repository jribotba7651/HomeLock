import Testing
import Foundation
@testable import HomeLock

struct OrphanDecisionTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func testResolvedIndefiniteIsNotOrphan() {
        #expect(!HomeKitService.isOrphanedTrigger(chainResolved: true, expiresAt: nil, now: now))
    }

    @Test func testResolvedFutureExpirationIsNotOrphan() {
        #expect(!HomeKitService.isOrphanedTrigger(chainResolved: true, expiresAt: now.addingTimeInterval(60), now: now))
    }

    @Test func testBrokenChainIsOrphan() {
        #expect(HomeKitService.isOrphanedTrigger(chainResolved: false, expiresAt: nil, now: now))
        #expect(HomeKitService.isOrphanedTrigger(chainResolved: false, expiresAt: now.addingTimeInterval(3600), now: now))
    }

    @Test func testExpiredIsOrphan() {
        #expect(HomeKitService.isOrphanedTrigger(chainResolved: true, expiresAt: now.addingTimeInterval(-1), now: now))
        // Exactly at expiration counts as expired
        #expect(HomeKitService.isOrphanedTrigger(chainResolved: true, expiresAt: now, now: now))
    }

    @Test @MainActor func testMalformedExpirationFromNameIsOrphan() {
        // parseTriggerName maps a malformed _exp to epoch 0 (fail-safe)
        let name = "HomeLock_\(UUID().uuidString)_expGARBAGE"
        let expiresAt = HomeKitService.parseTriggerName(name)?.expiresAt
        #expect(HomeKitService.isOrphanedTrigger(chainResolved: true, expiresAt: expiresAt, now: now))
    }
}
