//
//  LockManager.swift
//  HomeLock
//
//  Created by Juan C. Ribot on 1/4/26.
//

import Foundation
import Combine
import HomeKit
import BackgroundTasks

/// Configuración de un lock persistido
struct LockConfiguration: Codable, Identifiable {
    let id: UUID
    let accessoryID: UUID
    let accessoryName: String
    let roomName: String?
    let triggerID: UUID
    let lockedState: Bool
    let createdAt: Date
    let expiresAt: Date? // nil = indefinido
    let createdByID: String? // Family member ID (nil = local lock)
    let createdByName: String? // Family member name
    let sharedLockID: String? // CloudKit record ID for sync

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() >= expiresAt
    }

    var timeRemaining: TimeInterval? {
        guard let expiresAt else { return nil }
        let remaining = expiresAt.timeIntervalSinceNow
        return remaining > 0 ? remaining : 0
    }

    var isShared: Bool {
        sharedLockID != nil
    }

    // Backwards compatibility initializer
    init(id: UUID = UUID(),
         accessoryID: UUID,
         accessoryName: String,
         roomName: String? = nil,
         triggerID: UUID,
         lockedState: Bool,
         createdAt: Date = Date(),
         expiresAt: Date? = nil,
         createdByID: String? = nil,
         createdByName: String? = nil,
         sharedLockID: String? = nil) {
        self.id = id
        self.accessoryID = accessoryID
        self.accessoryName = accessoryName
        self.roomName = roomName
        self.triggerID = triggerID
        self.lockedState = lockedState
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.createdByID = createdByID
        self.createdByName = createdByName
        self.sharedLockID = sharedLockID
    }
}

/// Maneja la persistencia de locks usando UserDefaults
@MainActor
class LockManager: ObservableObject {
    static let shared = LockManager()

    @Published private(set) var locks: [UUID: LockConfiguration] = [:] // accessoryID -> config
    @Published private(set) var isFamilySyncEnabled = false

    private let userDefaultsKey = "HomeLock_ActiveLocks"
    private var expirationTimers: [UUID: Timer] = [:]
    private var homeKitService: HomeKitService?
    private var familyService: FamilyPermissionService?
    private var cancellables = Set<AnyCancellable>()

    // Background Task Management
    nonisolated static let backgroundTaskIdentifier = "com.jibaroenaluna.homelock.expireLock"

    // MARK: - Polling (Fallback for HMEventTrigger)
    private var pollingTimer: Timer?
    private let pollingInterval: TimeInterval = 5.0 // Check every 5 seconds
    private var isPolling = false
    private var isEnforcing = false // Prevent overlapping enforcement

    private init() {
        print("🏗️ [LockManager] Initializing singleton instance")
        loadLocks()
        registerBackgroundTasks()
    }

    deinit {
        print("🧹 [LockManager] Starting cleanup in deinit...")

        // Capturar referencias locales para evitar problemas de acceso
        let pollingTimer = self.pollingTimer
        let expirationTimers = self.expirationTimers

        // Invalidar polling timer inmediatamente (safe en deinit)
        pollingTimer?.invalidate()

        // Invalidar timers de expiración
        for timer in expirationTimers.values {
            timer.invalidate()
        }

        // Cancelar background task
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundTaskIdentifier)

