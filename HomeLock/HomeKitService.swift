//
//  HomeKitService.swift
//  HomeLock
//
//  Created by Juan C. Ribot on 1/4/26.
//

import Foundation
import HomeKit
import Combine

@MainActor
class HomeKitService: NSObject, ObservableObject {
    @Published var homes: [HMHome] = []
    @Published var accessories: [HMAccessory] = []
    @Published var outlets: [HMAccessory] = []
    @Published var isAuthorized = false
    @Published var errorMessage: String?

    private var homeManager: HMHomeManager?

    override init() {
        super.init()
    }

    func requestAuthorization() {
        homeManager = HMHomeManager()
        homeManager?.delegate = self
    }

    /// Filtra accesorios que tienen servicios de tipo outlet o switch
    private func filterOutlets(from accessories: [HMAccessory]) -> [HMAccessory] {
        accessories.filter { accessory in
            accessory.services.contains { service in
                service.serviceType == HMServiceTypeOutlet ||
                service.serviceType == HMServiceTypeSwitch ||
                service.serviceType == HMServiceTypeLightbulb
            }
        }
    }

    /// Obtiene el servicio controlable (outlet/switch/light) de un accesorio
    func getControllableService(for accessory: HMAccessory) -> HMService? {
        accessory.services.first { service in
            service.serviceType == HMServiceTypeOutlet ||
            service.serviceType == HMServiceTypeSwitch ||
            service.serviceType == HMServiceTypeLightbulb
        }
    }

    /// Obtiene la característica "Power State" de un servicio
    func getPowerStateCharacteristic(for service: HMService) -> HMCharacteristic? {
        service.characteristics.first { $0.characteristicType == HMCharacteristicTypePowerState }
    }

    /// Lee el estado actual (on/off) de un accesorio
    func isAccessoryOn(_ accessory: HMAccessory) async -> Bool? {
        guard let service = getControllableService(for: accessory),
              let powerState = getPowerStateCharacteristic(for: service) else {
            return nil
        }

        do {
            try await powerState.readValue()
            return powerState.value as? Bool
        } catch {
            print("Error reading power state: \(error)")
            return nil
        }
    }

    /// Cambia el estado de un accesorio
    func setAccessoryPower(_ accessory: HMAccessory, on: Bool) async throws {
        guard let service = getControllableService(for: accessory),
              let powerState = getPowerStateCharacteristic(for: service) else {
            throw HomeKitError.serviceNotFound
        }

        try await powerState.writeValue(on)
    }

    // MARK: - Lock Trigger Management

    /// Obtiene el home al que pertenece un accesorio
    func getHome(for accessory: HMAccessory) -> HMHome? {
        homes.first { $0.accessories.contains(where: { $0.uniqueIdentifier == accessory.uniqueIdentifier }) }
    }

    /// Crea un HMEventTrigger que revierte el estado del dispositivo cuando cambia
    /// - Parameters:
    ///   - accessory: El accesorio a bloquear
    ///   - lockedState: El estado al que debe mantenerse (true = on, false = off)
    /// - Returns: El UUID del trigger creado
    func createLockTrigger(for accessory: HMAccessory, lockedState: Bool) async throws -> UUID {
        guard let home = getHome(for: accessory) else {
            throw HomeKitError.homeNotFound
        }

        guard let service = getControllableService(for: accessory),
              let powerState = getPowerStateCharacteristic(for: service) else {
            throw HomeKitError.serviceNotFound
        }

        let triggerName = "HomeLock_\(accessory.uniqueIdentifier.uuidString)"

        // Eliminar trigger existente si hay uno
        if let existingTrigger = home.triggers.first(where: { $0.name == triggerName }) {
            try await home.removeTrigger(existingTrigger)
        }

        // Crear el evento: cuando PowerState cambia al estado opuesto al bloqueado
        let unwantedState = !lockedState
        let event = HMCharacteristicEvent(characteristic: powerState, triggerValue: unwantedState as NSCopying)

        // Crear la acción: revertir al estado bloqueado
        let actionSet = try await createRevertActionSet(home: home, characteristic: powerState, targetState: lockedState, accessoryName: accessory.name)

        // Crear el trigger con el evento y la acción
        let trigger = HMEventTrigger(name: triggerName, events: [event], predicate: nil)

        try await home.addTrigger(trigger)
        try await trigger.addActionSet(actionSet)
        try await trigger.enable(true)

        print("HomeLock: Trigger creado para \(accessory.name), mantener \(lockedState ? "ON" : "OFF")")

        return trigger.uniqueIdentifier
    }

