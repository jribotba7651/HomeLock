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
            guard success else {
                return .failure(.authenticationFailed)
            }

            // Detecta si alguien añadió/borró huellas o caras en el device
            // después del setup. El hash solo es válido tras `evaluatePolicy`
            // en el mismo LAContext.
            let current = Self.currentBiometryStateHash(from: context)
            let saved = KeychainManager.shared.loadBiometricDomainState()

            if let saved, let current {
                if saved.version != current.version {
                    // Formato cambió (update iOS 17→18). No es manipulación —
                    // re-capturamos y seguimos.
                    _ = KeychainManager.shared.saveBiometricDomainState(
                        current.state, version: current.version)
                } else if saved.state != current.state {
                    return .failure(.biometricDatabaseChanged)
                }
            } else if saved == nil, let current {
                // Build anterior no guardaba snapshot. Capturamos ahora para
                // no bloquear a usuarios existentes.
                _ = KeychainManager.shared.saveBiometricDomainState(
                    current.state, version: current.version)
            }

            return .success(true)
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
        if !enabled {
            // Snapshot fresco la próxima vez que activen biometría.
            _ = KeychainManager.shared.deleteBiometricDomainState()
        }
    }

    private func loadBiometricSettings() {
        isBiometricEnabled = KeychainManager.shared.isBiometricEnabled()
    }

    // MARK: - Biometry State Snapshot

    /// Hash opaco del estado actual de la base biométrica del device. Cambia
    /// si se añade/elimina una huella o cara. Apple deprecó la API vieja en
    /// iOS 18, así que elegimos en runtime y guardamos el formato con un
    /// byte de versión (1 = API vieja, 2 = API nueva).
    ///
    /// Debe llamarse **después** de un `evaluatePolicy` exitoso en el mismo
    /// `LAContext` — antes no está poblado.
    private static func currentBiometryStateHash(from context: LAContext) -> (version: UInt8, state: Data)? {
        if #available(iOS 18.0, macOS 15.0, *) {
            guard let hash = context.domainState.biometry.stateHash else { return nil }
            return (2, hash)
        } else {
            guard let state = context.evaluatedPolicyDomainState else { return nil }
            return (1, state)
        }
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
                // Snapshot de la base biométrica actual para detectar cambios
                // futuros (niño añade su cara al device → forzamos PIN).
                if let snapshot = Self.currentBiometryStateHash(from: context) {
                    _ = KeychainManager.shared.saveBiometricDomainState(
                        snapshot.state, version: snapshot.version)
                }
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
    case biometricDatabaseChanged
    case userCanceled
    case userFallback
    case authenticationFailed
    case pinIncorrect
    case pinMismatch
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
        case .biometricDatabaseChanged:
            return "Biometric data has changed since setup. Please enter your PIN to continue."
        case .userCanceled:
            return "Authentication was canceled by user."
        case .userFallback:
            return "User chose to use fallback authentication method."
        case .authenticationFailed:
            return "Authentication failed. Please try again."
        case .pinIncorrect:
            return "Incorrect PIN. Please try again."
        case .pinMismatch:
            return "The PINs do not match. Please try again."
        case .pinLockout:
            return "Too many failed attempts. Please try again in 5 minutes."
        case .invalidPin:
            return "Invalid PIN format. PIN must be 6 digits."
        }
    }
}