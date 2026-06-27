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

    /// Número de accesorios Lutron controlables que se están ocultando
    /// por la política `ignoreLutronDevices`. La UI usa este valor para
    /// mostrar un banner explicativo en el dashboard (en vez de silencio).
    @Published var hiddenLutronCount: Int = 0

    // MARK: - Lutron compatibility flag
    //
    // Los dispositivos Lutron (Caséta / RA3) a través de su bridge HomeKit son
    // notoriamente inestables: el bridge pierde la conexión con el Home Hub,
    // los triggers quedan huérfanos y los bloqueos no se aplican de forma fiable.
    // Por defecto HomeLock los IGNORA por completo (no aparecen en el picker,
    // no se pueden bloquear vía Shortcuts, no se sincronizan). El usuario puede
    // reactivarlos desde Settings si Lutron publica un firmware/bridge nuevo
    // que resuelva el problema de conectividad.
    static let ignoreLutronDefaultsKey = "ignoreLutronDevices"

    /// `true` (por defecto) = los dispositivos Lutron se excluyen de la app.
    /// Lee directamente UserDefaults para poder usarse fuera de Views.
    static var shouldIgnoreLutron: Bool {
        // Default = true. Registramos el valor por defecto para que el primer
        // lanzamiento también lo respete.
        UserDefaults.standard.register(defaults: [ignoreLutronDefaultsKey: true])
        return UserDefaults.standard.bool(forKey: ignoreLutronDefaultsKey)
    }

    /// Detecta si un accesorio es de la marca Lutron
    func isLutronDevice(_ accessory: HMAccessory) -> Bool {
        let manufacturer = accessory.manufacturer?.lowercased() ?? ""
        let model = accessory.model?.lowercased() ?? ""
        // Cubrimos tanto "Lutron Electronics Co., Inc." como nombres de modelo
        // tipo "Caséta" / "RA3" que a veces vienen con manufacturer vacío
        // cuando el bridge expone accesorios puenteados.
        return manufacturer.contains("lutron")
            || model.contains("caseta")
            || model.contains("caséta")
            || model.contains("ra2")
            || model.contains("ra3")
    }

    /// Detecta si un accesorio es de la marca TP-Link/Kasa
    func isKasaDevice(_ accessory: HMAccessory) -> Bool {
        let manufacturer = accessory.manufacturer?.lowercased() ?? ""
        return manufacturer.contains("tp-link") || manufacturer.contains("kasa")
    }

    private var homeManager: HMHomeManager?

    override init() {
        super.init()
    }

    func requestAuthorization() {
        if homeManager == nil {
            homeManager = HMHomeManager()
            homeManager?.delegate = self
        }
    }

    /// Espera a que HomeKit termine de cargar los hogares
    func waitServiceReady() async {
        if homeManager == nil {
            requestAuthorization()
        }
        
        // Si ya hay hogares, no esperamos
        if !homes.isEmpty { return }
        
        print("☁️ [HomeKitService] Esperando a que HomeKit esté listo...")
        
        // Reintentos durante 5 segundos
        for _ in 0..<10 {
            if !homes.isEmpty { break }
            try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
        }
    }

    /// Recalcula `outlets` aplicando los filtros actuales (incluido el de Lutron).
    /// Llamar cuando el usuario cambia el toggle de compatibilidad desde Settings.
    func refreshOutlets() {
        self.outlets = filterOutlets(from: self.accessories)
    }

    /// Filtra accesorios que tienen servicios controlables por encendido/apagado.
    /// Si `shouldIgnoreLutron` está activo (por defecto), también se excluye
    /// cualquier accesorio fabricado por Lutron — ver nota en la declaración
    /// de `shouldIgnoreLutron`. Actualiza `hiddenLutronCount` como efecto
    /// secundario para que la UI pueda mostrar un aviso.
    private func filterOutlets(from accessories: [HMAccessory]) -> [HMAccessory] {
        var hiddenLutron = 0
        let filtered = accessories.filter { accessory in
            let isControllable = accessory.services.contains { service in
                service.characteristics.contains { $0.characteristicType == HMCharacteristicTypePowerState }
            }
            guard isControllable else { return false }
            if isLutronDevice(accessory) {
                hiddenLutron += 1
                return false
            }
            return true
        }
        self.hiddenLutronCount = hiddenLutron
        return filtered
    }

    /// Obtiene el servicio controlable (outlet/switch/light) de un accesorio
    func getControllableService(for accessory: HMAccessory) -> HMService? {
        accessory.services.first { service in
            service.characteristics.contains { $0.characteristicType == HMCharacteristicTypePowerState }
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
            // Intentar lectura fresca con un timeout implícito corto
            try await powerState.readValue()
            return powerState.value as? Bool
        } catch {
            // Si la lectura falla (timeout o dispositivo ocupado), usamos el valor cacheado
            // Esto es vital para dispositivos Wi-Fi como Kasa que pueden tardar en responder
            if let cachedValue = powerState.value as? Bool {
                print("⚠️ [HomeKit] Usando valor cacheado para \(accessory.name) tras fallo de lectura")
                return cachedValue
            }
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

        // ========== PROTECCIÓN CONTRA MEMORY LEAK ==========
        // Contar triggers HomeLock existentes
        let homeLockTriggers = home.triggers.filter { $0.name.hasPrefix("HomeLock_") }
        let homeLockActionSets = home.actionSets.filter { $0.name.hasPrefix("HomeLock_") }
        print("🧹 [HomeLock] ANTES - HomeLock triggers: \(homeLockTriggers.count), ActionSets: \(homeLockActionSets.count)")

        // PROTECCIÓN: Si hay demasiados triggers, limpiar todo
        // Aumentamos límites para hogares con muchos dispositivos Kasa
        let totalTriggers = home.triggers.count
        if totalTriggers > 100 || homeLockTriggers.count > 50 {
            print("🚨 [HomeLock] PROTECCIÓN DE LÍMITES! Total triggers: \(totalTriggers), HomeLock: \(homeLockTriggers.count)")
            print("🧹 [HomeLock] Ejecutando limpieza masiva...")

            // Limpiar TODOS los triggers HomeLock
            for trigger in homeLockTriggers {
                print("🧹 [HomeLock] Eliminando trigger: \(trigger.name)")

                // Eliminar action sets del trigger
                if let eventTrigger = trigger as? HMEventTrigger {
                    for actionSet in eventTrigger.actionSets where actionSet.name.hasPrefix("HomeLock_") {
                        try? await home.removeActionSet(actionSet)
                    }
                }

                try? await home.removeTrigger(trigger)
            }

            // Limpiar action sets huérfanos
            for actionSet in homeLockActionSets {
                try? await home.removeActionSet(actionSet)
            }

            print("🧹 [HomeLock] Limpieza masiva completada")

            // Pausa para estabilizar HomeKit
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 segundo
        }

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

        // Stabilization pause for HomeKit sync
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s

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
