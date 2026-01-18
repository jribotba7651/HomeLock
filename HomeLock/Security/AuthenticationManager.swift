//
//  AuthenticationManager.swift
//  HomeLock
//
//  Created by HomeLock on [Date]
//  Copyright © [Year] HomeLock. All rights reserved.
//

import Foundation
import SwiftUI
import Combine

class AuthenticationManager: ObservableObject {
    static let shared = AuthenticationManager()

    @Published var isAuthenticated: Bool = false
    @Published var isPINSetup: Bool = false
    @Published var showingPINSetup: Bool = false
    @Published var showingAuthentication: Bool = false
    @Published var authenticationError: AuthenticationError?

    // PIN Lockout Management
    @Published var failedAttempts: Int = 0
    @Published var isLockedOut: Bool = false
    @Published var lockoutEndTime: Date?

    private let maxFailedAttempts = 5
    private let lockoutDuration: TimeInterval = 5 * 60 // 5 minutes
    private var lockoutTimer: Timer?

    // Keychain and Biometric managers
    private let keychainManager = KeychainManager.shared
    private let biometricManager = BiometricAuthManager.shared

    private var cancellables = Set<AnyCancellable>()

    private init() {
        checkInitialState()
        setupBackgroundObserver()
        loadLockoutState()
    }

    // MARK: - Initial State

    private func checkInitialState() {
        isPINSetup = keychainManager.isPINSet()
        isAuthenticated = !keychainManager.isAppLocked()

        if isPINSetup && keychainManager.isAppLocked() {
            showingAuthentication = true
        } else if !isPINSetup {
            showingPINSetup = true
        }
    }

    // MARK: - PIN Setup

