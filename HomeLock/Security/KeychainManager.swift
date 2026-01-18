//
//  KeychainManager.swift
//  HomeLock
//
//  Created by HomeLock on [Date]
//  Copyright © [Year] HomeLock. All rights reserved.
//

import Foundation
import Security

class KeychainManager {
    static let shared = KeychainManager()

    private init() {}

    // MARK: - Generic Keychain Operations

    func save(key: String, data: Data) -> Bool {
        let query = [
            kSecClass as String: kSecClassGenericPassword as String,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ] as [String: Any]

        SecItemDelete(query as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    func load(key: String) -> Data? {
        let query = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: kCFBooleanTrue!,
            kSecMatchLimit as String: kSecMatchLimitOne
        ] as [String: Any]

        var dataTypeRef: AnyObject? = nil

        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
        if status == errSecSuccess {
            return dataTypeRef as! Data?
        } else {
            return nil
        }
    }

    func delete(key: String) -> Bool {
        let query = [
            kSecClass as String: kSecClassGenericPassword as String,
            kSecAttrAccount as String: key
        ] as [String: Any]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess
    }

    // MARK: - PIN Management

    private let pinKey = "HomeLock_PIN"

    func savePIN(_ pin: String) -> Bool {
        guard let data = pin.data(using: .utf8) else { return false }
        return save(key: pinKey, data: data)
    }

    func loadPIN() -> String? {
        guard let data = load(key: pinKey),
              let pin = String(data: data, encoding: .utf8) else { return nil }
        return pin
    }

    func deletePIN() -> Bool {
        return delete(key: pinKey)
    }

    func isPINSet() -> Bool {
        return loadPIN() != nil
    }

    // MARK: - Biometric Settings

    private let biometricEnabledKey = "HomeLock_BiometricEnabled"

    func setBiometricEnabled(_ enabled: Bool) -> Bool {
        let data = Data([enabled ? 1 : 0])
        return save(key: biometricEnabledKey, data: data)
    }

    func isBiometricEnabled() -> Bool {
        guard let data = load(key: biometricEnabledKey),
              let byte = data.first else { return false }
        return byte == 1
    }

    // MARK: - Security Token for Secure Enclave

    private let securityTokenKey = "HomeLock_SecurityToken"

    func saveSecurityToken(_ token: Data) -> Bool {
        return save(key: securityTokenKey, data: token)
    }

    func loadSecurityToken() -> Data? {
        return load(key: securityTokenKey)
    }

    func deleteSecurityToken() -> Bool {
        return delete(key: securityTokenKey)
    }

    // MARK: - App Lock State

    private let appLockStateKey = "HomeLock_AppLockState"

    func setAppLocked(_ locked: Bool) -> Bool {
        let data = Data([locked ? 1 : 0])
        return save(key: appLockStateKey, data: data)
    }

    func isAppLocked() -> Bool {
        guard let data = load(key: appLockStateKey),
              let byte = data.first else { return true } // Default to locked
        return byte == 1
    }
}