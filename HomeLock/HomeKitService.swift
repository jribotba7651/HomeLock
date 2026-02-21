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
    static let shared = HomeKitService()
    
    @Published var homes: [HMHome] = []
    @Published var accessories: [HMAccessory] = []
    @Published var outlets: [HMAccessory] = []
    @Published var isAuthorized = false
    @Published var errorMessage: String?

    /// Detecta si un accesorio es de la marca Lutron
    func isLutronDevice(_ accessory: HMAccessory) -> Bool {
        let manufacturer = accessory.manufacturer?.lowercased() ?? ""
        return manufacturer.contains("lutron")
    }

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
        } catch let error as NSError {
            if error.domain == "HMErrorDomain" && error.code == 80 {
                // Expected: Background access not allowed
                return nil
            } else if error.domain == "HMErrorDomain" && error.code == 74 {
                // Expected: Device doesn't support reading power state
                return nil
            } else {
                print("Error reading power state: \(error)")
                return nil
            }
        }
    }

    /// Cambia el estado de un accesorio
    func setAccessoryPower(_ accessory: HMAccessory, on: Bool) async throws {
        guard let service = getControllableService(for: accessory),
              let powerState = getPowerStateCharacteristic(for: service) else {
            throw HomeKitError.serviceNotFound
        }

        do {
            try await powerState.writeValue(on)
        } catch let error as NSError where error.domain == "HMErrorDomain" && error.code == 74 {
            // Code 74 can be transient during concurrent HomeKit operations — retry after delay
            print("⚠️ [HomeLock] Write failed (Code 74) for \(accessory.name), retrying...")
            try await Task.sleep(nanoseconds: 1_000_000_000)
            do {
                try await powerState.writeValue(on)
            } catch let retryError as NSError where retryError.domain == "HMErrorDomain" && retryError.code == 74 {
                // Retry also failed — try Brightness fallback for dimmers
                guard let brightness = service.characteristics.first(where: {
                    $0.characteristicType == HMCharacteristicTypeBrightness
                }) else {
                    throw retryError
                }
                let brightnessValue = on ? 100 : 0
                try await brightness.writeValue(brightnessValue)
                print("🔒 [HomeLock] Fallback: Brightness set to \(brightnessValue) for \(accessory.name)")
            }
        }
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
        print("🔒 [HomeLock] Creando trigger para \(accessory.name) -> \(lockedState ? "ON" : "OFF")")

        guard let home = getHome(for: accessory) else {
            throw HomeKitError.homeNotFound
        }

        guard let service = getControllableService(for: accessory) else {
            throw HomeKitError.serviceNotFound
        }

        guard let powerState = getPowerStateCharacteristic(for: service) else {
            throw HomeKitError.serviceNotFound
        }

        let triggerName = "HomeLock_\(accessory.uniqueIdentifier.uuidString)"
        let actionSetPrefix = "HomeLock_Revert_"

        // Only run mass cleanup if there's actually a leak (>50 total or >20 HomeLock triggers)
        let homeLockTriggerCount = home.triggers.filter { $0.name.hasPrefix("HomeLock_") }.count
        if home.triggers.count > 50 || homeLockTriggerCount > 20 {
            print("🚨 [HomeLock] Trigger leak detected (\(homeLockTriggerCount)), cleaning up...")
            let homeLockTriggers = home.triggers.filter { $0.name.hasPrefix("HomeLock_") }
            for trigger in homeLockTriggers {
                if let eventTrigger = trigger as? HMEventTrigger {
                    for actionSet in eventTrigger.actionSets where actionSet.name.hasPrefix("HomeLock_") {
                        try? await home.removeActionSet(actionSet)
                    }
                }
                try? await home.removeTrigger(trigger)
            }
            for actionSet in home.actionSets.filter({ $0.name.hasPrefix("HomeLock_") }) {
                try? await home.removeActionSet(actionSet)
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        // Remove existing triggers for THIS device only
        let triggersToRemove = home.triggers.filter { $0.name == triggerName }
        for trigger in triggersToRemove {
            if let eventTrigger = trigger as? HMEventTrigger {
                for actionSet in eventTrigger.actionSets where actionSet.name.hasPrefix(actionSetPrefix) {
                    try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        home.removeActionSet(actionSet) { error in
                            continuation.resume()
                        }
                    }
                }
            }
            try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                home.removeTrigger(trigger) { error in
                    continuation.resume()
                }
            }
        }

        // Clean orphaned action sets for this device
        for actionSet in home.actionSets.filter({ $0.name.hasPrefix(actionSetPrefix) }) {
            if let action = actionSet.actions.first as? HMCharacteristicWriteAction<NSCopying>,
               action.characteristic.service?.accessory?.uniqueIdentifier == accessory.uniqueIdentifier {
                try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    home.removeActionSet(actionSet) { error in
                        continuation.resume()
                    }
                }
            }
        }

        // Stabilization pause — longer for Lutron bridges
        let stabilizationDelay: UInt64 = isLutronDevice(accessory) ? 1_000_000_000 : 500_000_000
        try? await Task.sleep(nanoseconds: stabilizationDelay)

        // Create the event: fires when PowerState changes to the unwanted state
        let unwantedState = !lockedState
        let event = HMCharacteristicEvent(characteristic: powerState, triggerValue: unwantedState as NSCopying)

        // Create the action set to revert to locked state
        let actionSet = try await createRevertActionSet(home: home, characteristic: powerState, targetState: lockedState, accessoryName: accessory.name)

        // Create and configure trigger
        let trigger = HMEventTrigger(name: triggerName, events: [event], predicate: nil)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            home.addTrigger(trigger) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            trigger.addActionSet(actionSet) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            trigger.enable(true) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }

        print("🔒 [HomeLock] Trigger creado para \(accessory.name) (UUID: \(trigger.uniqueIdentifier))")

        return trigger.uniqueIdentifier
    }


    /// Crea un ActionSet que revierte el estado del dispositivo
    private func createRevertActionSet(home: HMHome, characteristic: HMCharacteristic, targetState: Bool, accessoryName: String) async throws -> HMActionSet {
        let actionSetName = "HomeLock_Revert_\(characteristic.uniqueIdentifier.uuidString)"
        print("🔧 [HomeLock] Creando ActionSet: \(actionSetName)")
        print("🔧 [HomeLock] Target state para revertir: \(targetState)")

        // Eliminar action set existente si hay uno
        if let existing = home.actionSets.first(where: { $0.name == actionSetName }) {
            print("🔧 [HomeLock] Eliminando ActionSet existente...")
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                home.removeActionSet(existing) { error in
                    if let error {
                        print("❌ [HomeLock] Error eliminando ActionSet: \(error)")
                        continuation.resume(throwing: error)
                    } else {
                        print("✅ [HomeLock] ActionSet existente eliminado")
                        continuation.resume()
                    }
                }
            }
        }

        // Crear nuevo action set
        print("🔧 [HomeLock] Creando nuevo ActionSet...")
        let actionSet: HMActionSet = try await withCheckedThrowingContinuation { continuation in
            home.addActionSet(withName: actionSetName) { actionSet, error in
                if let error {
                    print("❌ [HomeLock] Error creando ActionSet: \(error)")
                    continuation.resume(throwing: error)
                } else if let actionSet {
                    print("✅ [HomeLock] ActionSet creado: \(actionSet.uniqueIdentifier)")
                    continuation.resume(returning: actionSet)
                } else {
                    print("❌ [HomeLock] ActionSet es nil sin error")
                    continuation.resume(throwing: HomeKitError.triggerCreationFailed)
                }
            }
        }

        // Crear la acción que establece el estado
        print("🔧 [HomeLock] Creando HMCharacteristicWriteAction...")
        print("🔧 [HomeLock] Characteristic UUID: \(characteristic.uniqueIdentifier)")
        print("🔧 [HomeLock] Target value: \(targetState)")

        let action = HMCharacteristicWriteAction(characteristic: characteristic, targetValue: targetState as NSCopying)
        print("🔧 [HomeLock] Action creada, agregando al ActionSet...")

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            actionSet.addAction(action) { error in
                if let error {
                    print("❌ [HomeLock] Error agregando action: \(error)")
                    continuation.resume(throwing: error)
                } else {
                    print("✅ [HomeLock] Action agregada al ActionSet")
                    continuation.resume()
                }
            }
        }

        print("🔧 [HomeLock] ActionSet listo con \(actionSet.actions.count) actions")
        return actionSet
    }

    /// Elimina un trigger de lock por su UUID
    func removeLockTrigger(triggerID: UUID, for accessory: HMAccessory) async throws {
        guard let home = getHome(for: accessory) else {
            throw HomeKitError.homeNotFound
        }

        // Buscar el trigger por UUID
        guard let trigger = home.triggers.first(where: { $0.uniqueIdentifier == triggerID }) else {
            print("🧹 [HomeLock] Trigger no encontrado, puede que ya haya sido eliminado")
            return
        }

        print("🧹 [HomeLock] Eliminando trigger: \(trigger.name)")

        // Eliminar action sets asociados primero
        if let eventTrigger = trigger as? HMEventTrigger {
            for actionSet in eventTrigger.actionSets {
                if actionSet.name.hasPrefix("HomeLock_Revert_") {
                    print("🧹 [HomeLock] Eliminando ActionSet: \(actionSet.name)")
                    try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        home.removeActionSet(actionSet) { error in
                            if let error {
                                print("⚠️ [HomeLock] Error eliminando ActionSet: \(error.localizedDescription)")
                            }
                            continuation.resume()
                        }
                    }
                }
            }
        }

        // Eliminar el trigger
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            home.removeTrigger(trigger) { error in
                if let error {
                    print("❌ [HomeLock] Error eliminando trigger: \(error)")
                    continuation.resume(throwing: error)
                } else {
                    print("✅ [HomeLock] Trigger eliminado para \(accessory.name)")
                    continuation.resume()
                }
            }
        }

        // Delay extra para Lutron para dejar que el bridge procese la eliminación
        if isLutronDevice(accessory) {
            try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
        }
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

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            home.removeTrigger(trigger) { error in
                if let error {
                    print("❌ [HomeLock] Error eliminando trigger: \(error)")
                    continuation.resume(throwing: error)
                } else {
                    print("✅ [HomeLock] Trigger eliminado para \(accessory.name)")
                    continuation.resume()
                }
            }
        }

        // Delay extra para Lutron
        if isLutronDevice(accessory) {
            try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
        }
    }

    /// Elimina TODAS las automatizaciones de HomeLock (triggers y action sets que empiezan con "HomeLock_")
    /// - Returns: Número de elementos eliminados (triggers + action sets)
    func removeAllHomeLockAutomations() async -> Int {
        var removedCount = 0

        for home in homes {
            print("🧹 [HomeLock] Limpiando home: \(home.name)")

            // 1. Eliminar todos los triggers que empiezan con "HomeLock_"
            let homeLockTriggers = home.triggers.filter { $0.name.hasPrefix("HomeLock_") }
            print("🧹 [HomeLock] Encontrados \(homeLockTriggers.count) triggers HomeLock_")

            for trigger in homeLockTriggers {
                do {
                    // Primero eliminar action sets asociados al trigger
                    if let eventTrigger = trigger as? HMEventTrigger {
                        for actionSet in eventTrigger.actionSets where actionSet.name.hasPrefix("HomeLock_") {
                            try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                                home.removeActionSet(actionSet) { error in
                                    if let error {
                                        print("⚠️ [HomeLock] Error eliminando ActionSet asociado: \(error.localizedDescription)")
                                    }
                                    continuation.resume()
                                }
                            }
                        }
                    }

                    // Eliminar el trigger
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        home.removeTrigger(trigger) { error in
                            if let error {
                                print("❌ [HomeLock] Error eliminando trigger \(trigger.name): \(error.localizedDescription)")
                                continuation.resume(throwing: error)
                            } else {
                                print("✅ [HomeLock] Trigger eliminado: \(trigger.name)")
                                continuation.resume()
                            }
                        }
                    }
                    removedCount += 1
                } catch {
                    print("⚠️ [HomeLock] No se pudo eliminar trigger: \(error.localizedDescription)")
                }
            }

            // 2. Eliminar action sets huérfanos que empiezan con "HomeLock_"
            let homeLockActionSets = home.actionSets.filter { $0.name.hasPrefix("HomeLock_") }
            print("🧹 [HomeLock] Encontrados \(homeLockActionSets.count) ActionSets HomeLock_")

            for actionSet in homeLockActionSets {
                do {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        home.removeActionSet(actionSet) { error in
                            if let error {
                                print("❌ [HomeLock] Error eliminando ActionSet \(actionSet.name): \(error.localizedDescription)")
                                continuation.resume(throwing: error)
                            } else {
                                print("✅ [HomeLock] ActionSet eliminado: \(actionSet.name)")
                                continuation.resume()
                            }
                        }
                    }
                    removedCount += 1
                } catch {
                    print("⚠️ [HomeLock] No se pudo eliminar ActionSet: \(error.localizedDescription)")
                }
            }
        }

        print("🧹 [HomeLock] Limpieza completada. Eliminados: \(removedCount) elementos")
        return removedCount
    }

    /// Cuenta el número de automatizaciones HomeLock existentes
    func countHomeLockAutomations() -> Int {
        var count = 0
        for home in homes {
            count += home.triggers.filter { $0.name.hasPrefix("HomeLock_") }.count
            count += home.actionSets.filter { $0.name.hasPrefix("HomeLock_") }.count
        }
        return count
    }

    // MARK: - Multi-User Sync Support

    /// Estructura para representar un lock detectado desde HomeKit
    struct DetectedLock {
        let accessoryUUID: UUID
        let accessoryName: String
        let triggerUUID: UUID
        let lockedState: Bool
        let isEnabled: Bool
    }

    /// Obtiene todos los triggers de HomeLock activos desde HomeKit
    /// Esto permite sincronizar con locks creados por otros miembros del hogar
    func getAllActiveLockTriggers() -> [DetectedLock] {
        var detectedLocks: [DetectedLock] = []

        for home in homes {
            let homeLockTriggers = home.triggers.filter {
                $0.name.hasPrefix("HomeLock_") && $0.isEnabled
            }

            for trigger in homeLockTriggers {
                guard let eventTrigger = trigger as? HMEventTrigger else { continue }

                // Extraer el UUID del accesorio del nombre del trigger
                // Formato: HomeLock_{accessoryUUID}
                let triggerName = trigger.name
                let uuidString = triggerName.replacingOccurrences(of: "HomeLock_", with: "")
                guard let accessoryUUID = UUID(uuidString: uuidString) else { continue }

                // Buscar el accesorio
                guard let accessory = home.accessories.first(where: { $0.uniqueIdentifier == accessoryUUID }) else { continue }

                // Determinar el estado bloqueado desde el evento del trigger
                var lockedState = true
                if let characteristicEvent = eventTrigger.events.first as? HMCharacteristicEvent<NSCopying> {
                    // El trigger se dispara cuando el estado cambia al valor NO deseado
                    // Por lo tanto, el estado bloqueado es el opuesto
                    if let triggerValue = characteristicEvent.triggerValue as? Bool {
                        lockedState = !triggerValue
                    }
                }

                let detected = DetectedLock(
                    accessoryUUID: accessoryUUID,
                    accessoryName: accessory.name,
                    triggerUUID: trigger.uniqueIdentifier,
                    lockedState: lockedState,
                    isEnabled: trigger.isEnabled
                )

                detectedLocks.append(detected)
                print("🔍 [HomeKit Sync] Trigger detectado: \(accessory.name) -> \(lockedState ? "ON" : "OFF")")
            }
        }

        print("🔍 [HomeKit Sync] Total triggers detectados: \(detectedLocks.count)")
        return detectedLocks
    }

    /// Publisher para notificar cambios en los homes
    @Published var homesLastUpdated: Date = Date()
}

