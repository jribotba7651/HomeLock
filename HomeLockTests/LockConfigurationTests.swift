import Testing
import Foundation
@testable import HomeLock

struct LockConfigurationTests {

    @Test func testIsExpired() async throws {
        let now = Date()
        let id = UUID()
        let accessoryID = UUID()
        let triggerID = UUID()
        
        // Not expired
        let futureDate = now.addingTimeInterval(3600)
        let config1 = LockConfiguration(
            id: id,
            accessoryID: accessoryID,
            accessoryName: "Test",
            triggerID: triggerID,
            lockedState: true,
            createdAt: now,
            expiresAt: futureDate
        )
        #expect(config1.isExpired == false)
        
        // Expired
        let pastDate = now.addingTimeInterval(-3600)
        let config2 = LockConfiguration(
            id: id,
            accessoryID: accessoryID,
            accessoryName: "Test",
            triggerID: triggerID,
            lockedState: true,
            createdAt: now,
            expiresAt: pastDate
        )
        #expect(config2.isExpired == true)
        
        // Indefinite (never expires)
        let config3 = LockConfiguration(
            id: id,
            accessoryID: accessoryID,
            accessoryName: "Test",
            triggerID: triggerID,
            lockedState: true,
            createdAt: now,
            expiresAt: nil
        )
        #expect(config3.isExpired == false)
    }

    @Test func testTimeRemaining() async throws {
        let now = Date()
        let id = UUID()
        let accessoryID = UUID()
        let triggerID = UUID()
        
        let duration: TimeInterval = 60
        let expiresAt = now.addingTimeInterval(duration)
        
        let config = LockConfiguration(
            id: id,
            accessoryID: accessoryID,
            accessoryName: "Test",
            triggerID: triggerID,
            lockedState: true,
            createdAt: now,
            expiresAt: expiresAt
        )
        
        let remaining = config.timeRemaining
        #expect(remaining != nil)
        #expect(remaining! > 55 && remaining! <= 60)
        
        // Indefinite
        let configIndefinite = LockConfiguration(
            id: id,
            accessoryID: accessoryID,
            accessoryName: "Test",
            triggerID: triggerID,
            lockedState: true,
            createdAt: now,
            expiresAt: nil
        )
        #expect(configIndefinite.timeRemaining == nil)
    }
}
