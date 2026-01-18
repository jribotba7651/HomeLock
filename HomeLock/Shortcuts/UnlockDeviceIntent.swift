//
//  UnlockDeviceIntent.swift
//  HomeLock
//
//  Created by Claude on 1/18/26.
//

import AppIntents

/// Intent para desbloquear un dispositivo desde Shortcuts
/// Requiere abrir la app para autenticación por seguridad
struct UnlockDeviceIntent: AppIntent {
    static var title: LocalizedStringResource = "Unlock Device"
    static var description = IntentDescription("Unlock a locked HomeKit device (requires authentication)")

    /// Requiere abrir la app para autenticación
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Device")
    var device: DeviceEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Unlock \(\.$device)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let lockManager = LockManager.shared

        guard let uuid = UUID(uuidString: device.id) else {
            throw UnlockDeviceError.deviceNotFound
        }

        // Verificar si está bloqueado
        guard lockManager.isLocked(uuid) else {
            throw UnlockDeviceError.notLocked
        }

        // Obtener el nombre antes de desbloquear
        let deviceName = lockManager.getLock(for: uuid)?.accessoryName ?? device.name

        // Desbloquear
        await lockManager.removeLock(for: uuid)

        return .result(value: "\(deviceName) has been unlocked")
    }
}

/// Intent para desbloquear todos los dispositivos
struct UnlockAllDevicesIntent: AppIntent {
    static var title: LocalizedStringResource = "Unlock All Devices"
    static var description = IntentDescription("Unlock all locked devices (requires authentication)")

    /// Requiere abrir la app para autenticación
    static var openAppWhenRun: Bool = true

    static var parameterSummary: some ParameterSummary {
        Summary("Unlock all devices")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let lockManager = LockManager.shared

        let lockedDevices = Array(lockManager.locks.keys)

        if lockedDevices.isEmpty {
            return .result(value: "No devices are currently locked")
        }

        var unlockedCount = 0
        for accessoryID in lockedDevices {
            await lockManager.removeLock(for: accessoryID)
            unlockedCount += 1
        }

        let deviceText = unlockedCount == 1 ? "device" : "devices"
        return .result(value: "Unlocked \(unlockedCount) \(deviceText)")
    }
}

enum UnlockDeviceError: Error, CustomLocalizedStringResourceConvertible {
    case deviceNotFound
    case notLocked

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .deviceNotFound:
            return "Device not found"
        case .notLocked:
            return "Device is not locked"
        }
    }
}
