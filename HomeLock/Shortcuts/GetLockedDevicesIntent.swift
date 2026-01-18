//
//  GetLockedDevicesIntent.swift
//  HomeLock
//
//  Created by Claude on 1/18/26.
//

import AppIntents

/// Intent para obtener la lista de dispositivos bloqueados
struct GetLockedDevicesIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Locked Devices"
    static var description = IntentDescription("Get a list of all currently locked devices")

    static var parameterSummary: some ParameterSummary {
        Summary("Get locked devices")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[DeviceEntity]> {
        let homeKitService = HomeKitService.shared
        let lockManager = LockManager.shared

        let lockedDevices = homeKitService.outlets.compactMap { accessory -> DeviceEntity? in
            guard lockManager.isLocked(accessory.uniqueIdentifier) else {
                return nil
            }
            return DeviceEntity(from: accessory, lockManager: lockManager)
        }

        return .result(value: lockedDevices)
    }
}

/// Intent para verificar si un dispositivo específico está bloqueado
struct IsDeviceLockedIntent: AppIntent {
    static var title: LocalizedStringResource = "Is Device Locked"
    static var description = IntentDescription("Check if a specific device is locked")

    @Parameter(title: "Device")
    var device: DeviceEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Is \(\.$device) locked?")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let lockManager = LockManager.shared

        guard let uuid = UUID(uuidString: device.id) else {
            return .result(value: false)
        }

        let isLocked = lockManager.isLocked(uuid)
        return .result(value: isLocked)
    }
}

/// Intent para obtener información del lock de un dispositivo
struct GetLockInfoIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Lock Info"
    static var description = IntentDescription("Get detailed lock information for a device")

    @Parameter(title: "Device")
    var device: DeviceEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Get lock info for \(\.$device)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let lockManager = LockManager.shared

        guard let uuid = UUID(uuidString: device.id),
              let lock = lockManager.getLock(for: uuid) else {
            return .result(value: "Device is not locked")
        }

        let stateText = lock.lockedState ? "ON" : "OFF"

        if let timeRemaining = lock.timeRemaining {
            let minutes = Int(timeRemaining / 60)
            let hours = minutes / 60
            let remainingMinutes = minutes % 60

            let timeText: String
            if hours > 0 {
                timeText = "\(hours)h \(remainingMinutes)m remaining"
            } else {
                timeText = "\(remainingMinutes) minutes remaining"
            }

            return .result(value: "\(lock.accessoryName) locked \(stateText) - \(timeText)")
        } else {
            return .result(value: "\(lock.accessoryName) locked \(stateText) indefinitely")
        }
    }
}