// MARK: - HMHomeManagerDelegate
extension HomeKitService: HMHomeManagerDelegate {
    nonisolated func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        Task { @MainActor in
            self.homes = manager.homes
            self.isAuthorized = true

            // Set delegate for each home to receive trigger updates
            for home in manager.homes {
                home.delegate = self
            }

            // Recolectar todos los accesorios de todos los homes
            var allAccessories: [HMAccessory] = []
            for home in manager.homes {
                allAccessories.append(contentsOf: home.accessories)
            }
            self.accessories = allAccessories
            self.outlets = filterOutlets(from: allAccessories)

            print("🏠 [HomeKit] ========== HOMES ACTUALIZADOS ==========")
            print("🏠 [HomeKit] \(homes.count) homes, \(accessories.count) accessories, \(outlets.count) outlets/switches")
            print("🏠 [HomeKit] ==========================================")

            // Notify that homes were updated (for sync)
            self.homesLastUpdated = Date()
        }
    }
}

// MARK: - HMHomeDelegate
extension HomeKitService: HMHomeDelegate {
    // Called when a trigger is added to the home (including by other users)
    nonisolated func home(_ home: HMHome, didAdd trigger: HMTrigger) {
        Task { @MainActor in
            print("🔔 [HomeKit] Trigger added: \(trigger.name)")
            if trigger.name.hasPrefix("HomeLock_") {
                print("🔔 [HomeKit] HomeLock trigger detected from another device!")
                self.homesLastUpdated = Date()
            }
        }
    }

