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

    /// `true` si el trigger HomeLock apunta a un accesorio Lutron.
    /// Uses the event chain (event.characteristic.service.accessory) for cross-device
    /// stable mapping instead of the UUID in the trigger name.
    func triggerReferencesLutron(_ trigger: HMTrigger, in home: HMHome) -> Bool {
        guard trigger.name.hasPrefix("HomeLock_") else { return false }
        guard let eventTrigger = trigger as? HMEventTrigger,
              let charEvent = eventTrigger.events.first as? HMCharacteristicEvent<NSCopying>,
              let accessory = charEvent.characteristic.service?.accessory else {
            return false
        }
        return isLutronDevice(accessory)
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

        // Last-line defense for reads: characteristic reads also travel over
        // the Caséta bridge's Clear Connect radio. With Lutron isolated, even
        // a cached read should avoid issuing a fresh readValue() to the bridge.
        // We return the cached value if present, otherwise nil (caller treats
        // as "unknown state"), without ever hitting the bridge.
        if Self.shouldIgnoreLutron && isLutronDevice(accessory) {
            return powerState.value as? Bool
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
        // Last-line defense: the lowest write primitive in the app refuses to
        // touch a Lutron accessory when isolation is on. Every higher-level
        // call site is supposed to gate this already, but if any path slipped
        // past (CloudKit-driven re-application, a forgotten code path, a future
        // refactor), this guard ensures no characteristic write ever reaches
        // the Caséta bridge while the user has Lutron isolated.
        if Self.shouldIgnoreLutron && isLutronDevice(accessory) {
            print("🚫 [HomeKit] BLOCKED setAccessoryPower for isolated Lutron: \(accessory.name)")
            throw HomeKitError.serviceNotFound
        }

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
    ///   - expiresAt: Expiration date embedded in trigger name for cross-device sync (nil = indefinite)
    /// - Returns: El UUID del trigger creado
    func createLockTrigger(for accessory: HMAccessory, lockedState: Bool, expiresAt: Date? = nil) async throws -> UUID {
        print("🔒 [HomeLock] ========== CREANDO LOCK TRIGGER ==========")
        print("🔒 [HomeLock] Dispositivo: \(accessory.name)")
        print("🔒 [HomeLock] Estado a mantener: \(lockedState ? "ON" : "OFF")")

        // Lutron isolation: when the user has Lutron isolated (default), refuse
        // to write triggers to a Lutron device. This is defense-in-depth — UI and
        // schedulers already filter Lutron, but a direct call from a deep-linked
        // path or a stale lock-restore flow could still reach here. Refusing prevents
        // the bridge saturation that drops the entire Lutron home off HomeKit.
        if Self.shouldIgnoreLutron && isLutronDevice(accessory) {
            print("🚫 [HomeLock] Refusing to create trigger for isolated Lutron device: \(accessory.name)")
            throw HomeKitError.serviceNotFound
        }

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

        let triggerName = Self.buildTriggerName(accessoryUUID: accessory.uniqueIdentifier, expiresAt: expiresAt)
        let triggerPrefix = "HomeLock_\(accessory.uniqueIdentifier.uuidString)"
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

            let isolateLutron = Self.shouldIgnoreLutron

            // Limpiar TODOS los triggers HomeLock — pero respetando el aislamiento.
            // Si el flag está activo, saltamos los triggers cuyo accesorio es Lutron
            // para no enviar borrados al bridge.
            for trigger in homeLockTriggers {
                if isolateLutron && triggerReferencesLutron(trigger, in: home) {
                    print("🚫 [HomeLock] Skip trigger Lutron en limpieza masiva: \(trigger.name)")
                    continue
                }
                print("🧹 [HomeLock] Eliminando trigger: \(trigger.name)")

                // Eliminar action sets del trigger
                if let eventTrigger = trigger as? HMEventTrigger {
                    for actionSet in eventTrigger.actionSets where actionSet.name.hasPrefix("HomeLock_") {
                        try? await home.removeActionSet(actionSet)
                    }
                }

                try? await home.removeTrigger(trigger)
            }

            // Limpiar action sets huérfanos — saltando los que pertenecen a Lutron.
            for actionSet in homeLockActionSets {
                if isolateLutron, let action = actionSet.actions.first as? HMCharacteristicWriteAction<NSCopying>,
                   let actionAccessory = action.characteristic.service?.accessory,
                   isLutronDevice(actionAccessory) {
                    print("🚫 [HomeLock] Skip ActionSet Lutron en limpieza masiva: \(actionSet.name)")
                    continue
                }
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

        // Eliminar TODOS los triggers HomeLock_ para este dispositivo (matches both old and new name format)
        let triggersToRemove = home.triggers.filter { $0.name.hasPrefix(triggerPrefix) }
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

        // Lutron Clear Connect throttle: insert a 500ms gap between consecutive
        // writes so the Caséta bridge has time to settle. Without this, the three
        // back-to-back writes (addTrigger → addActionSet → enable) saturate the
        // 434 MHz radio and the bridge drops the HomeKit connection.
        if isLutron {
            try? await Task.sleep(nanoseconds: 500_000_000)
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

        if isLutron {
            try? await Task.sleep(nanoseconds: 500_000_000)
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

    /// Elimina un trigger de lock por su UUID. Idempotent: if the trigger was already
    /// removed by another device, this returns silently without error.
    func removeLockTrigger(triggerID: UUID, for accessory: HMAccessory) async throws {
        if Self.shouldIgnoreLutron && isLutronDevice(accessory) {
            print("🚫 [HomeKit] Skip removeLockTrigger (Lutron isolated): \(accessory.name)")
            return
        }

        guard let home = getHome(for: accessory) else {
            throw HomeKitError.homeNotFound
        }

        // Idempotent: trigger may have been removed by another device already
        guard let trigger = home.triggers.first(where: { $0.uniqueIdentifier == triggerID }) else {
            print("🧹 [HomeLock] Trigger no encontrado, puede que ya haya sido eliminado (idempotent)")
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

        // Eliminar el trigger — idempotent for concurrent removal, loud for real errors
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                home.removeTrigger(trigger) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        print("✅ [HomeLock] Trigger eliminado para \(accessory.name)")
                        continuation.resume()
                    }
                }
            }
        } catch let hmError as HMError where Self.isNotFoundError(hmError) {
            // Expected: another device already removed this trigger
            print("🔇 [HomeLock] Trigger already removed by another device (code \(hmError.code.rawValue)): \(accessory.name)")
        } catch {
            // Unexpected: network, permissions, etc. — log visibly but don't crash
            print("⚠️ [HomeLock] WARNING: Trigger removal failed with unexpected error: \(error.localizedDescription) (code: \((error as NSError).code))")
        }

    }

    /// Elimina un trigger de lock por nombre del accesorio (matches both old and new name format)
    func removeLockTrigger(for accessory: HMAccessory) async throws {
        // Aislamiento Lutron: ver nota en la otra sobrecarga.
        if Self.shouldIgnoreLutron && isLutronDevice(accessory) {
            print("🚫 [HomeKit] Skip removeLockTrigger by-name (Lutron isolated): \(accessory.name)")
            return
        }

        guard let home = getHome(for: accessory) else {
            throw HomeKitError.homeNotFound
        }

        let triggerPrefix = "HomeLock_\(accessory.uniqueIdentifier.uuidString)"

        // Find all triggers for this device (old format or new format with _exp)
        let matchingTriggers = home.triggers.filter { $0.name.hasPrefix(triggerPrefix) }
        guard !matchingTriggers.isEmpty else { return }

        for trigger in matchingTriggers {
            // Eliminar action sets asociados
            if let eventTrigger = trigger as? HMEventTrigger {
                for actionSet in eventTrigger.actionSets {
                    if actionSet.name.hasPrefix("HomeLock_Revert_") {
                        try? await home.removeActionSet(actionSet)
                    }
                }
            }

            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    home.removeTrigger(trigger) { error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            print("✅ [HomeLock] Trigger eliminado para \(accessory.name)")
                            continuation.resume()
                        }
                    }
                }
            } catch let hmError as HMError where Self.isNotFoundError(hmError) {
                print("🔇 [HomeLock] Trigger already removed by another device (code \(hmError.code.rawValue)): \(accessory.name)")
            } catch {
                print("⚠️ [HomeLock] WARNING: Trigger removal failed with unexpected error: \(error.localizedDescription) (code: \((error as NSError).code))")
            }
        }

    }

    /// Elimina TODAS las automatizaciones de HomeLock (triggers y action sets que empiezan con "HomeLock_")
    /// - Returns: Número de elementos eliminados (triggers + action sets)
    func removeAllHomeLockAutomations() async -> Int {
        var removedCount = 0
        let isolateLutron = Self.shouldIgnoreLutron

        for home in homes {
            print("🧹 [HomeLock] Limpiando home: \(home.name)")

            // 1. Eliminar todos los triggers que empiezan con "HomeLock_"
            let homeLockTriggers = home.triggers.filter { $0.name.hasPrefix("HomeLock_") }
            print("🧹 [HomeLock] Encontrados \(homeLockTriggers.count) triggers HomeLock_")

            for trigger in homeLockTriggers {
                // Aislamiento Lutron: incluso un cleanup explícito del usuario debe
                // saltar Lutron, porque borrar 50 triggers en ráfaga al bridge es
                // exactamente lo que tira la conexión de toda la casa. Si el usuario
                // quiere limpiar Lutron, primero desactiva el aislamiento.
                if isolateLutron && triggerReferencesLutron(trigger, in: home) {
                    print("🚫 [HomeLock] Skip trigger Lutron en cleanup (aislado): \(trigger.name)")
                    continue
                }
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
                if isolateLutron,
                   let action = actionSet.actions.first as? HMCharacteristicWriteAction<NSCopying>,
                   let actionAccessory = action.characteristic.service?.accessory,
                   isLutronDevice(actionAccessory) {
                    print("🚫 [HomeLock] Skip ActionSet Lutron en cleanup (aislado): \(actionSet.name)")
                    continue
                }
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

    // MARK: - Trigger Name Parsing

    /// Result of parsing a HomeLock trigger name.
    struct ParsedTriggerName {
        let accessoryUUID: UUID
        /// nil = indefinite (explicit NONE or legacy format).
        /// Date(timeIntervalSince1970: 0) = malformed expiration (fail-safe: expires immediately).
        let expiresAt: Date?
    }

    /// Parses a HomeLock trigger name into its components.
    ///
    /// Supports:
    /// - New format: `HomeLock_{accessoryUUID}_exp{unixTimestamp}`
    /// - New format (indefinite): `HomeLock_{accessoryUUID}_expNONE`
    /// - Legacy format: `HomeLock_{accessoryUUID}` (treated as expiresAt: nil)
    ///
    /// Uses rsplit (range of "_exp" searching backwards) so that the hyphens
    /// inside the UUID are never ambiguous with the separator.
    ///
    /// Returns nil for non-HomeLock triggers or names that start with "HomeLock_Revert_".
    static func parseTriggerName(_ name: String) -> ParsedTriggerName? {
        let prefix = "HomeLock_"
        guard name.hasPrefix(prefix) else { return nil }
        guard !name.hasPrefix("HomeLock_Revert_") else { return nil }

        let afterPrefix = String(name.dropFirst(prefix.count))

        // New format: rsplit on "_exp" from the right
        if let expRange = afterPrefix.range(of: "_exp", options: .backwards) {
            let uuidString = String(afterPrefix[afterPrefix.startIndex..<expRange.lowerBound])
            let expValue = String(afterPrefix[expRange.upperBound...])

            guard let accessoryUUID = UUID(uuidString: uuidString) else { return nil }

            if expValue == "NONE" {
                return ParsedTriggerName(accessoryUUID: accessoryUUID, expiresAt: nil)
            } else if let timestamp = TimeInterval(expValue), timestamp > 0 {
                return ParsedTriggerName(accessoryUUID: accessoryUUID, expiresAt: Date(timeIntervalSince1970: timestamp))
            } else {
                // Malformed exp value: fail-safe to epoch 0 so it expires immediately
                // on the next poll. Better a lock that falls off than one that's eternal.
                print("WARNING [HomeKit] Malformed expiration in trigger name: \(name)")
                return ParsedTriggerName(accessoryUUID: accessoryUUID, expiresAt: Date(timeIntervalSince1970: 0))
            }
        }

        // Legacy format: HomeLock_{accessoryUUID} (no _exp suffix)
        guard let accessoryUUID = UUID(uuidString: afterPrefix) else { return nil }
        return ParsedTriggerName(accessoryUUID: accessoryUUID, expiresAt: nil)
    }

    /// Builds a trigger name embedding the accessory UUID and expiration.
    static func buildTriggerName(accessoryUUID: UUID, expiresAt: Date?) -> String {
        let expSuffix: String
        if let expiresAt {
            expSuffix = "_exp\(Int(expiresAt.timeIntervalSince1970))"
        } else {
            expSuffix = "_expNONE"
        }
        return "HomeLock_\(accessoryUUID.uuidString)\(expSuffix)"
    }

    // MARK: - Multi-User Sync Support

    /// Estructura para representar un lock detectado desde HomeKit
    struct DetectedLock {
        let accessoryUUID: UUID
        let accessoryName: String
        let triggerUUID: UUID
        let lockedState: Bool
        let isEnabled: Bool
        let expiresAt: Date?
    }

    /// Obtiene todos los triggers de HomeLock activos desde HomeKit.
    /// Esta es la fuente de verdad para locks activos cross-device.
    /// El mapeo trigger -> accessory se hace via la cadena de eventos del trigger
    /// (event.characteristic.service.accessory), NO por el UUID en el nombre,
    /// porque uniqueIdentifier es per-device y no es estable cross-device.
    func getAllActiveLockTriggers() -> [DetectedLock] {
        var detectedLocks: [DetectedLock] = []

        for home in homes {
            let homeLockTriggers = home.triggers.filter {
                $0.name.hasPrefix("HomeLock_") && !$0.name.hasPrefix("HomeLock_Revert_") && $0.isEnabled
            }

            for trigger in homeLockTriggers {
                guard let eventTrigger = trigger as? HMEventTrigger else {
                    print("❌ [HomeKit Sync] no es HMEventTrigger: [\(trigger.name)]")
                    continue
                }

                // Cross-device mapping: extract accessory from the trigger's event chain.
                // HomeKit maintains this reference correctly on each device, unlike
                // uniqueIdentifier which is per-device and not stable cross-device.
                guard let characteristicEvent = eventTrigger.events.first as? HMCharacteristicEvent<NSCopying> else {
                    print("❌ [HomeKit Sync] sin HMCharacteristicEvent: [\(trigger.name)]")
                    continue
                }

                guard let accessory = characteristicEvent.characteristic.service?.accessory else {
                    print("❌ [HomeKit Sync] cadena event->characteristic->service->accessory rota: [\(trigger.name)]")
                    continue
                }

                // Parse expiration from trigger name (the UUID in the name is ignored
                // for mapping — only _exp{timestamp} / _expNONE matters)
                let parsed = Self.parseTriggerName(trigger.name)
                let expiresAt = parsed?.expiresAt

                // triggerValue is the unwanted state; lockedState is the opposite
                var lockedState = true
                if let triggerValue = characteristicEvent.triggerValue as? Bool {
                    lockedState = !triggerValue
                }

                let detected = DetectedLock(
                    accessoryUUID: accessory.uniqueIdentifier,
                    accessoryName: accessory.name,
                    triggerUUID: trigger.uniqueIdentifier,
                    lockedState: lockedState,
                    isEnabled: trigger.isEnabled,
                    expiresAt: expiresAt
                )

                detectedLocks.append(detected)
                print("🔍 [HomeKit Sync] Trigger detectado: \(accessory.name) (UUID local: \(accessory.uniqueIdentifier)) -> \(lockedState ? "ON" : "OFF"), expires: \(expiresAt?.description ?? "never")")
            }
        }

        print("🔍 [HomeKit Sync] Total triggers detectados: \(detectedLocks.count)")
        return detectedLocks
    }

    // MARK: - Error Classification

    /// Returns true if the HMError indicates the object was already removed or not found.
    /// These are expected during concurrent removal by multiple devices.
    static func isNotFoundError(_ error: HMError) -> Bool {
        switch error.code {
        case .notFound,
             .operationNotSupported:  // Some HomeKit versions return this for stale references
            return true
        default:
            return false
        }
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
