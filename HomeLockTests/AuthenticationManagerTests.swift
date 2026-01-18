import Testing
import Foundation
@testable import HomeLock

@MainActor
struct AuthenticationManagerTests {

    @Test func testPINValidation() async throws {
        let manager = AuthenticationManager.shared
        manager.resetSecurity()
        
        // Valid PIN
        let result1 = manager.setupPIN("123456", confirmation: "123456")
        if case .success(let success) = result1 {
            #expect(success == true)
        } else {
            Issue.record("Should have succeeded")
        }
        
        // Mismatch
        let result2 = manager.setupPIN("123456", confirmation: "654321")
        if case .failure(let error) = result2 {
            #expect(error == .pinMismatch)
        } else {
            Issue.record("Should have failed with mismatch")
        }
        
        // Too short
        let result3 = manager.setupPIN("123", confirmation: "123")
        if case .failure(let error) = result3 {
            #expect(error == .invalidPin)
        } else {
            Issue.record("Should have failed with invalid format")
        }
    }

    @Test func testBruteForceLockout() async throws {
        let manager = AuthenticationManager.shared
        manager.resetSecurity()
        _ = manager.setupPIN("123456", confirmation: "123456")
        
        // Fail 5 times
        for _ in 1...5 {
            _ = manager.authenticateWithPIN("000000")
        }
        
        let result = manager.authenticateWithPIN("123456")
        if case .failure(let error) = result {
            #expect(error == .pinLockout)
        } else {
            Issue.record("Should have been locked out")
        }
    }
}