    // Called when a trigger is removed from the home (including by other users)
    nonisolated func home(_ home: HMHome, didRemove trigger: HMTrigger) {
        Task { @MainActor in
            print("🔔 [HomeKit] Trigger removed: \(trigger.name)")
            if trigger.name.hasPrefix("HomeLock_") {
                print("🔔 [HomeKit] HomeLock trigger removed from another device!")
                self.homesLastUpdated = Date()
            }
        }
    }

    // Called when a trigger is updated
    nonisolated func home(_ home: HMHome, didUpdate trigger: HMTrigger) {
        Task { @MainActor in
            print("🔔 [HomeKit] Trigger updated: \(trigger.name)")
            if trigger.name.hasPrefix("HomeLock_") {
                self.homesLastUpdated = Date()
            }
        }
    }

    // Called when an accessory is added
    nonisolated func home(_ home: HMHome, didAdd accessory: HMAccessory) {
        Task { @MainActor in
            print("🔔 [HomeKit] Accessory added: \(accessory.name)")
            self.accessories.append(accessory)
            self.outlets = filterOutlets(from: self.accessories)
        }
    }

    // Called when an accessory is removed
    nonisolated func home(_ home: HMHome, didRemove accessory: HMAccessory) {
        Task { @MainActor in
            print("🔔 [HomeKit] Accessory removed: \(accessory.name)")
            self.accessories.removeAll { $0.uniqueIdentifier == accessory.uniqueIdentifier }
            self.outlets = filterOutlets(from: self.accessories)
        }
    }
}

// MARK: - Errors
enum HomeKitError: LocalizedError {
    case serviceNotFound
    case characteristicNotFound
    case homeNotFound
    case triggerCreationFailed
    case unknown

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
        case .unknown:
            return "Error desconocido en HomeKit"
        }
    }
}
