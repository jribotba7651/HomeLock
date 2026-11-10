//
//  LockEndPredicateTests.swift
//  HomeLockTests
//
//  The hub-side end condition for timed locks.
//

import Testing
import Foundation
import HomeKit
@testable import HomeLock

struct LockEndPredicateTests {

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Puerto_Rico")!
        return c
    }

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
    }

    @Test func exactMinuteIsKept() {
        let c = HomeKitService.lockEndComponents(for: date(2026, 11, 10, 21, 30), calendar: calendar)
        #expect(c == DateComponents(year: 2026, month: 11, day: 10, hour: 21, minute: 30))
    }

    @Test func secondsRoundUpSoTheHubNeverEndsEarly() {
        let c = HomeKitService.lockEndComponents(for: date(2026, 11, 10, 21, 30, 1), calendar: calendar)
        #expect(c == DateComponents(year: 2026, month: 11, day: 10, hour: 21, minute: 31))
    }

    @Test func roundingCrossesMidnightAndMonthEnd() {
        let c = HomeKitService.lockEndComponents(for: date(2026, 11, 30, 23, 59, 30), calendar: calendar)
        #expect(c == DateComponents(year: 2026, month: 12, day: 1, hour: 0, minute: 0))
    }

    @Test func includesTheFullDateNotJustTimeOfDay() {
        // An overnight or multi-day lock must not end at "the next 06:00".
        let c = HomeKitService.lockEndComponents(for: date(2026, 11, 12, 6, 0), calendar: calendar)
        #expect(c.year == 2026 && c.month == 11 && c.day == 12)
        #expect(c.hour == 6 && c.minute == 0)
        #expect(c.second == nil)
    }

    @Test func predicateBuildsFromComponents() {
        let comps = HomeKitService.lockEndComponents(for: date(2026, 11, 10, 21, 30), calendar: calendar)
        let predicate = HMEventTrigger.predicateForEvaluatingTrigger(occurringBefore: comps)
        #expect(!predicate.predicateFormat.isEmpty)
    }
}