        print("🧹 [LockManager] LockManager deallocated - \(expirationTimers.count) timers invalidated")
    }

    private func cleanup() {
        print("🧹 [LockManager] Starting cleanup...")

        // Invalidar polling timer
        if pollingTimer != nil {
            print("🧹 [LockManager] Invalidating polling timer")
            pollingTimer?.invalidate()
            pollingTimer = nil
            isPolling = false
        }

        // Invalidar todos los timers de expiración
        let timerCount = expirationTimers.count
        if timerCount > 0 {
            print("🧹 [LockManager] Invalidating \(timerCount) expiration timers")
            for timer in expirationTimers.values {
                timer.invalidate()
            }
            expirationTimers.removeAll()
        }

        // Cancel background task
        print("🧹 [LockManager] Canceling background tasks")
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundTaskIdentifier)

        print("🧹 [LockManager] Cleanup completed")
    }

    /// Configura el servicio de HomeKit para poder eliminar triggers
    func configure(with homeKitService: HomeKitService) {
        // Solo configurar si es diferente o es la primera vez
        guard self.homeKitService !== homeKitService else { return }

        self.homeKitService = homeKitService

        // Verificar locks expirados y triggers huérfanos al iniciar
        Task { [weak self] in
            await self?.checkExpiredLocks()
            await self?.cleanupOrphanedTriggers()
        }

        // Iniciar polling si hay locks activos
        if !locks.isEmpty {
            startPolling()
        }
    }

    /// Configura la sincronización con Family Service
    func configureFamily(with familyService: FamilyPermissionService) {
        guard self.familyService !== familyService else { return }

        self.familyService = familyService
        isFamilySyncEnabled = familyService.isCloudKitAvailable

        // Observar cambios en shared locks
        familyService.$sharedLocks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sharedLocks in
                Task { @MainActor in
                    await self?.syncFromSharedLocks(sharedLocks)
                }
            }
            .store(in: &cancellables)

        familyService.$isCloudKitAvailable
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isAvailable in
                self?.isFamilySyncEnabled = isAvailable
            }
            .store(in: &cancellables)

        print("👨‍👩‍👧‍👦 [LockManager] Family sync configured")
    }

    /// Sincroniza locks locales desde shared locks de CloudKit
    private func syncFromSharedLocks(_ sharedLocks: [SharedLock]) async {
        guard let homeKit = homeKitService else { return }

        print("🔄 [LockManager] Syncing from \(sharedLocks.count) shared locks")

        // Obtener IDs de locks compartidos activos
        let sharedAccessoryIDs = Set(sharedLocks.map { $0.accessoryID })

        // Verificar locks locales que ya no están compartidos
        for (accessoryID, config) in locks {
            if config.isShared, !sharedAccessoryIDs.contains(accessoryID) {
                print("🔓 [LockManager] Removing lock no longer shared: \(config.accessoryName)")
                await removeLock(for: accessoryID)
            }
        }

        // Agregar o actualizar locks compartidos
        for sharedLock in sharedLocks where !sharedLock.isExpired {
            if let existingLock = locks[sharedLock.accessoryID] {
                // Ya existe, verificar si necesita actualización
                if existingLock.sharedLockID != sharedLock.id {
                    print("🔄 [LockManager] Updating lock from shared: \(sharedLock.accessoryName)")
                    // Remover el viejo y crear nuevo
                    await removeLock(for: sharedLock.accessoryID)
                    await createLockFromShared(sharedLock)
                }
            } else {
                // No existe localmente, crear desde shared
                print("➕ [LockManager] Creating local lock from shared: \(sharedLock.accessoryName)")
                await createLockFromShared(sharedLock)
            }
        }
    }

    /// Crea un lock local desde un SharedLock de CloudKit
    private func createLockFromShared(_ sharedLock: SharedLock) async {
        guard let homeKit = homeKitService,
              let accessory = homeKit.accessories.first(where: { $0.uniqueIdentifier == sharedLock.accessoryID }) else {
            print("⚠️ [LockManager] Accessory not found for shared lock: \(sharedLock.accessoryName)")
            return
        }

        do {
            // Establecer el estado bloqueado
            try await homeKit.setAccessoryPower(accessory, on: sharedLock.lockedState)

            // Crear trigger de HomeKit
            let triggerID = try await homeKit.createLockTrigger(for: accessory, lockedState: sharedLock.lockedState)

            // Crear configuración local
            let config = LockConfiguration(
                id: UUID(),
                accessoryID: sharedLock.accessoryID,
                accessoryName: sharedLock.accessoryName,
                roomName: sharedLock.roomName,
                triggerID: triggerID,
                lockedState: sharedLock.lockedState,
                createdAt: sharedLock.createdAt,
                expiresAt: sharedLock.expiresAt,
                createdByID: sharedLock.createdByID,
                createdByName: sharedLock.createdByName,
                sharedLockID: sharedLock.id
            )

            locks[sharedLock.accessoryID] = config
            saveLocks()

            // Programar expiración si tiene tiempo límite
            if let expiresAt = sharedLock.expiresAt {
                scheduleExpiration(for: sharedLock.accessoryID, at: expiresAt)
            }

            startPolling()

            print("✅ [LockManager] Lock created from shared: \(sharedLock.accessoryName)")
        } catch {
            print("❌ [LockManager] Error creating lock from shared: \(error)")
        }
    }

    // MARK: - Public API

    /// Agrega un nuevo lock
    func addLock(
        accessoryID: UUID,
        accessoryName: String,
        roomName: String? = nil,
        triggerID: UUID,
        lockedState: Bool,
        duration: TimeInterval?,
        shareWithFamily: Bool = false,
        homeID: String? = nil
    ) {
        let expiresAt = duration.map { Date().addingTimeInterval($0) }

        // Obtener info del usuario actual si está disponible
        let createdByID = familyService?.currentUser?.id
        let createdByName = familyService?.currentUser?.name

        var sharedLockID: String? = nil

        // Sincronizar con familia si está habilitado
        if shareWithFamily, let familyService = familyService, let homeID = homeID {
            Task {
                if let sharedLock = await familyService.createSharedLock(
                    accessoryID: accessoryID,
                    accessoryName: accessoryName,
                    roomName: roomName,
                    lockedState: lockedState,
                    expiresAt: expiresAt,
                    homeID: homeID
                ) {
                    // Actualizar el lock local con el ID compartido
                    await MainActor.run {
                        if var existingConfig = self.locks[accessoryID] {
                            let updatedConfig = LockConfiguration(
                                id: existingConfig.id,
                                accessoryID: existingConfig.accessoryID,
                                accessoryName: existingConfig.accessoryName,
                                roomName: existingConfig.roomName,
                                triggerID: existingConfig.triggerID,
                                lockedState: existingConfig.lockedState,
                                createdAt: existingConfig.createdAt,
                                expiresAt: existingConfig.expiresAt,
                                createdByID: existingConfig.createdByID,
                                createdByName: existingConfig.createdByName,
                                sharedLockID: sharedLock.id
                            )
                            self.locks[accessoryID] = updatedConfig
                            self.saveLocks()
                        }
                    }
                    print("👨‍👩‍👧‍👦 [LockManager] Lock shared with family: \(accessoryName)")
                }
            }
        }

        let config = LockConfiguration(
            id: UUID(),
            accessoryID: accessoryID,
            accessoryName: accessoryName,
            roomName: roomName,
            triggerID: triggerID,
            lockedState: lockedState,
            createdAt: Date(),
            expiresAt: expiresAt,
            createdByID: createdByID,
            createdByName: createdByName,
            sharedLockID: sharedLockID
        )

        locks[accessoryID] = config
        saveLocks()

        // Programar expiración si tiene tiempo límite
        if let expiresAt {
            scheduleExpiration(for: accessoryID, at: expiresAt)
            scheduleBackgroundTask(for: accessoryID, expiresAt: expiresAt)

            // Programar notificación local
            Task {
                await NotificationManager.shared.scheduleLockExpirationNotification(
                    accessoryID: accessoryID,
                    accessoryName: accessoryName,
                    expiresAt: expiresAt
                )
            }
        }

        // Iniciar polling
        startPolling()

        print("🔒 [LockManager] Lock agregado para \(accessoryName), expira: \(expiresAt?.description ?? "nunca"), compartido: \(shareWithFamily)")
    }

    /// Elimina un lock
    func removeLock(for accessoryID: UUID, removeFromCloud: Bool = true) async {
        guard let config = locks[accessoryID] else { return }

        // Cancelar timer de expiración, background task y notificación
        expirationTimers[accessoryID]?.invalidate()
        expirationTimers.removeValue(forKey: accessoryID)
        cancelBackgroundTask(for: accessoryID)

        // Cancelar notificación local
        Task {
            await NotificationManager.shared.cancelLockExpirationNotification(accessoryID: accessoryID)
        }

        // Eliminar de CloudKit si es un lock compartido
        if removeFromCloud, let sharedLockID = config.sharedLockID, let familyService = familyService {
            Task {
                _ = await familyService.removeSharedLock(lockID: sharedLockID)
            }
        }

        // Eliminar trigger de HomeKit (best effort, polling is the real enforcement)
        if let homeKit = homeKitService,
           let accessory = homeKit.accessories.first(where: { $0.uniqueIdentifier == accessoryID }) {
            do {
                try await homeKit.removeLockTrigger(triggerID: config.triggerID, for: accessory)
            } catch {
                print("⚠️ [LockManager] Error eliminando trigger: \(error)")
            }
        }

        // Eliminar de la lista
        locks.removeValue(forKey: accessoryID)
        saveLocks()

        // Detener polling si no hay más locks
        stopPollingIfNeeded()

        print("🔓 [LockManager] Lock eliminado para \(config.accessoryName)")
    }

    /// Verifica si un accesorio está bloqueado
    func isLocked(_ accessoryID: UUID) -> Bool {
        guard let config = locks[accessoryID] else { return false }
        return !config.isExpired
    }

    /// Obtiene la configuración de lock para un accesorio
    func getLock(for accessoryID: UUID) -> LockConfiguration? {
        guard let config = locks[accessoryID], !config.isExpired else { return nil }
        return config
    }

    // MARK: - Polling Enforcement

    private func startPolling() {
        guard !isPolling else { return }
        isPolling = true

        print("🔄 [LockManager] Iniciando polling cada \(pollingInterval)s")

        // Invalidar timer existente por seguridad
        pollingTimer?.invalidate()

        // Crear timer en el main run loop explícitamente con weak reference
        let timer = Timer(timeInterval: pollingInterval, repeats: true) { [weak self] timer in
            guard let self = self else {
                print("🧹 [LockManager] Self is nil, invalidating timer")
                timer.invalidate()
                return
            }

            Task { @MainActor [weak self] in
                guard let self = self else {
                    timer.invalidate()
                    return
                }

                // Verificar si aún hay locks activos
                if self.locks.isEmpty {
                    print("🛑 [LockManager] No hay locks activos, deteniendo polling")
                    timer.invalidate()
                    self.pollingTimer = nil
                    self.isPolling = false
                    return
                }

                // Solo ejecutar si no hay otra ejecución en progreso
                guard !self.isEnforcing else {
                    print("⏭️ [LockManager] Skipping poll - previous enforcement still running")
                    return
                }
                await self.enforceAllLocks()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollingTimer = timer

        // También ejecutar inmediatamente
        Task { @MainActor [weak self] in
            await self?.enforceAllLocks()
        }
    }

    private func stopPolling() {
        guard isPolling else { return }
        isPolling = false

        pollingTimer?.invalidate()
        pollingTimer = nil

        print("⏹️ [LockManager] Polling detenido")
    }

    private func stopPollingIfNeeded() {
        if locks.isEmpty {
            print("🛑 [LockManager] No hay locks activos, deteniendo polling automáticamente")
            stopPolling()
        }
    }

    /// Verifica y enforce todos los locks activos
    private func enforceAllLocks() async {
        // Prevent overlapping enforcement
        guard !isEnforcing else { return }
        isEnforcing = true
        defer {
            isEnforcing = false
        }

        // Early exit si no hay locks
        guard !locks.isEmpty else {
            print("🛑 [LockManager] No hay locks para enforcer, deteniendo polling")
            stopPollingIfNeeded()
            return
        }

        guard let homeKit = homeKitService else {
            print("⚠️ [LockManager] HomeKitService no disponible")
            return
        }

        // Capturar locks al inicio para evitar mutación durante iteración
        let currentLocks = locks

        for (accessoryID, config) in currentLocks {
            // Verificar si expiró
            if config.isExpired {
                print("⏰ [LockManager] Lock expirado durante polling: \(config.accessoryName)")
                await removeLock(for: accessoryID)
                continue
            }

            // Buscar el accesorio
            guard let accessory = homeKit.accessories.first(where: { $0.uniqueIdentifier == accessoryID }) else {
                print("⚠️ [LockManager] Accesorio no encontrado: \(config.accessoryName)")
                continue
            }

            // Leer estado actual (puede fallar en background)
            guard let currentState = await homeKit.isAccessoryOn(accessory) else {
                // print("⚠️ [LockManager] No se pudo leer estado de: \(config.accessoryName)")
                continue
            }

            // Verificar si el estado es el deseado
            if currentState != config.lockedState {
                print("🚨 [LockManager] Estado incorrecto detectado!")
                print("   Dispositivo: \(config.accessoryName)")
                print("   Estado actual: \(currentState ? "ON" : "OFF")")
                print("   Estado deseado: \(config.lockedState ? "ON" : "OFF")")
                print("   ➡️ Revirtiendo...")

                // Revertir al estado bloqueado
                do {
                    try await homeKit.setAccessoryPower(accessory, on: config.lockedState)
                    print("✅ [LockManager] Revertido exitosamente a \(config.lockedState ? "ON" : "OFF")")
                } catch {
                    print("❌ [LockManager] Error revirtiendo: \(error.localizedDescription)")
                }
            } else {
                // Estado correcto, log silencioso
                // print("✓ [LockManager] \(config.accessoryName): OK")
            }
        }
    }

    // MARK: - Persistence

    nonisolated private func saveLocks() {
        Task { @MainActor in
            do {
                let data = try JSONEncoder().encode(Array(locks.values))
                UserDefaults.standard.set(data, forKey: userDefaultsKey)
            } catch {
                print("❌ [LockManager] Error guardando locks: \(error)")
            }
        }
    }

    nonisolated private func loadLocks() {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else { return }

        do {
            let configs = try JSONDecoder().decode([LockConfiguration].self, from: data)

            Task { @MainActor [weak self] in
                guard let self = self else { return }

                // CRITICAL FIX: Separar locks válidos de expirados ANTES de asignar
                let expiredLocks = configs.filter { $0.isExpired }
                let validLocks = configs.filter { !$0.isExpired }

                // Solo cargar locks válidos (no expirados)
                self.locks = Dictionary(uniqueKeysWithValues: validLocks.map { ($0.accessoryID, $0) })

                print("🔒 [LockManager] Cargando locks: Total=\(configs.count), Válidos=\(validLocks.count), Expirados=\(expiredLocks.count)")

                // Limpiar locks expirados
                for expiredLock in expiredLocks {
                    print("🚨 [LockManager] Lock expirado detectado al cargar: \(expiredLock.accessoryName)")

                    // Cancelar notificación
                    await NotificationManager.shared.cancelLockExpirationNotification(accessoryID: expiredLock.accessoryID)

                    // Limpiar HomeKit trigger directamente (sin usar removeLock ya que no está en self.locks)
                    if let homeKit = self.homeKitService,
                       let accessory = homeKit.accessories.first(where: { $0.uniqueIdentifier == expiredLock.accessoryID }) {
                        do {
                            try await homeKit.removeLockTrigger(triggerID: expiredLock.triggerID, for: accessory)
                            print("✅ [LockManager] Trigger removido para lock expirado: \(expiredLock.accessoryName)")
                        } catch {
                            print("⚠️ [LockManager] Error eliminando trigger expirado: \(error)")
                        }
                    }
                }

                // Re-programar timers, background tasks y notificaciones para locks válidos
                for config in validLocks {
                    if let expiresAt = config.expiresAt {
                        self.scheduleExpiration(for: config.accessoryID, at: expiresAt)
                        self.scheduleBackgroundTask(for: config.accessoryID, expiresAt: expiresAt)

                        // Re-programar notificación
                        await NotificationManager.shared.scheduleLockExpirationNotification(
                            accessoryID: config.accessoryID,
                            accessoryName: config.accessoryName,
                            expiresAt: expiresAt
                        )
                    }
                }

                // Guardar solo locks válidos
                if expiredLocks.count > 0 {
                    self.saveLocks()
                    print("💾 [LockManager] Guardado actualizado sin locks expirados")
                }

                print("🔒 [LockManager] Carga completada: \(self.locks.count) locks activos")
            }
        } catch {
            print("❌ [LockManager] Error cargando locks: \(error)")
        }
    }

    // MARK: - Expiration

    private func scheduleExpiration(for accessoryID: UUID, at date: Date) {
        // Cancelar timer existente
        expirationTimers[accessoryID]?.invalidate()
        expirationTimers.removeValue(forKey: accessoryID)

        let interval = date.timeIntervalSinceNow
        guard interval > 0 else {
            // Ya expiró
            Task { @MainActor [weak self] in
                await self?.handleExpiration(for: accessoryID)
            }
            return
        }

        // Crear timer en el main run loop explícitamente con weak reference
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] timer in
            print("⏰ [LockManager] Timer de expiración ejecutado para accessory: \(accessoryID)")
            timer.invalidate()
            Task { @MainActor [weak self] in
                guard let self = self else {
                    print("🧹 [LockManager] Self is nil en timer de expiración")
                    return
                }
                await self.handleExpiration(for: accessoryID)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        expirationTimers[accessoryID] = timer
    }

    private func handleExpiration(for accessoryID: UUID) async {
        guard let config = locks[accessoryID] else {
            print("⚠️ [LockManager] Config no encontrado para accessoryID en expiración: \(accessoryID)")
            return
        }
        print("⏰ [LockManager] Lock expirado para \(config.accessoryName)")

        // Limpiar timer inmediatamente
        expirationTimers[accessoryID]?.invalidate()
        expirationTimers.removeValue(forKey: accessoryID)

        await removeLock(for: accessoryID)
    }

    private func checkExpiredLocks() async {
        for (accessoryID, config) in locks where config.isExpired {
            await removeLock(for: accessoryID)
        }
    }


    /// Public method for background task to cleanup expired locks
    func cleanupExpiredLocks() async {
        print("🎯 [LockManager] Background cleanup: checking expired locks")

        var expiredCount = 0
        let currentLocks = locks

        for (accessoryID, config) in currentLocks where config.isExpired {
            print("🚨 [LockManager] Found expired lock in background: \(config.accessoryName)")
            await removeLock(for: accessoryID)
            expiredCount += 1
        }

        print("🎯 [LockManager] Background cleanup completed. Expired locks processed: \(expiredCount)")

        // Schedule next background task if there are still active locks
        scheduleNextBackgroundTaskIfNeeded()
    }

    private func cleanupOrphanedTriggers() async {
        guard let homeKit = homeKitService else { return }

        print("🧹 [LockManager] Iniciando limpieza de triggers huérfanos...")

        var removedCount = 0

        for home in homeKit.homes {
            let homeLockTriggers = home.triggers.filter { $0.name.hasPrefix("HomeLock_") }
            print("🔍 [LockManager] Encontrados \(homeLockTriggers.count) triggers HomeLock en \(home.name)")

            for trigger in homeLockTriggers {
                print("🔍 [LockManager] Verificando trigger: \(trigger.name)")

                // Verificar si hay un lock activo para este trigger UUID
                let hasActiveLock = locks.values.contains { lockConfig in
                    lockConfig.triggerID == trigger.uniqueIdentifier && !lockConfig.isExpired
                }

                if !hasActiveLock {
                    print("🚨 [LockManager] Trigger huérfano detectado: \(trigger.name)")

                    do {
                        // Eliminar trigger directamente sin buscar accesorio
                        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                            home.removeTrigger(trigger) { error in
                                if let error {
                                    print("❌ [LockManager] Error eliminando trigger: \(error)")
                                    continuation.resume(throwing: error)
                                } else {
                                    print("✅ [LockManager] Trigger huérfano eliminado: \(trigger.name)")
                                    continuation.resume()
                                }
                            }
                        }

                        // También eliminar ActionSets asociados
                        if let eventTrigger = trigger as? HMEventTrigger {
                            for actionSet in eventTrigger.actionSets {
                                if actionSet.name.hasPrefix("HomeLock_Revert_") {
                                    print("🧹 [LockManager] Eliminando ActionSet asociado: \(actionSet.name)")
                                    try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                                        home.removeActionSet(actionSet) { error in
                                            if let error {
                                                print("⚠️ [LockManager] Error eliminando ActionSet: \(error.localizedDescription)")
                                            }
                                            continuation.resume()
                                        }
                                    }
                                }
                            }
                        }

                        removedCount += 1

                    } catch {
                        print("❌ [LockManager] Error eliminando trigger huérfano: \(error)")
                    }
                } else {
                    print("✅ [LockManager] Trigger válido (tiene lock activo): \(trigger.name)")
                }
            }

            // Limpiar ActionSets huérfanos que no están asociados a ningún trigger
            let homeLockActionSets = home.actionSets.filter { $0.name.hasPrefix("HomeLock_Revert_") }
            for actionSet in homeLockActionSets {
                // Verificar si este ActionSet está asociado a algún trigger activo
                let hasActiveTrigger = home.triggers.contains { trigger in
                    guard let eventTrigger = trigger as? HMEventTrigger else { return false }
                    return eventTrigger.actionSets.contains(where: { $0.uniqueIdentifier == actionSet.uniqueIdentifier })
                }

                if !hasActiveTrigger {
                    print("🚨 [LockManager] ActionSet huérfano detectado: \(actionSet.name)")
                    try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        home.removeActionSet(actionSet) { error in
                            if let error {
                                print("⚠️ [LockManager] Error eliminando ActionSet huérfano: \(error.localizedDescription)")
                            } else {
                                print("✅ [LockManager] ActionSet huérfano eliminado: \(actionSet.name)")
                            }
                            continuation.resume()
                        }
                    }
                    removedCount += 1
                }
            }
        }

        print("🧹 [LockManager] Limpieza completada. Triggers huérfanos eliminados: \(removedCount)")
    }

    // MARK: - Background Tasks

    private func registerBackgroundTasks() {
        // Background task registration is now handled in HomeLockApp.swift
        // This method is kept for consistency but does nothing
        print("🎯 [LockManager] Background task registration delegated to HomeLockApp")
    }

    private func scheduleBackgroundTask(for accessoryID: UUID, expiresAt: Date) {
        // For simplicity, schedule a single background task for the earliest expiration
        // Instead of individual tasks per accessory
        scheduleNextBackgroundTaskIfNeeded()
    }

    private func scheduleNextBackgroundTaskIfNeeded() {
        // Find the earliest expiration among all active locks
        let activeLocks = locks.values.filter { !$0.isExpired }
        guard let earliestExpiration = activeLocks.compactMap(\.expiresAt).min() else {
            print("🛑 [LockManager] No active locks with expiration, no background task needed")
            return
        }

        // Cancel existing background task
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundTaskIdentifier)

        // Schedule new background task
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundTaskIdentifier)
        request.earliestBeginDate = earliestExpiration

        do {
            try BGTaskScheduler.shared.submit(request)
            print("📅 [LockManager] Background task scheduled for: \(earliestExpiration)")
        } catch {
            print("❌ [LockManager] Error scheduling background task: \(error)")
        }
    }

    private func cancelBackgroundTask(for accessoryID: UUID) {
        // Background task cancellation is now handled globally
        // Reschedule background task for remaining locks
        scheduleNextBackgroundTaskIfNeeded()
    }
}
