import Testing
import Foundation
@testable import HomeLock

struct ScheduleWindowTests {
    // Fixed calendar so results don't depend on the machine's locale/time zone
    let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    // Weekdays: 1=Sun, 2=Mon, 3=Tue ... 7=Sat
    // 2026-11-09 is a Monday.
    func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }
    func time(_ hour: Int, _ minute: Int = 0) -> Date { date(1, hour, minute) }

    func end(now: Date, start: Date, end: Date, days: [Int]) -> Date? {
        ScheduleManager.activeWindowEnd(now: now, start: start, end: end, days: days, calendar: calendar)
    }

    @Test func testSameDayWindowInside() {
        let result = end(now: date(9, 10), start: time(9), end: time(17), days: [2])
        #expect(result == date(9, 17))
    }

    @Test func testSameDayWindowOutside() {
        #expect(end(now: date(9, 8, 59), start: time(9), end: time(17), days: [2]) == nil)
        // End is exclusive
        #expect(end(now: date(9, 17), start: time(9), end: time(17), days: [2]) == nil)
    }

    @Test func testSameDayWindowWrongDay() {
        // Tuesday, schedule is Monday only
        #expect(end(now: date(10, 10), start: time(9), end: time(17), days: [2]) == nil)
    }

    @Test func testOvernightEveningPartEndsNextMorning() {
        // Monday 22:00, schedule Mon 21:00-07:00 -> ends Tuesday 07:00
        let result = end(now: date(9, 22), start: time(21), end: time(7), days: [2])
        #expect(result == date(10, 7))
    }

    @Test func testOvernightMorningPartCountsStartDay() {
        // Tuesday 06:00 belongs to Monday's window -> ends Tuesday 07:00
        let result = end(now: date(10, 6), start: time(21), end: time(7), days: [2])
        #expect(result == date(10, 7))
    }

    @Test func testOvernightMorningPartWithoutPreviousDayIsInactive() {
        // Monday 06:00: Sunday is not scheduled, so not in a window even though Monday is
        #expect(end(now: date(9, 6), start: time(21), end: time(7), days: [2]) == nil)
    }

    @Test func testOvernightCrossesMonthAndWeekBoundary() {
        // Saturday 2026-11-28 23:30, schedule Sat 21:00-07:00 -> ends Sunday 2026-11-29 07:00
        let result = end(now: date(28, 23, 30), start: time(21), end: time(7), days: [7])
        #expect(result == date(29, 7))
    }

    @Test func testOvernightBetweenWindowsIsInactive() {
        #expect(end(now: date(10, 12), start: time(21), end: time(7), days: [2, 3]) == nil)
    }

    @Test func testEqualStartAndEndIsNeverActive() {
        #expect(end(now: date(9, 9), start: time(9), end: time(9), days: [1, 2, 3, 4, 5, 6, 7]) == nil)
    }
}
