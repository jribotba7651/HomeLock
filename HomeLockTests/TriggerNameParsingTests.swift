import Testing
import Foundation
@testable import HomeLock

@MainActor
struct TriggerNameParsingTests {

    // MARK: - New format with timestamp

    @Test func testNewFormatWithTimestamp() {
        let uuid = UUID()
        let timestamp: TimeInterval = 1751836800 // 2025-07-06 16:00:00 UTC
        let name = "HomeLock_\(uuid.uuidString)_exp\(Int(timestamp))"

        let parsed = HomeKitService.parseTriggerName(name)
        #expect(parsed != nil)
        #expect(parsed?.accessoryUUID == uuid)
        #expect(parsed?.expiresAt != nil)
        #expect(Int(parsed!.expiresAt!.timeIntervalSince1970) == Int(timestamp))
    }

    // MARK: - New format with NONE (indefinite)

    @Test func testNewFormatWithNONE() {
        let uuid = UUID()
        let name = "HomeLock_\(uuid.uuidString)_expNONE"

        let parsed = HomeKitService.parseTriggerName(name)
        #expect(parsed != nil)
        #expect(parsed?.accessoryUUID == uuid)
        #expect(parsed?.expiresAt == nil) // NONE = indefinite
    }

    // MARK: - Legacy format (no _exp suffix)

    @Test func testLegacyFormat() {
        let uuid = UUID()
        let name = "HomeLock_\(uuid.uuidString)"

        let parsed = HomeKitService.parseTriggerName(name)
        #expect(parsed != nil)
        #expect(parsed?.accessoryUUID == uuid)
        #expect(parsed?.expiresAt == nil) // Legacy = indefinite
    }

    // MARK: - Malformed _exp value -> fail-safe to epoch 0

    @Test func testMalformedExpValue() {
        let uuid = UUID()
        let name = "HomeLock_\(uuid.uuidString)_expGARBAGE"

        let parsed = HomeKitService.parseTriggerName(name)
        #expect(parsed != nil)
        #expect(parsed?.accessoryUUID == uuid)
        // Malformed = fail-safe to epoch 0, NOT nil (indefinite)
        #expect(parsed?.expiresAt != nil)
        #expect(parsed!.expiresAt!.timeIntervalSince1970 == 0)
    }

    @Test func testMalformedExpEmpty() {
        let uuid = UUID()
        let name = "HomeLock_\(uuid.uuidString)_exp"

        let parsed = HomeKitService.parseTriggerName(name)
        #expect(parsed != nil)
        #expect(parsed?.accessoryUUID == uuid)
        // Empty string after _exp = malformed = epoch 0
        #expect(parsed?.expiresAt != nil)
        #expect(parsed!.expiresAt!.timeIntervalSince1970 == 0)
    }

    // MARK: - Revert action set names are rejected

    @Test func testRevertActionSetRejected() {
        let name = "HomeLock_Revert_A9E57E14-1234-5678-9ABC-DEF012345678"
        let parsed = HomeKitService.parseTriggerName(name)
        #expect(parsed == nil)
    }

    // MARK: - Non-HomeLock names are rejected

    @Test func testNonHomeLockRejected() {
        let parsed = HomeKitService.parseTriggerName("SomeOtherTrigger_123")
        #expect(parsed == nil)
    }

    // MARK: - Invalid UUID in name

    @Test func testInvalidUUID() {
        let parsed = HomeKitService.parseTriggerName("HomeLock_not-a-uuid_exp1751836800")
        #expect(parsed == nil)
    }

    @Test func testInvalidUUIDLegacy() {
        let parsed = HomeKitService.parseTriggerName("HomeLock_not-a-uuid")
        #expect(parsed == nil)
    }

    // MARK: - buildTriggerName round-trip

    @Test func testBuildAndParseRoundTrip() {
        let uuid = UUID()
        let expiresAt = Date(timeIntervalSince1970: 1751836800)

        // With expiration
        let name1 = HomeKitService.buildTriggerName(accessoryUUID: uuid, expiresAt: expiresAt)
        let parsed1 = HomeKitService.parseTriggerName(name1)
        #expect(parsed1?.accessoryUUID == uuid)
        #expect(Int(parsed1!.expiresAt!.timeIntervalSince1970) == 1751836800)

        // Without expiration (NONE)
        let name2 = HomeKitService.buildTriggerName(accessoryUUID: uuid, expiresAt: nil)
        #expect(name2.hasSuffix("_expNONE"))
        let parsed2 = HomeKitService.parseTriggerName(name2)
        #expect(parsed2?.accessoryUUID == uuid)
        #expect(parsed2?.expiresAt == nil)
    }

    // MARK: - Coexistence: old and new format in same home

    @Test func testOldAndNewFormatCoexist() {
        let uuid1 = UUID()
        let uuid2 = UUID()

        // Old format trigger
        let oldName = "HomeLock_\(uuid1.uuidString)"
        // New format trigger
        let newName = "HomeLock_\(uuid2.uuidString)_exp1751836800"

        let parsedOld = HomeKitService.parseTriggerName(oldName)
        let parsedNew = HomeKitService.parseTriggerName(newName)

        // Both parse successfully
        #expect(parsedOld != nil)
        #expect(parsedNew != nil)

        // Correct UUIDs extracted
        #expect(parsedOld?.accessoryUUID == uuid1)
        #expect(parsedNew?.accessoryUUID == uuid2)

        // Old = indefinite, new = has expiration
        #expect(parsedOld?.expiresAt == nil)
        #expect(parsedNew?.expiresAt != nil)
        #expect(Int(parsedNew!.expiresAt!.timeIntervalSince1970) == 1751836800)
    }

    // MARK: - Negative timestamp treated as malformed

    @Test func testNegativeTimestamp() {
        let uuid = UUID()
        let name = "HomeLock_\(uuid.uuidString)_exp-100"

        let parsed = HomeKitService.parseTriggerName(name)
        #expect(parsed != nil)
        // Negative timestamp fails the `timestamp > 0` check -> malformed -> epoch 0
        #expect(parsed?.expiresAt != nil)
        #expect(parsed!.expiresAt!.timeIntervalSince1970 == 0)
    }

    // MARK: - Zero timestamp treated as malformed

    @Test func testZeroTimestamp() {
        let uuid = UUID()
        let name = "HomeLock_\(uuid.uuidString)_exp0"

        let parsed = HomeKitService.parseTriggerName(name)
        #expect(parsed != nil)
        // 0 fails the `timestamp > 0` check -> malformed -> epoch 0
        #expect(parsed?.expiresAt != nil)
        #expect(parsed!.expiresAt!.timeIntervalSince1970 == 0)
    }
}