    func setupPIN(_ pin: String, confirmation: String) -> Result<Bool, AuthenticationError> {
        // Validate PIN format
        guard isValidPIN(pin) else {
            return .failure(.invalidPin)
        }

        // Validate confirmation
        guard pin == confirmation else {
            return .failure(.pinMismatch)
        }

        // Save PIN
        let success = keychainManager.savePIN(pin)
        if success {
            isPINSetup = true
            showingPINSetup = false
            isAuthenticated = true
            _ = keychainManager.setAppLocked(false)

            // Ask for biometric setup if available
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.promptForBiometricSetup()
            }

            return .success(true)
        } else {
            return .failure(.authenticationFailed)
        }
    }

    private func isValidPIN(_ pin: String) -> Bool {
        return pin.count == 6 && pin.allSatisfy { $0.isNumber }
    }

    // MARK: - Authentication

    func authenticateWithPIN(_ pin: String) -> Result<Bool, AuthenticationError> {
        // Check if locked out
        guard !isLockedOut else {
            return .failure(.pinLockout)
        }

        // Validate PIN format
        guard isValidPIN(pin) else {
            return .failure(.invalidPin)
        }

        // Get stored PIN
        guard let storedPIN = keychainManager.loadPIN() else {
            return .failure(.authenticationFailed)
        }

        // Check PIN
        if pin == storedPIN {
            // Successful authentication
            resetFailedAttempts()
            isAuthenticated = true
            showingAuthentication = false
            _ = keychainManager.setAppLocked(false)
            return .success(true)
        } else {
            // Failed authentication
            incrementFailedAttempts()
            return .failure(.pinIncorrect)
        }
    }

    func authenticateWithBiometrics() async -> Result<Bool, AuthenticationError> {
        // Check if locked out
        guard !isLockedOut else {
            return .failure(.pinLockout)
        }

        let result = await biometricManager.authenticateWithBiometrics()

        switch result {
        case .success(let success):
            if success {
                DispatchQueue.main.async {
                    self.resetFailedAttempts()
                    self.isAuthenticated = true
                    self.showingAuthentication = false
                    _ = self.keychainManager.setAppLocked(false)
                }
                return .success(true)
            } else {
                return .failure(.authenticationFailed)
            }
        case .failure(let error):
            return .failure(error)
        }
    }

    // MARK: - Lockout Management

    private func incrementFailedAttempts() {
        failedAttempts += 1
        saveLockoutState()

        if failedAttempts >= maxFailedAttempts {
            startLockout()
        }
    }

    private func resetFailedAttempts() {
        failedAttempts = 0
        isLockedOut = false
        lockoutEndTime = nil
        lockoutTimer?.invalidate()
        lockoutTimer = nil
        saveLockoutState()
    }

    private func startLockout() {
        isLockedOut = true
        lockoutEndTime = Date().addingTimeInterval(lockoutDuration)
        saveLockoutState()

        // Start timer to end lockout
        lockoutTimer?.invalidate()
        lockoutTimer = Timer.scheduledTimer(withTimeInterval: lockoutDuration, repeats: false) { _ in
            DispatchQueue.main.async {
                self.endLockout()
            }
        }
    }

    private func endLockout() {
        isLockedOut = false
        failedAttempts = 0
        lockoutEndTime = nil
        lockoutTimer?.invalidate()
        lockoutTimer = nil
        saveLockoutState()
    }

    var remainingLockoutTime: TimeInterval {
        guard let endTime = lockoutEndTime else { return 0 }
        return max(0, endTime.timeIntervalSinceNow)
    }

    // MARK: - Persistence

    private func saveLockoutState() {
        UserDefaults.standard.set(failedAttempts, forKey: "HomeLock_FailedAttempts")
        UserDefaults.standard.set(lockoutEndTime, forKey: "HomeLock_LockoutEndTime")
    }

    private func loadLockoutState() {
        failedAttempts = UserDefaults.standard.integer(forKey: "HomeLock_FailedAttempts")
        lockoutEndTime = UserDefaults.standard.object(forKey: "HomeLock_LockoutEndTime") as? Date

        // Check if still locked out
        if let endTime = lockoutEndTime {
            if Date() < endTime {
                isLockedOut = true
                let remainingTime = endTime.timeIntervalSinceNow
                lockoutTimer = Timer.scheduledTimer(withTimeInterval: remainingTime, repeats: false) { _ in
                    DispatchQueue.main.async {
                        self.endLockout()
                    }
                }
            } else {
                endLockout()
            }
        }
    }

    // MARK: - App Lifecycle

    private func setupBackgroundObserver() {
        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .sink { [weak self] _ in
                self?.lockApp()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.checkAuthenticationRequired()
            }
            .store(in: &cancellables)
    }

    private func lockApp() {
        if isPINSetup && isAuthenticated {
            isAuthenticated = false
            _ = keychainManager.setAppLocked(true)
            showingAuthentication = true
        }
    }

    private func checkAuthenticationRequired() {
        if isPINSetup && !isAuthenticated {
            showingAuthentication = true
        }
    }

    // MARK: - Biometric Setup

    private func promptForBiometricSetup() {
        guard biometricManager.isBiometricAvailable else { return }

        let alert = UIAlertController(
            title: "Enable \(biometricManager.biometricTypeString)?",
            message: "Would you like to enable \(biometricManager.biometricTypeString) for quick and secure access?",
            preferredStyle: .alert
        )

        alert.addAction(UIAlertAction(title: "Enable", style: .default) { _ in
            Task {
                _ = await self.biometricManager.requestBiometricSetup()
            }
        })

        alert.addAction(UIAlertAction(title: "Not Now", style: .cancel))

        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first,
           let rootViewController = window.rootViewController {
            rootViewController.present(alert, animated: true)
        }
    }

    // MARK: - Manual Actions

    func logout() {
        isAuthenticated = false
        showingAuthentication = true
        _ = keychainManager.setAppLocked(true)
    }

    func resetSecurity() {
        // Clear all security data
        _ = keychainManager.deletePIN()
        _ = keychainManager.deleteSecurityToken()
        biometricManager.setBiometricEnabled(false)

        // Reset state
        isPINSetup = false
        isAuthenticated = false
        showingPINSetup = true
        showingAuthentication = false
        resetFailedAttempts()

        // Clear app lock state
        _ = keychainManager.setAppLocked(false)
    }
}