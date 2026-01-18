//
//  LockDeviceIntent.swift
//  HomeLock
//
//  Created by Claude on 1/18/26.
//

import AppIntents
import HomeKit

/// Intent para bloquear un dispositivo desde Shortcuts
struct LockDeviceIntent: AppIntent {
    static var title: LocalizedStringResource = "Lock Device"
    static var description = IntentDescription("Lock a HomeKit device in its current state")

    @Parameter(title: "Device")
    var device: DeviceEntity

    @Parameter(title: "Duration", default: .oneHour)
    var duration: LockDuration

    @Parameter(title: "Lock State", description: "Lock in ON or OFF state", default: false)
    var lockInOnState: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Lock \(\.$device) for \(\.$duration)") {
            \.$lockInOnState
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let homeKitService = HomeKitService.shared
        let lockManager = LockManager.shared

        // Buscar el accesorio
        guard let uuid = UUID(uuidString: device.id),
              let accessory = homeKitService.outlets.first(where: { $0.uniqueIdentifier == uuid }) else {
            throw LockDeviceError.deviceNotFound
        }

        // Verificar si ya está bloqueado
        if lockManager.isLocked(uuid) {
            throw LockDeviceError.alreadyLocked
        }

        // Primero establecer el estado deseado
        do {
            try await homeKitService.setAccessoryPower(accessory, on: lockInOnState)
        } catch {
            throw LockDeviceError.failedToSetState
        }

        // Crear el trigger de bloqueo
        do {
            let triggerID = try await homeKitService.createLockTrigger(for: accessory, lockedState: lockInOnState)

            // Agregar el lock al manager
            lockManager.addLock(
                accessoryID: uuid,
                accessoryName: accessory.name,
                triggerID: triggerID,
                lockedState: lockInOnState,
                duration: duration.timeInterval
            )

            let stateText = lockInOnState ? "ON" : "OFF"
            let durationText = duration == .indefinite ? "indefinitely" : "for \(duration.caseDisplayRepresentations[duration]?.title ?? "")"

            return .result(value: "\(accessory.name) locked \(stateText) \(durationText)")
        } catch {
            throw LockDeviceError.failedToCreateLock
        }
    }
}

enum LockDeviceError: Error, CustomLocalizedStringResourceConvertible {
    case deviceNotFound
    case alreadyLocked
    case failedToSetState
    case failedToCreateLock

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .deviceNotFound:
            return "Device not found"
        case .alreadyLocked:
            return "Device is already locked"
        case .failedToSetState:
            return "Failed to set device state"
        case .failedToCreateLock:
            return "Failed to create lock"
        }
    }
}
