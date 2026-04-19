//
//  KeychainManager.swift
//  HomeLock
//
//  Secure storage for the HomeLock PIN and lockout counters.
//
//  Design notes:
//  - The PIN is NEVER stored in clear. We store `salt || PBKDF2_SHA256(pin, salt, 100_000)`
//    as a single blob. On verify we re-derive with the stored salt and compare
//    in constant time. This way a Keychain leak, a jailbreak dump or an
//    iCloud/iTunes backup cannot recover the PIN.
//  - Lockout counters (`failedAttempts`, `lockoutEndTime`) live in Keychain
//    (not UserDefaults) so that uninstall+reinstall does NOT reset them.
//    Otherwise a child could uninstall, reinstall, and brute-force the PIN.
//  - Access class is `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` — matches
//    the parental-control threat model and prevents iCloud Keychain sync
//    leaking the hash to other devices.
//

import Foundation
import Security
import CommonCrypto

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
        guard status == errSecSuccess else { return nil }
        // Antes usábamos `as! Data?` que crashea si SecItem devuelve otro tipo.
        // Usamos cast condicional — si no es Data, devolvemos nil.
        return dataTypeRef as? Data
    }

    func delete(key: String) -> Bool {
        let query = [
            kSecClass as String: kSecClassGenericPassword as String,
            kSecAttrAccount as String: key
        ] as [String: Any]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess
    }

    // MARK: - PIN Management (hashed, not plaintext)

    private let pinHashKey = "HomeLock_PIN_Hash_v2"
    private let legacyPinKey = "HomeLock_PIN" // plaintext — solo se borra si existe
    private let saltLength = 16
    private let hashLength = 32
    private let pbkdf2Rounds: UInt32 = 100_000

    /// Guarda el PIN como `salt(16) || PBKDF2_SHA256(pin, salt, 100k, 32)`.
    func savePIN(_ pin: String) -> Bool {
        guard let pinData = pin.data(using: .utf8) else { return false }
        guard let salt = randomBytes(saltLength) else { return false }
        guard let hash = pbkdf2(password: pinData, salt: salt) else { return false }

        var blob = Data()
        blob.append(salt)
        blob.append(hash)

        let ok = save(key: pinHashKey, data: blob)
        // Si venimos de un build anterior con PIN en claro, lo borramos.
        _ = delete(key: legacyPinKey)
        return ok
    }

    /// Verifica un PIN contra el hash guardado. Constant-time.
    /// - Returns: `true` si coincide, `false` si no o si no hay PIN configurado.
    func verifyPIN(_ pin: String) -> Bool {
        guard let blob = load(key: pinHashKey),
              blob.count == saltLength + hashLength,
              let pinData = pin.data(using: .utf8) else {
            return false
        }
        let salt = blob.prefix(saltLength)
        let storedHash = blob.suffix(hashLength)
        guard let candidate = pbkdf2(password: pinData, salt: Data(salt)) else {
            return false
        }
        return constantTimeEquals(Data(storedHash), candidate)
    }

    /// `loadPIN()` ya no existe — es imposible recuperar el PIN en claro
    /// por diseño. Usa `verifyPIN(_:)` para comparar.

    func deletePIN() -> Bool {
        _ = delete(key: legacyPinKey) // legacy cleanup
        return delete(key: pinHashKey)
    }

    func isPINSet() -> Bool {
        return load(key: pinHashKey) != nil
    }

    // MARK: - Lockout State (persisted in Keychain, not UserDefaults)

    private let failedAttemptsKey = "HomeLock_FailedAttempts"
    private let lockoutEndTimeKey = "HomeLock_LockoutEndTime"

    func saveFailedAttempts(_ count: Int) {
        var value = Int64(count)
        let data = Data(bytes: &value, count: MemoryLayout<Int64>.size)
        _ = save(key: failedAttemptsKey, data: data)
    }

    func loadFailedAttempts() -> Int {
        guard let data = load(key: failedAttemptsKey),
              data.count == MemoryLayout<Int64>.size else { return 0 }
        let value = data.withUnsafeBytes { $0.load(as: Int64.self) }
        return Int(value)
    }

    func saveLockoutEndTime(_ date: Date?) {
        guard let date else {
            _ = delete(key: lockoutEndTimeKey)
            return
        }
        var value = date.timeIntervalSince1970
        let data = Data(bytes: &value, count: MemoryLayout<TimeInterval>.size)
        _ = save(key: lockoutEndTimeKey, data: data)
    }

    func loadLockoutEndTime() -> Date? {
        guard let data = load(key: lockoutEndTimeKey),
              data.count == MemoryLayout<TimeInterval>.size else { return nil }
        let value = data.withUnsafeBytes { $0.load(as: TimeInterval.self) }
        return Date(timeIntervalSince1970: value)
    }

    func clearLockoutState() {
        _ = delete(key: failedAttemptsKey)
        _ = delete(key: lockoutEndTimeKey)
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

    // MARK: - Biometric Domain State
    //
    // Snapshot de la base biométrica del device para detectar que alguien
    // añada una huella/cara nueva después del setup. Si cambia → forzamos PIN.
    // Esto previene el ataque "niño añade su Face ID al device y desbloquea
    // HomeLock con ella".
    //
    // Formato del blob guardado: `version(1B) || hash(N)`.
    //  - version == 1 → `LAContext.evaluatedPolicyDomainState` (iOS ≤17).
    //  - version == 2 → `LAContext.domainState.biometry.stateHash` (iOS 18+).
    //
    // Apple deprecó la API vieja en iOS 18 y cambió la representación. Si el
    // usuario actualiza de iOS 17 → iOS 18 el formato cambia, así que el
    // caller debe tratar "version mismatch" como migración (re-capturar),
    // no como manipulación.

    private let biometricDomainStateKey = "HomeLock_BiometricDomainState"

    func saveBiometricDomainState(_ state: Data, version: UInt8) -> Bool {
        var blob = Data([version])
        blob.append(state)
        return save(key: biometricDomainStateKey, data: blob)
    }

    func loadBiometricDomainState() -> (version: UInt8, state: Data)? {
        guard let blob = load(key: biometricDomainStateKey),
              let first = blob.first else { return nil }
        return (first, blob.dropFirst())
    }

    func deleteBiometricDomainState() -> Bool {
        return delete(key: biometricDomainStateKey)
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

    // MARK: - Crypto helpers

    /// PBKDF2-HMAC-SHA256.
    private func pbkdf2(password: Data, salt: Data) -> Data? {
        var derived = Data(count: hashLength)
        let result = derived.withUnsafeMutableBytes { (derivedBytes: UnsafeMutableRawBufferPointer) -> Int32 in
            salt.withUnsafeBytes { (saltBytes: UnsafeRawBufferPointer) -> Int32 in
                password.withUnsafeBytes { (passwordBytes: UnsafeRawBufferPointer) -> Int32 in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                        password.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        pbkdf2Rounds,
                        derivedBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        hashLength
                    )
                }
            }
        }
        return result == kCCSuccess ? derived : nil
    }

    private func randomBytes(_ count: Int) -> Data? {
        var bytes = Data(count: count)
        let result = bytes.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, count, ptr.baseAddress!)
        }
        return result == errSecSuccess ? bytes : nil
    }

    /// Constant-time `Data` comparison — previene timing attacks.
    private func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<lhs.count {
            diff |= lhs[i] ^ rhs[i]
        }
        return diff == 0
    }
}