    /// Crea un ActionSet que revierte el estado del dispositivo
    private func createRevertActionSet(home: HMHome, characteristic: HMCharacteristic, targetState: Bool, accessoryName: String) async throws -> HMActionSet {
        let actionSetName = "HomeLock_Revert_\(characteristic.uniqueIdentifier.uuidString)"

        // Eliminar action set existente si hay uno
        if let existing = home.actionSets.first(where: { $0.name == actionSetName }) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                home.removeActionSet(existing) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        }

        // Crear nuevo action set
        let actionSet: HMActionSet = try await withCheckedThrowingContinuation { continuation in
            home.addActionSet(withName: actionSetName) { actionSet, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let actionSet {
                    continuation.resume(returning: actionSet)
                } else {
                    continuation.resume(throwing: HomeKitError.triggerCreationFailed)
                }
            }
        }

        // Crear la acción que establece el estado
        let action = HMCharacteristicWriteAction(characteristic: characteristic, targetValue: targetState as NSCopying)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            actionSet.addAction(action) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }

        return actionSet
    }

    /// Elimina un trigger de lock por su UUID
    func removeLockTrigger(triggerID: UUID, for accessory: HMAccessory) async throws {
        guard let home = getHome(for: accessory) else {
            throw HomeKitError.homeNotFound
        }

        // Buscar el trigger por UUID
        guard let trigger = home.triggers.first(where: { $0.uniqueIdentifier == triggerID }) else {
            print("HomeLock: Trigger no encontrado, puede que ya haya sido eliminado")
            return
        }

        // Eliminar action sets asociados
        if let eventTrigger = trigger as? HMEventTrigger {
            for actionSet in eventTrigger.actionSets {
                if actionSet.name.hasPrefix("HomeLock_Revert_") {
                    try? await home.removeActionSet(actionSet)
                }
            }
        }

        try await home.removeTrigger(trigger)
        print("HomeLock: Trigger eliminado para \(accessory.name)")
    }

    /// Elimina un trigger de lock por nombre del accesorio
    func removeLockTrigger(for accessory: HMAccessory) async throws {
        guard let home = getHome(for: accessory) else {
            throw HomeKitError.homeNotFound
        }

        let triggerName = "HomeLock_\(accessory.uniqueIdentifier.uuidString)"

        guard let trigger = home.triggers.first(where: { $0.name == triggerName }) else {
            return
        }

        // Eliminar action sets asociados
        if let eventTrigger = trigger as? HMEventTrigger {
            for actionSet in eventTrigger.actionSets {
                if actionSet.name.hasPrefix("HomeLock_Revert_") {
                    try? await home.removeActionSet(actionSet)
                }
            }
        }

        try await home.removeTrigger(trigger)
        print("HomeLock: Trigger eliminado para \(accessory.name)")
    }
}

// MARK: - HMHomeManagerDelegate
extension HomeKitService: HMHomeManagerDelegate {
    nonisolated func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        Task { @MainActor in
            self.homes = manager.homes
            self.isAuthorized = true

            // Recolectar todos los accesorios de todos los homes
            var allAccessories: [HMAccessory] = []
            for home in manager.homes {
                allAccessories.append(contentsOf: home.accessories)
            }
            self.accessories = allAccessories
            self.outlets = filterOutlets(from: allAccessories)

            print("HomeKit: \(homes.count) homes, \(accessories.count) accessories, \(outlets.count) outlets/switches")
        }
    }
}

// MARK: - Errors
enum HomeKitError: LocalizedError {
    case serviceNotFound
    case characteristicNotFound
    case homeNotFound
    case triggerCreationFailed

    var errorDescription: String? {
        switch self {
        case .serviceNotFound:
            return "No se encontró un servicio controlable en este accesorio"
        case .characteristicNotFound:
            return "No se encontró la característica de encendido"
        case .homeNotFound:
            return "No se encontró el home del accesorio"
        case .triggerCreationFailed:
            return "No se pudo crear el trigger de bloqueo"
        }
    }
}
