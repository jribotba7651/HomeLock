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
    //
    // Single source of truth: the UserDefaults key below. Views bind to
    // `ignoreLutronDevices` (never to their own @AppStorage copy) so Settings,
    // the Home banner and the outlet filter always agree.
    nonisolated static let ignoreLutronDefaultsKey = "ignoreLutronDevices"

    /// Reads the isolation flag from `defaults`. Missing key = `true` (ignore ON).
    nonisolated static func isLutronIsolated(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: ignoreLutronDefaultsKey) as? Bool ?? true
    }

    /// Effective isolation: with Lutron locking compiled out
    /// (`FeatureFlags.lutronLockingEnabled == false`, v1) Lutron is always
    /// ignored regardless of the stored setting.
    nonisolated static func effectiveIgnoreLutron(stored: Bool, lutronEnabled: Bool) -> Bool {
        !lutronEnabled || stored
    }

    /// `true` (por defecto) = los dispositivos Lutron se excluyen de la app.
    /// Always `true` in v1 (see `FeatureFlags.lutronLockingEnabled`).
    /// Lee directamente UserDefaults para poder usarse fuera de Views.
    nonisolated static var shouldIgnoreLutron: Bool {
        effectiveIgnoreLutron(stored: isLutronIsolated(in: .standard),
                              lutronEnabled: FeatureFlags.lutronLockingEnabled)
    }

    /// Pure filter rule: an accessory is hidden from outlets for being Lutron
    /// only while isolation is on.
    nonisolated static func hidesLutron(isLutron: Bool, ignoreLutron: Bool) -> Bool {
        isLutron && ignoreLutron
    }

    /// Pure lock rule: Lutron can be locked only while isolation is OFF.
    nonisolated static func allowsLock(isLutron: Bool, ignoreLutron: Bool) -> Bool {
        !(isLutron && ignoreLutron)
    }

    /// Pure unlock rule: unlocking is never blocked, so a lock is never stranded
    /// (removals are allowed for Lutron even while isolation is ON).
    nonisolated static func allowsUnlock(isLutron: Bool, ignoreLutron: Bool) -> Bool {
        true
    }

    /// Observable, persisted isolation flag. Settings' toggle and the Home
    /// banner's "Show anyway" both write here; writes persist to UserDefaults
    /// and recompute `outlets` so Home updates immediately.
    @Published var ignoreLutronDevices: Bool = HomeKitService.shouldIgnoreLutron {
        didSet {
            // v1: Lutron locking is off, so isolation cannot be turned off.
            // TODO(1.1): drop this once FeatureFlags.lutronLockingEnabled is on.
            if !FeatureFlags.lutronLockingEnabled && !ignoreLutronDevices {
                ignoreLutronDevices = true
                return
            }
            guard oldValue != ignoreLutronDevices else { return }
            UserDefaults.standard.set(ignoreLutronDevices, forKey: Self.ignoreLutronDefaultsKey)
            refreshOutlets()
        }
    }

    /// Detecta si un accesorio es de la marca Lutron
    func isLutronDevice(_ accessory: HMAccessory) -> Bool {
        Self.isLutron(manufacturer: accessory.manufacturer, model: accessory.model)
    }

    /// Pure Lutron detection from manufacturer/model strings (testable without HMAccessory).
    nonisolated static func isLutron(manufacturer: String?, model: String?) -> Bool {
        let manufacturer = manufacturer?.lowercased() ?? ""
        let model = model?.lowercased() ?? ""
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

    /// Resolves the accessory a HomeLock trigger acts on through its event chain
    /// (event -> characteristic -> service -> accessory). Returns nil when the
    /// chain is broken. Never use the UUID in the trigger name for this: it is the
    /// creating device's `uniqueIdentifier`, which differs on every device.
    func resolveAccessory(for trigger: HMTrigger) -> HMAccessory? {
        guard let eventTrigger = trigger as? HMEventTrigger,
              let charEvent = eventTrigger.events.first as? HMCharacteristicEvent<NSCopying> else {
            return nil
        }
        return charEvent.characteristic.service?.accessory
    }

    /// Pure orphan decision for a HomeLock_ trigger: orphaned only if its event
    /// chain no longer resolves to an accessory, or its `_exp` timestamp has passed.
    nonisolated static func isOrphanedTrigger(chainResolved: Bool, expiresAt: Date?, now: Date = Date()) -> Bool {
        if !chainResolved { return true }
        if let expiresAt, now >= expiresAt { return true }
        return false
    }

    /// Removes one HomeLock_ trigger and its HomeLock_ action sets.
    /// "Not found" is treated as success (another device may have removed it);
    /// any other error is thrown.
    func removeHomeLockTrigger(_ trigger: HMTrigger, in home: HMHome) async throws {
        // Lutron isolation blocks writes and new triggers, but removals are always
        // allowed — just spaced ~1s apart so the Caséta bridge isn't flooded.
        let isLutron = resolveAccessory(for: trigger).map(isLutronDevice) ?? false
        if let eventTrigger = trigger as? HMEventTrigger {
            for actionSet in eventTrigger.actionSets where actionSet.name.hasPrefix("HomeLock_") {
                if isLutron { await spaceLutronDeletion() }
                do {
                    try await home.removeActionSet(actionSet)
                } catch let hmError as HMError where Self.isNotFoundError(hmError) {
                    // Already gone
                } catch {
                    print("⚠️ [HomeLock] Error eliminando ActionSet \(actionSet.name): \(error.localizedDescription)")
                }
            }
        }
        if isLutron { await spaceLutronDeletion() }
        do {
            try await home.removeTrigger(trigger)
            print("✅ [HomeLock] Trigger eliminado: \(trigger.name)")
        } catch let hmError as HMError where Self.isNotFoundError(hmError) {
            print("🔇 [HomeLock] Trigger already removed (code \(hmError.code.rawValue)): \(trigger.name)")
        }
    }

    /// Removes a standalone HomeLock_ action set, spacing Lutron deletions.
    func removeHomeLockActionSet(_ actionSet: HMActionSet, in home: HMHome) async throws {
        if actionSetReferencesLutron(actionSet) { await spaceLutronDeletion() }
        do {
            try await home.removeActionSet(actionSet)
            print("✅ [HomeLock] ActionSet eliminado: \(actionSet.name)")
        } catch let hmError as HMError where Self.isNotFoundError(hmError) {
            // Already gone
        }
    }

    /// `true` if the action set writes to a characteristic of a Lutron accessory.
    func actionSetReferencesLutron(_ actionSet: HMActionSet) -> Bool {
        guard let action = actionSet.actions.first as? HMCharacteristicWriteAction<NSCopying>,
              let accessory = action.characteristic.service?.accessory else { return false }
        return isLutronDevice(accessory)
    }

    /// Next time a Lutron deletion may run; consecutive deletions are spaced ~1s.
    private var nextLutronDeletionAt: Date = .distantPast
    static let lutronDeletionSpacing: TimeInterval = 1.0

    private func spaceLutronDeletion() async {
        let now = Date()
        let slot = max(now, nextLutronDeletionAt)
        nextLutronDeletionAt = slot.addingTimeInterval(Self.lutronDeletionSpacing)
        let wait = slot.timeIntervalSince(now)
        if wait > 0 {
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
    }

    /// Detecta si un accesorio es de la marca TP-Link/Kasa
    func isKasaDevice(_ accessory: HMAccessory) -> Bool {
        let manufacturer = accessory.manufacturer?.lowercased() ?? ""
        return manufacturer.contains("tp-link") || manufacturer.contains("kasa")
    }

    private var homeManager: HMHomeManager?

    /// Maximum number of HomeLock_ triggers per home.
    nonisolated static let maxHomeLockTriggers = 50

    override init() {
        super.init()
    }

    func requestAuthorization() {
        if homeManager == nil {
            homeManager = HMHomeManager()
            homeManager?.delegate = self
        }
    }

    /// True once HMHomeManager has delivered its homes (homeManagerDidUpdateHomes).
    @Published private(set) var homesLoaded = false

    /// Waits until HMHomeManager has loaded the homes (not just a fixed 5 s),
    /// capped at `timeout` so an intent can't hang forever.
    func waitUntilHomesLoaded(timeout: TimeInterval = 20) async {
        if homeManager == nil { requestAuthorization() }
        let deadline = Date().addingTimeInterval(timeout)
        while !homesLoaded && Date() < deadline {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    /// Shortcuts cold launch: waits for the homes, then for the accessory to
    /// be found and reachable (HomeKit needs a moment to reconnect after
    /// launch; writing before that fails). Returns the accessory, reachable
    /// or not after `timeout`, or nil if it doesn't exist.
    func waitForReadyAccessory(_ id: UUID, timeout: TimeInterval = 10) async -> HMAccessory? {
        await waitUntilHomesLoaded()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let accessory = accessories.first(where: { $0.uniqueIdentifier == id }), accessory.isReachable {
                return accessory
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return accessories.first(where: { $0.uniqueIdentifier == id })
    }

    /// HMError readWriteFailure (74), as an HMError or a bridged NSError.
    nonisolated static func isReadWriteFailure(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == HMErrorDomain && ns.code == HMError.Code.readWriteFailure.rawValue
    }

    /// Runs `operation`; on readWriteFailure waits `delay` and runs it once more.
    static func retryingOnceOnReadWriteFailure<T>(delay: UInt64 = 1_000_000_000,
                                                  _ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch where isReadWriteFailure(error) {
            print("🔁 [HomeKit] readWriteFailure; retrying once")
            try? await Task.sleep(nanoseconds: delay)
            return try await operation()
        }
    }

    /// Power step of a lock started outside the device screen (Shortcuts):
    /// fresh read, skip the write if the device is already in the target state
    /// (writing the current value is rejected by some bridges with
    /// readWriteFailure), otherwise write and verify. On readWriteFailure it
    /// re-reads and retries once (the first write may have gone through).
    func setPowerForLock(_ accessory: HMAccessory, on: Bool) async throws -> Bool? {
        try await Self.retryingOnceOnReadWriteFailure {
            let current = await freshPowerState(accessory)
            if Self.shouldSkipPowerWrite(currentState: current, target: on) {
                print("⏭️ [HomeKit] \(accessory.name) already \(on ? "on" : "off"); skipping power write")
                return current
            }
            return try await setAccessoryPowerVerified(accessory, on: on)
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
    /// Se llama automáticamente al cambiar `ignoreLutronDevices`.
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

        // Categories that expose a PowerState characteristic but don't behave
        // like switchable outlets (writing fails or has unintended effects).
        // Excluding them up-front prevents the user from picking a camera or
        // doorbell only to hit a "Read/Write operation failed" error.
        let unsupportedCategories: Set<String> = [
            HMAccessoryCategoryTypeIPCamera,
            HMAccessoryCategoryTypeVideoDoorbell,
            HMAccessoryCategoryTypeAirPurifier,
            HMAccessoryCategoryTypeThermostat,
            HMAccessoryCategoryTypeSensor,
            HMAccessoryCategoryTypeDoorLock,
            HMAccessoryCategoryTypeGarageDoorOpener,
            HMAccessoryCategoryTypeWindowCovering,
            HMAccessoryCategoryTypeWindow,
            HMAccessoryCategoryTypeDoor,
            HMAccessoryCategoryTypeAirConditioner,
            HMAccessoryCategoryTypeAirHeater,
            HMAccessoryCategoryTypeAirHumidifier,
            HMAccessoryCategoryTypeAirDehumidifier,
            HMAccessoryCategoryTypeShowerHead,
            HMAccessoryCategoryTypeFaucet,
            HMAccessoryCategoryTypeSprinkler,
        ]

        let filtered = accessories.filter { accessory in
            // Skip categories we know don't behave like switchable outlets.
            if unsupportedCategories.contains(accessory.category.categoryType) {
                return false
            }

            // Primero: ¿es controlable? Si no, fuera siempre.
            let isControllable = accessory.services.contains { service in
                service.characteristics.contains { $0.characteristicType == HMCharacteristicTypePowerState }
            }
            guard isControllable else { return false }
            if Self.hidesLutron(isLutron: isLutronDevice(accessory), ignoreLutron: ignoreLutronDevices) {
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

    /// Full calendar date (year…minute, local time) at which a timed lock stops
    /// being enforced by the hub. HomeKit time predicates work at minute
    /// granularity, so the end is rounded UP to the next whole minute: the hub
    /// never releases a lock early (at most 59 s late).
    nonisolated static func lockEndComponents(for expiresAt: Date, calendar: Calendar = .current) -> DateComponents {
        let seconds = calendar.component(.second, from: expiresAt)
        let nanos = calendar.component(.nanosecond, from: expiresAt)
        let end = (seconds == 0 && nanos == 0)
            ? expiresAt
            : calendar.date(byAdding: .second, value: 60 - seconds, to: expiresAt.addingTimeInterval(-Double(nanos) / 1e9))!
        return calendar.dateComponents([.year, .month, .day, .hour, .minute], from: end)
    }

    /// How a timed lock's trigger is told to stop on the hub.
    /// - appOnly:   no end condition (build 4 behavior). Enforcement is proven;
    ///              the lock ends only when the app removes the trigger.
    /// - timeOfDay: Home-app-style time window (hour/minute only) from the lock
    ///              start to its end. The window repeats daily, so the app must
    ///              still remove the trigger later (LockManager removes expired
    ///              triggers at launch, on becoming active, on Release Lock and
    ///              when the expiry notification is handled). HomeKit rejects
    ///              year/month/day in these conditions ("Invalid parameter"), so
    ///              the window can't be pinned to one date. Windows that can't be
    ///              expressed (24 h or more, or start and end in the same
    ///              minute) fall back to appOnly + the expiry notification.
    /// - fullDate:  occurringBefore with year…minute (build 5). Device test of
    ///              build 5 showed the trigger was not enforced at all.
    enum LockEndMode: String, CaseIterable, Identifiable {
        case appOnly, timeOfDay, fullDate
        var id: String { rawValue }
        var title: String {
            switch self {
            case .appOnly: return "No end condition (build 4)"
            case .timeOfDay: return "Time-of-day window"
            case .fullDate: return "Full date (build 5)"
            }
        }
    }

    nonisolated static let lockEndModeKey = "lockEndMode"

    /// Mode used when nothing else is chosen. timeOfDay is build 7's behavior,
    /// confirmed on device (iOS 27.3 beta): the lock is enforced with the app
    /// closed and the hub frees the device at expiry without opening HomeLock.
    nonisolated static let defaultLockEndMode: LockEndMode = .timeOfDay

    /// Release builds always use the default, ignoring any mode left over from
    /// a TestFlight build; only DEBUG builds can pick another mode.
    nonisolated static var lockEndMode: LockEndMode {
        guard AppEnvironment.showsDiagnostics else { return defaultLockEndMode }
        return UserDefaults.standard.string(forKey: lockEndModeKey).flatMap(LockEndMode.init) ?? defaultLockEndMode
    }

    /// End condition for a lock trigger, or nil for "no condition".
    nonisolated static func lockEndPredicate(start: Date, end: Date?, mode: LockEndMode,
                                             calendar: Calendar = .current) -> NSPredicate? {
        guard let end, end > start else { return nil }
        switch mode {
        case .appOnly:
            return nil
        case .fullDate:
            return HMEventTrigger.predicateForEvaluatingTrigger(occurringBefore: lockEndComponents(for: end, calendar: calendar))
        case .timeOfDay:
            // A daily window cannot describe 24 h or more.
            guard end.timeIntervalSince(start) < 24 * 3600 else { return nil }
            // Hour/minute only, built explicitly (no calendar/timeZone fields).
            // The window opens one minute before the lock starts so the current
            // minute is always inside it.
            let openFull = calendar.dateComponents([.hour, .minute], from: start.addingTimeInterval(-60))
            let closeFull = lockEndComponents(for: end, calendar: calendar)
            let open = DateComponents(hour: openFull.hour, minute: openFull.minute)
            let close = DateComponents(hour: closeFull.hour, minute: closeFull.minute)
            let after = HMEventTrigger.predicateForEvaluatingTrigger(occurringAfter: open)
            let before = HMEventTrigger.predicateForEvaluatingTrigger(occurringBefore: close)
            let openMinutes = open.hour! * 60 + open.minute!
            let closeMinutes = close.hour! * 60 + close.minute!
            // Same opening and closing minute (a lock just under 24 h): the
            // window would be "always" or "never". Fall back to no condition.
            guard closeMinutes != openMinutes else { return nil }
            if closeMinutes > openMinutes {
                return NSCompoundPredicate(andPredicateWithSubpredicates: [after, before])
            }
            // Crosses midnight: after the opening time OR before the closing time.
            // createLockTrigger falls back to no condition if HomeKit rejects it.
            return NSCompoundPredicate(orPredicateWithSubpredicates: [after, before])
        }
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

        // Limit check uses only HomeLock's own triggers. Never mass-delete active,
        // unexpired triggers to make room: throw a clear error instead. The trigger
        // being replaced for this same accessory doesn't count against the limit.
        let replacingOwnTrigger = homeLockTriggers.contains { trigger in
            !trigger.name.hasPrefix(actionSetPrefix)
                && (resolveAccessory(for: trigger)?.uniqueIdentifier == accessory.uniqueIdentifier
                    || trigger.name.hasPrefix(triggerPrefix))
        }
        if !replacingOwnTrigger && homeLockTriggers.count >= Self.maxHomeLockTriggers {
            print("🚨 [HomeLock] Trigger limit reached: \(homeLockTriggers.count) HomeLock triggers")
            throw HomeKitError.triggerLimitReached
        }

        print("🔒 [HomeLock] Todos los triggers en home (\(home.triggers.count)):")
        for existingTrigger in home.triggers {
            let isHomeLock = existingTrigger.name.hasPrefix("HomeLock_") ? "🔒" : "  "
            print("   \(isHomeLock) \(existingTrigger.name): enabled=\(existingTrigger.isEnabled)")
        }

        // Remove existing HomeLock_ triggers for this accessory before creating a new
        // one. Matched via the event chain (works for triggers created on any device),
        // plus the legacy name prefix for triggers created on this device. If a removal
        // fails with anything other than not-found, abort: creating would leave a duplicate.
        let triggersToRemove = home.triggers.filter { trigger in
            guard trigger.name.hasPrefix("HomeLock_"), !trigger.name.hasPrefix(actionSetPrefix) else { return false }
            if let resolved = resolveAccessory(for: trigger) {
                return resolved.uniqueIdentifier == accessory.uniqueIdentifier
            }
            return trigger.name.hasPrefix(triggerPrefix)
        }
        print("🧹 [HomeLock] Triggers a eliminar para este dispositivo: \(triggersToRemove.count)")

        for trigger in triggersToRemove {
            print("🧹 [HomeLock] Eliminando trigger existente: \(trigger.name)...")
            try await removeHomeLockTrigger(trigger, in: home)
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

        let isLutron = isLutronDevice(accessory)

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
        // Optional hub-side end condition (see LockEndMode). Indefinite locks
        // (expiresAt == nil) never get one.
        let mode = Self.lockEndMode
        var endPredicate = Self.lockEndPredicate(start: Date(), end: expiresAt, mode: mode)
        print("🔒 [HomeLock] Lock end mode: \(mode.rawValue), predicate: \(endPredicate?.predicateFormat ?? "none")")
        let trigger: HMEventTrigger
        do {
            trigger = try Self.makeLockTrigger(name: triggerName, events: [event], predicate: endPredicate)
        } catch HomeKitError.predicateRejected(let reason) where (endPredicate as? NSCompoundPredicate)?.compoundPredicateType == .or {
            // Overnight window not accepted by this HomeKit: keep the lock, end it from the app.
            print("⚠️ [HomeLock] Overnight end condition rejected (\(reason)); falling back to no end condition")
            endPredicate = nil
            trigger = try Self.makeLockTrigger(name: triggerName, events: [event], predicate: nil)
        }

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


        // Verify what HomeKit actually saved; fail loudly instead of reporting
        // a lock that will not be enforced.
        try verifySavedLockTrigger(trigger.uniqueIdentifier, in: home, expectedPredicate: endPredicate != nil)

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
    /// Creates the HMEventTrigger. HomeKit validates the predicate by raising an
    /// Objective-C exception (NSInvalidArgumentException "Invalid parameter"),
    /// which would crash the app; it is turned into a thrown error instead.
    nonisolated static func makeLockTrigger(name: String, events: [HMEvent], predicate: NSPredicate?) throws -> HMEventTrigger {
        var trigger: HMEventTrigger?
        do {
            try ObjCException.catching {
                trigger = HMEventTrigger(name: name, events: events, predicate: predicate)
            }
        } catch {
            print("❌ [HomeLock] HomeKit rejected the trigger (predicate: \(predicate?.predicateFormat ?? "none")): \(error.localizedDescription)")
            throw HomeKitError.predicateRejected(error.localizedDescription)
        }
        guard let trigger else { throw HomeKitError.triggerCreationFailed }
        return trigger
    }

    /// Re-reads the trigger from home.triggers and checks it is enabled, has
    /// exactly one characteristic event and one action set with one write.
    func verifySavedLockTrigger(_ id: UUID, in home: HMHome, expectedPredicate: Bool) throws {
        guard let saved = home.triggers.first(where: { $0.uniqueIdentifier == id }) as? HMEventTrigger else {
            throw HomeKitError.triggerVerificationFailed("the trigger is not in the home after saving")
        }
        print("🔎 [HomeLock] Saved trigger \(saved.name): enabled=\(saved.isEnabled) events=\(saved.events.count) actionSets=\(saved.actionSets.count) predicate=\(saved.predicate?.predicateFormat ?? "none")")
        guard saved.isEnabled else {
            throw HomeKitError.triggerVerificationFailed("the trigger is saved but not enabled")
        }
        guard saved.events.count == 1, saved.events.first is HMCharacteristicEvent<NSCopying> else {
            throw HomeKitError.triggerVerificationFailed("the trigger has \(saved.events.count) events instead of 1 power event")
        }
        guard saved.actionSets.count == 1, saved.actionSets.first?.actions.count == 1 else {
            throw HomeKitError.triggerVerificationFailed("the trigger's action set is missing or empty")
        }
        if expectedPredicate && saved.predicate == nil {
            throw HomeKitError.triggerVerificationFailed("the end condition was dropped when saving")
        }
    }

    /// Pure rule for the Lutron lock path: skip the power write when a fresh read
    /// shows the device already in the target state. The Caséta bridge rejects
    /// writing the value a device is already in (HMError readWriteFailure).
    /// An unknown state (read failed) never skips.
    nonisolated static func shouldSkipPowerWrite(currentState: Bool?, target: Bool) -> Bool {
        currentState == target
    }

    /// Fresh read of the power state; nil if the read fails (no cached fallback,
    /// so a stale cache can never cause a skipped write).
    func freshPowerState(_ accessory: HMAccessory) async -> Bool? {
        guard let service = getControllableService(for: accessory),
              let powerState = getPowerStateCharacteristic(for: service) else { return nil }
        do {
            try await powerState.readValue()
            return powerState.value as? Bool
        } catch {
            print("⚠️ [HomeKit] Fresh power read failed for \(accessory.name): \(error)")
            return nil
        }
    }

    /// Lutron lock path only: fresh read first; if the device is already in the
    /// target state, skip the write (the bridge would reject it). Otherwise
    /// write and verify like other devices, retrying once after ~1 s if the
    /// bridge answers readWriteFailure. Returns the state the device reports.
    func setLutronPowerForLock(_ accessory: HMAccessory, on: Bool) async throws -> Bool? {
        let current = await freshPowerState(accessory)
        if Self.shouldSkipPowerWrite(currentState: current, target: on) {
            print("⏭️ [HomeKit] \(accessory.name) already \(on ? "on" : "off"); skipping Lutron power write")
            return current
        }
        do {
            return try await setAccessoryPowerVerified(accessory, on: on)
        } catch let error as HMError where error.code == .readWriteFailure {
            // The bridge sometimes rejects a write transiently; retry once after ~1 s.
            print("🔁 [HomeKit] Lutron write failed (readWriteFailure) for \(accessory.name); retrying once in 1s")
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            return try await setAccessoryPowerVerified(accessory, on: on)
        }
    }

    /// Writes the power state, reads it back from the device and retries once.
    /// Returns the state the device reports afterwards (nil if unreadable).
    func setAccessoryPowerVerified(_ accessory: HMAccessory, on: Bool) async throws -> Bool? {
        try await setAccessoryPower(accessory, on: on)
        for attempt in 1...2 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let actual = await isAccessoryOn(accessory)
            print("🔎 [HomeLock] Power write check \(attempt): wanted \(on), device reports \(actual.map(String.init) ?? "unknown")")
            if actual == on || actual == nil { return actual }
            if attempt == 1 { try await setAccessoryPower(accessory, on: on) }
        }
        return await isAccessoryOn(accessory)
    }

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
        // Lutron isolation never blocks removals (spacing is applied in removeHomeLockTrigger).
        guard let home = getHome(for: accessory) else {
            throw HomeKitError.homeNotFound
        }

        // Idempotent: trigger may have been removed by another device already
        guard let trigger = home.triggers.first(where: { $0.uniqueIdentifier == triggerID }) else {
            print("🧹 [HomeLock] Trigger no encontrado, puede que ya haya sido eliminado (idempotent)")
            return
        }

        print("🧹 [HomeLock] Eliminando trigger: \(trigger.name)")
        do {
            try await removeHomeLockTrigger(trigger, in: home)
        } catch {
            // Unexpected (network, bridge unreachable, permissions). "Not found" is
            // already treated as success; rethrow so user-initiated unlocks can
            // report it. Background callers use try? and are unaffected.
            print("⚠️ [HomeLock] WARNING: Trigger removal failed with unexpected error: \(error.localizedDescription) (code: \((error as NSError).code))")
            throw error
        }
    }

    /// Elimina todos los triggers de lock de un accesorio. Matches via the event chain
    /// (triggers created on any device) and the legacy name prefix (this device).
    func removeLockTrigger(for accessory: HMAccessory) async throws {
        // Lutron isolation never blocks removals (spacing is applied in removeHomeLockTrigger).
        guard let home = getHome(for: accessory) else {
            throw HomeKitError.homeNotFound
        }

        let triggerPrefix = "HomeLock_\(accessory.uniqueIdentifier.uuidString)"
        let matchingTriggers = home.triggers.filter { trigger in
            guard trigger.name.hasPrefix("HomeLock_"), !trigger.name.hasPrefix("HomeLock_Revert_") else { return false }
            if let resolved = resolveAccessory(for: trigger) {
                return resolved.uniqueIdentifier == accessory.uniqueIdentifier
            }
            return trigger.name.hasPrefix(triggerPrefix)
        }
        guard !matchingTriggers.isEmpty else { return }

        var firstError: Error?
        for trigger in matchingTriggers {
            do {
                try await removeHomeLockTrigger(trigger, in: home)
            } catch {
                print("⚠️ [HomeLock] WARNING: Trigger removal failed with unexpected error: \(error.localizedDescription) (code: \((error as NSError).code))")
                if firstError == nil { firstError = error }
            }
        }
        // Keep removing the rest, then report the first failure.
        if let firstError { throw firstError }
    }

    /// Elimina TODAS las automatizaciones de HomeLock (triggers y action sets que empiezan con "HomeLock_")
    /// - Returns: Número de elementos eliminados (triggers + action sets)
    func removeAllHomeLockAutomations() async -> Int {
        var removedCount = 0

        for home in homes {
            print("🧹 [HomeLock] Limpiando home: \(home.name)")

            // 1. Eliminar todos los triggers que empiezan con "HomeLock_".
            // Lutron triggers are removed too (isolation never blocks removals);
            // removeHomeLockTrigger spaces Lutron deletions ~1s apart.
            let homeLockTriggers = home.triggers.filter { $0.name.hasPrefix("HomeLock_") }
            print("🧹 [HomeLock] Encontrados \(homeLockTriggers.count) triggers HomeLock_")

            for trigger in homeLockTriggers {
                do {
                    try await removeHomeLockTrigger(trigger, in: home)
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
                    try await removeHomeLockActionSet(actionSet, in: home)
                    removedCount += 1
                } catch {
                    print("⚠️ [HomeLock] No se pudo eliminar ActionSet: \(error.localizedDescription)")
                }
            }
        }

        print("🧹 [HomeLock] Limpieza completada. Eliminados: \(removedCount) elementos")
        return removedCount
    }

    /// Number of HomeLock lock triggers (one per active lock). Action sets are
    /// not counted: each trigger has one, so counting both showed 2 per lock.
    func countHomeLockTriggers() -> Int {
        homes.reduce(0) { $0 + Self.countHomeLockTriggers(named: $1.triggers.map(\.name)) }
    }

    /// Pure count of HomeLock lock triggers among trigger names.
    nonisolated static func countHomeLockTriggers(named names: [String]) -> Int {
        names.filter { $0.hasPrefix("HomeLock_") && !$0.hasPrefix("HomeLock_Revert_") }.count
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
            print("🔍 [HomeKit Sync] Home '\(home.name)': \(homeLockTriggers.count) HomeLock triggers, \(home.accessories.count) accessories")

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
            self.homesLoaded = true

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
    case triggerLimitReached
    case triggerVerificationFailed(String)
    case predicateRejected(String)
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
        case .triggerLimitReached:
            return "HomeLock has reached the maximum of \(HomeKitService.maxHomeLockTriggers) active locks in this home. Unlock a device before locking another."
        case .triggerVerificationFailed(let reason):
            return "The lock was not saved correctly in HomeKit: \(reason)."
        case .predicateRejected(let reason):
            return "HomeKit rejected this lock's end condition (\(reason)). Choose \"No end condition\" in Lock Diagnostics."
        case .unknown:
            return "Error desconocido en HomeKit"
        }
    }
}
