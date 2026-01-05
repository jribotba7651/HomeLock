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
        print("🔒 [HomeLock] ========== CREANDO LOCK TRIGGER ==========")
        print("🔒 [HomeLock] Dispositivo: \(accessory.name)")
        print("🔒 [HomeLock] Estado a mantener: \(lockedState ? "ON" : "OFF")")

        guard let home = getHome(for: accessory) else {
            print("❌ [HomeLock] ERROR: No se encontró el home para el accesorio")
            throw HomeKitError.homeNotFound
        }
        print("🔒 [HomeLock] Home encontrado: \(home.name)")

        guard let service = getControllableService(for: accessory) else {
            print("❌ [HomeLock] ERROR: No se encontró servicio controlable")
            throw HomeKitError.serviceNotFound
        }
        print("🔒 [HomeLock] Servicio: \(service.serviceType) - \(service.name)")

        guard let powerState = getPowerStateCharacteristic(for: service) else {
            print("❌ [HomeLock] ERROR: No se encontró PowerState characteristic")
            throw HomeKitError.serviceNotFound
        }
        print("🔒 [HomeLock] PowerState characteristic encontrado: \(powerState.characteristicType)")
        print("🔒 [HomeLock] Valor actual: \(String(describing: powerState.value))")

        let triggerName = "HomeLock_\(accessory.uniqueIdentifier.uuidString)"
        let actionSetPrefix = "HomeLock_Revert_"
        print("🔒 [HomeLock] Nombre del trigger: \(triggerName)")

        // ========== LIMPIEZA AGRESIVA ==========
        // Contar triggers HomeLock existentes
        let homeLockTriggers = home.triggers.filter { $0.name.hasPrefix("HomeLock_") }
        let homeLockActionSets = home.actionSets.filter { $0.name.hasPrefix("HomeLock_") }
        print("🧹 [HomeLock] ANTES - HomeLock triggers: \(homeLockTriggers.count), ActionSets: \(homeLockActionSets.count)")

        print("🔒 [HomeLock] Todos los triggers en home (\(home.triggers.count)):")
        for existingTrigger in home.triggers {
            let isHomeLock = existingTrigger.name.hasPrefix("HomeLock_") ? "🔒" : "  "
            print("   \(isHomeLock) \(existingTrigger.name): enabled=\(existingTrigger.isEnabled)")
        }

        // Eliminar TODOS los triggers HomeLock_ para este dispositivo
        let triggersToRemove = home.triggers.filter { $0.name == triggerName }
        print("🧹 [HomeLock] Triggers a eliminar para este dispositivo: \(triggersToRemove.count)")

        for trigger in triggersToRemove {
            print("🧹 [HomeLock] Eliminando trigger: \(trigger.name)...")

            // Primero eliminar action sets asociados
            if let eventTrigger = trigger as? HMEventTrigger {
                for actionSet in eventTrigger.actionSets where actionSet.name.hasPrefix(actionSetPrefix) {
                    print("🧹 [HomeLock] Eliminando ActionSet asociado: \(actionSet.name)")
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

            // Luego eliminar el trigger
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    home.removeTrigger(trigger) { error in
                        if let error {
                            print("❌ [HomeLock] Error eliminando trigger: \(error.localizedDescription)")
                            continuation.resume(throwing: error)
                        } else {
                            print("✅ [HomeLock] Trigger eliminado: \(trigger.name)")
                            continuation.resume()
                        }
                    }
                }
            } catch {
                print("⚠️ [HomeLock] Continuando a pesar del error: \(error.localizedDescription)")
            }
        }

        // También limpiar ActionSets huérfanos de este dispositivo
        let orphanedActionSets = home.actionSets.filter {
            $0.name.hasPrefix(actionSetPrefix) && $0.actions.isEmpty == false
        }
        for actionSet in orphanedActionSets {
            // Verificar si el actionSet pertenece a esta characteristic
            if let action = actionSet.actions.first as? HMCharacteristicWriteAction<NSCopying>,
               action.characteristic.service?.accessory?.uniqueIdentifier == accessory.uniqueIdentifier {
                print("🧹 [HomeLock] Eliminando ActionSet huérfano: \(actionSet.name)")
                try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    home.removeActionSet(actionSet) { error in
                        continuation.resume()
                    }
                }
            }
        }

        // Pequeña pausa para que HomeKit sincronice
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 segundos

        // Verificar limpieza
        let remainingHomeLockTriggers = home.triggers.filter { $0.name.hasPrefix("HomeLock_") }
        print("🧹 [HomeLock] DESPUÉS - HomeLock triggers: \(remainingHomeLockTriggers.count)")

        // Crear el evento: cuando PowerState cambia al estado opuesto al bloqueado
        let unwantedState = !lockedState
        print("🔒 [HomeLock] Estado NO deseado (trigger value): \(unwantedState)")

        let event = HMCharacteristicEvent(characteristic: powerState, triggerValue: unwantedState as NSCopying)
        print("🔒 [HomeLock] Evento creado: HMCharacteristicEvent")
        print("   - Characteristic: \(event.characteristic.characteristicType)")
        print("   - Trigger value: \(String(describing: event.triggerValue))")

        // Crear la acción: revertir al estado bloqueado
        print("🔒 [HomeLock] Creando ActionSet...")
        let actionSet = try await createRevertActionSet(home: home, characteristic: powerState, targetState: lockedState, accessoryName: accessory.name)
        print("✅ [HomeLock] ActionSet creado: \(actionSet.name)")
        print("   - Actions: \(actionSet.actions.count)")
        for action in actionSet.actions {
            if let writeAction = action as? HMCharacteristicWriteAction<NSCopying> {
                print("   - WriteAction: target=\(String(describing: writeAction.targetValue))")
            }
        }

        // Crear el trigger con el evento y la acción
        print("🔒 [HomeLock] Creando HMEventTrigger...")
        let trigger = HMEventTrigger(name: triggerName, events: [event], predicate: nil)

        // Agregar trigger al home
        print("🔒 [HomeLock] Agregando trigger al home...")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            home.addTrigger(trigger) { error in
                if let error {
                    print("❌ [HomeLock] Error agregando trigger: \(error)")
                    continuation.resume(throwing: error)
                } else {
                    print("✅ [HomeLock] Trigger agregado al home")
                    continuation.resume()
                }
            }
        }

        // Agregar action set al trigger
        print("🔒 [HomeLock] Agregando ActionSet al trigger...")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            trigger.addActionSet(actionSet) { error in
                if let error {
                    print("❌ [HomeLock] Error agregando ActionSet: \(error)")
                    continuation.resume(throwing: error)
                } else {
                    print("✅ [HomeLock] ActionSet agregado al trigger")
                    continuation.resume()
                }
            }
        }

        // Habilitar el trigger
        print("🔒 [HomeLock] Habilitando trigger...")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            trigger.enable(true) { error in
                if let error {
                    print("❌ [HomeLock] Error habilitando trigger: \(error)")
                    continuation.resume(throwing: error)
                } else {
                    print("✅ [HomeLock] Trigger habilitado")
                    continuation.resume()
                }
            }
        }

        // Verificación final
        print("🔒 [HomeLock] ========== VERIFICACIÓN FINAL ==========")
        print("🔒 [HomeLock] Trigger UUID: \(trigger.uniqueIdentifier)")
        print("🔒 [HomeLock] Trigger enabled: \(trigger.isEnabled)")
        print("🔒 [HomeLock] Trigger events: \(trigger.events.count)")
        for (index, evt) in trigger.events.enumerated() {
            print("   - Event \(index): \(type(of: evt))")
            if let charEvent = evt as? HMCharacteristicEvent<NSCopying> {
                print("     Characteristic: \(charEvent.characteristic.characteristicType)")
                print("     Trigger value: \(String(describing: charEvent.triggerValue))")
            }
        }
        print("🔒 [HomeLock] Trigger actionSets: \(trigger.actionSets.count)")
        for actionSet in trigger.actionSets {
            print("   - ActionSet: \(actionSet.name), actions: \(actionSet.actions.count)")
        }

        // Verificar que el trigger está en home.triggers
        print("🔒 [HomeLock] Triggers en home después de crear:")
        for t in home.triggers {
            let enabled = t.isEnabled ? "✅" : "❌"
            let isHomeLock = t.name.hasPrefix("HomeLock_") ? "🔒" : "  "
            print("   \(enabled) \(isHomeLock) \(t.name)")
        }

        // Conteo final
        let finalHomeLockTriggers = home.triggers.filter { $0.name.hasPrefix("HomeLock_") }
        let finalHomeLockActionSets = home.actionSets.filter { $0.name.hasPrefix("HomeLock_") }
        print("📊 [HomeLock] CONTEO FINAL - HomeLock triggers: \(finalHomeLockTriggers.count), ActionSets: \(finalHomeLockActionSets.count)")

        // Verificar que el trigger recién creado está en la lista
        let triggerExists = home.triggers.contains(where: { $0.uniqueIdentifier == trigger.uniqueIdentifier })
        print("📊 [HomeLock] ¿Trigger existe en home.triggers? \(triggerExists ? "✅ SÍ" : "❌ NO")")

        print("🔒 [HomeLock] ========== LOCK TRIGGER CREADO EXITOSAMENTE ==========")

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

            print("🏠 [HomeKit] ========== HOMES ACTUALIZADOS ==========")
            print("🏠 [HomeKit] \(homes.count) homes, \(accessories.count) accessories, \(outlets.count) outlets/switches")

            // Debug: listar todos los triggers existentes
            for home in manager.homes {
                print("🏠 [HomeKit] Home: \(home.name)")
                print("   Triggers: \(home.triggers.count)")
                for trigger in home.triggers {
                    let enabled = trigger.isEnabled ? "✅" : "❌"
                    print("   \(enabled) \(trigger.name) (UUID: \(trigger.uniqueIdentifier))")
                    if let eventTrigger = trigger as? HMEventTrigger {
                        print("      Events: \(eventTrigger.events.count)")
                        for event in eventTrigger.events {
                            if let charEvent = event as? HMCharacteristicEvent<NSCopying> {
                                print("      - CharEvent: triggerValue=\(String(describing: charEvent.triggerValue))")
                            }
                        }
                        print("      ActionSets: \(eventTrigger.actionSets.count)")
                        for actionSet in eventTrigger.actionSets {
                            print("      - \(actionSet.name): \(actionSet.actions.count) actions")
                        }
                    }
                }
                print("   ActionSets: \(home.actionSets.count)")
                for actionSet in home.actionSets {
                    if actionSet.name.hasPrefix("HomeLock") {
                        print("   - \(actionSet.name): \(actionSet.actions.count) actions")
                    }
                }
            }
            print("🏠 [HomeKit] ==========================================")
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
