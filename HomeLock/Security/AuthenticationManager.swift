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
import LocalAuthentication

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

        // Verificación contra hash PBKDF2 guardado en Keychain.
        // `verifyPIN` hace constant-time compare internamente.
        guard keychainManager.isPINSet() else {
            return .failure(.authenticationFailed)
        }

        if keychainManager.verifyPIN(pin) {
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

    /// Requiere autenticación del dueño del dispositivo (Face ID / Touch ID
    /// con passcode del device como fallback) para acciones sensibles ejecutadas
    /// FUERA de la UI principal — por ejemplo desde un `AppIntent` de Siri /
    /// Shortcuts o desde la acción de una notificación.
    ///
    /// Esto NO usa el PIN de HomeLock (los `AppIntent` no pueden presentar la
    /// PINEntryView de forma fiable). Usa la autenticación del dueño del
    /// device, que es la barrera que Apple recomienda para acciones sensibles
    /// invocadas fuera del foreground.
    ///
    /// - Parameter reason: texto que se muestra en el prompt de Face ID.
    /// - Returns: `true` si autenticó, `false` si canceló o falló.
    func requireDeviceAuthForIntent(reason: String) async -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"

        var error: NSError?
        // `.deviceOwnerAuthentication` = biometría + passcode del device como fallback.
        // Usamos este (no `.deviceOwnerAuthenticationWithBiometrics`) para que
        // el padre pueda autorizar aunque Face ID esté deshabilitado.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            print("🔐 [Auth] canEvaluatePolicy failed: \(error?.localizedDescription ?? "unknown")")
            return false
        }

        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            print("🔐 [Auth] evaluatePolicy failed: \(error.localizedDescription)")
            return false
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

    /// Persiste el estado de lockout en Keychain. ANTES vivía en UserDefaults,
    /// lo cual permitía bypass trivial: desinstalar + reinstalar borra
    /// UserDefaults pero el PIN en Keychain sobrevive → contador reseteado a 0
    /// y el atacante vuelve a tener 5 intentos. Moviéndolo a Keychain hacemos
    /// que el lockout también sobreviva a reinstalaciones.
    private func saveLockoutState() {
        keychainManager.saveFailedAttempts(failedAttempts)
        keychainManager.saveLockoutEndTime(lockoutEndTime)

        // Legacy cleanup: si venimos de un build anterior con el estado en
        // UserDefaults, lo borramos para que no quede basura.
        UserDefaults.standard.removeObject(forKey: "HomeLock_FailedAttempts")
        UserDefaults.standard.removeObject(forKey: "HomeLock_LockoutEndTime")
    }

    private func loadLockoutState() {
        failedAttempts = keychainManager.loadFailedAttempts()
        lockoutEndTime = keychainManager.loadLockoutEndTime()

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