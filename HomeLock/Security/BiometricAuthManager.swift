//
//  BiometricAuthManager.swift
//  HomeLock
//
//  Created by HomeLock on [Date]
//  Copyright © [Year] HomeLock. All rights reserved.
//

import Foundation
import LocalAuthentication
import Combine

class BiometricAuthManager: ObservableObject {
    static let shared = BiometricAuthManager()

    @Published var biometricType: LABiometryType = .none
    @Published var isBiometricAvailable: Bool = false
    @Published var isBiometricEnabled: Bool = false

    private let context = LAContext()

    private init() {
        checkBiometricAvailability()
        loadBiometricSettings()
    }

    // MARK: - Biometric Availability

    func checkBiometricAvailability() {
        var error: NSError?

        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            isBiometricAvailable = true
            biometricType = context.biometryType
        } else {
            isBiometricAvailable = false
            biometricType = .none
        }
    }

    var biometricTypeString: String {
        switch biometricType {
        case .faceID:
            return "Face ID"
        case .touchID:
            return "Touch ID"
        case .opticID:
            return "Optic ID"
        default:
            return "Biometric Authentication"
        }
    }

    // MARK: - Authentication

    func authenticateWithBiometrics() async -> Result<Bool, AuthenticationError> {
        guard isBiometricAvailable else {
            return .failure(.biometricUnavailable)
        }

        guard isBiometricEnabled else {
            return .failure(.biometricNotEnabled)
        }

        let context = LAContext()
        let reason = "Authenticate to access HomeLock"

        do {
            let success = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
            return .success(success)
        } catch let error as LAError {
            switch error.code {
            case .userCancel:
                return .failure(.userCanceled)
            case .userFallback:
                return .failure(.userFallback)
            case .biometryNotAvailable:
                return .failure(.biometricUnavailable)
            case .biometryNotEnrolled:
                return .failure(.biometricNotEnrolled)
            case .biometryLockout:
                return .failure(.biometricLockout)
            default:
                return .failure(.authenticationFailed)
            }
        } catch {
            return .failure(.authenticationFailed)
        }
    }

    // MARK: - Settings Management

    func setBiometricEnabled(_ enabled: Bool) {
        isBiometricEnabled = enabled
        _ = KeychainManager.shared.setBiometricEnabled(enabled)
    }

    private func loadBiometricSettings() {
        isBiometricEnabled = KeychainManager.shared.isBiometricEnabled()
    }

    // MARK: - Enrollment Check

    func requestBiometricSetup() async -> Result<Bool, AuthenticationError> {
        guard isBiometricAvailable else {
            return .failure(.biometricUnavailable)
        }

        let context = LAContext()
        let reason = "Enable \(biometricTypeString) for quick and secure access to HomeLock"

        do {
            let success = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
            if success {
                setBiometricEnabled(true)
                return .success(true)
            } else {
                return .failure(.authenticationFailed)
            }
        } catch let error as LAError {
            switch error.code {
            case .userCancel:
                return .failure(.userCanceled)
            case .biometryNotAvailable:
                return .failure(.biometricUnavailable)
            case .biometryNotEnrolled:
                return .failure(.biometricNotEnrolled)
            default:
                return .failure(.authenticationFailed)
            }
        } catch {
            return .failure(.authenticationFailed)
        }
    }
}

// MARK: - Authentication Error

enum AuthenticationError: LocalizedError {
    case biometricUnavailable
    case biometricNotEnabled
    case biometricNotEnrolled
    case biometricLockout
    case userCanceled
    case userFallback
    case authenticationFailed
    case pinIncorrect
    case pinLockout
    case invalidPin

    var errorDescription: String? {
        switch self {
        case .biometricUnavailable:
            return "Biometric authentication is not available on this device."
        case .biometricNotEnabled:
            return "Biometric authentication is not enabled. Please enable it in settings."
        case .biometricNotEnrolled:
            return "No biometric data is enrolled. Please set up biometric authentication in device settings."
        case .biometricLockout:
            return "Biometric authentication is locked. Please use your passcode."
        case .userCanceled:
            return "Authentication was canceled by user."
        case .userFallback:
            return "User chose to use fallback authentication method."
        case .authenticationFailed:
            return "Authentication failed. Please try again."
        case .pinIncorrect:
            return "Incorrect PIN. Please try again."
        case .pinLockout:
            return "Too many failed attempts. Please try again in 5 minutes."
        case .invalidPin:
            return "Invalid PIN format. PIN must be 6 digits."
        }
    }
}