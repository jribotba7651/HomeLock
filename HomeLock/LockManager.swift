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
import SwiftData

/// Configuración de un lock persistido
struct LockConfiguration: Codable, Identifiable {
    let id: UUID
    let accessoryID: UUID
    let accessoryName: String
    let triggerID: UUID
    let lockedState: Bool
    let createdAt: Date
    let expiresAt: Date? // nil = indefinido

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() >= expiresAt
    }

    var timeRemaining: TimeInterval? {
        guard let expiresAt else { return nil }
        let remaining = expiresAt.timeIntervalSinceNow
        return remaining > 0 ? remaining : 0
    }
}

/// Maneja la persistencia de locks usando UserDefaults
@MainActor
class LockManager: ObservableObject {
    static let shared = LockManager()

    @Published private(set) var locks: [UUID: LockConfiguration] = [:] // accessoryID -> config
    @Published var lastSyncTime: Date?
    @Published var isSyncing: Bool = false

    private let userDefaultsKey = "HomeLock_ActiveLocks"
    private var expirationTimers: [UUID: Timer] = [:]
    private var homeKitService: HomeKitService?
    private var modelContext: ModelContext?
    private var homeKitCancellable: AnyCancellable?
    private var syncTimer: Timer?
    private let syncInterval: TimeInterval = 30.0 // Sync every 30 seconds (increased from 10)

    // Background Task Management
    nonisolated static let backgroundTaskIdentifier = "com.jibaroenaluna.homelock.expireLock"

    // MARK: - Polling (Fallback for HMEventTrigger)
    private var pollingTimer: Timer?
    private let pollingInterval: TimeInterval = 8.0 // Check every 8 seconds (increased from 5)
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

        // Invalidar sync timer
        if syncTimer != nil {
            print("🧹 [LockManager] Invalidating sync timer")
            syncTimer?.invalidate()
            syncTimer = nil
        }

        // Cancelar suscripción a HomeKit
        homeKitCancellable?.cancel()
        homeKitCancellable = nil

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

        // Suscribirse a actualizaciones de HomeKit para sincronización multi-usuario
        homeKitCancellable = homeKitService.$homesLastUpdated
            .dropFirst()
            .debounce(for: .seconds(3), scheduler: RunLoop.main) // Debounce increased to 3s
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.syncFromHomeKit()
                }
            }

        // Iniciar sincronización periódica
        startSyncTimer()

        // Sincronizar inmediatamente
        Task { [weak self] in
            await self?.syncFromHomeKit()
        }
    }

    // MARK: - Multi-User Sync

    private func startSyncTimer() {
        syncTimer?.invalidate()
        syncTimer = Timer.scheduledTimer(withTimeInterval: syncInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.syncFromHomeKit()
            }
        }
        print("🔄 [LockManager] Sync timer iniciado (cada \(syncInterval)s)")
    }

    /// Sincroniza el estado local con los triggers de HomeKit
    /// Esto permite detectar locks creados/eliminados por otros usuarios del hogar
    func syncFromHomeKit() async {
        guard !isSyncing else {
            print("⏭️ [LockManager Sync] Ya hay una sincronización en progreso")
            return
        }

        guard let homeKit = homeKitService else {
            print("⚠️ [LockManager Sync] HomeKitService no disponible")
            return
        }

        isSyncing = true
        defer {
            isSyncing = false
            lastSyncTime = Date()
        }

        print("🔄 [LockManager Sync] Iniciando sincronización desde HomeKit...")

        // Obtener todos los triggers activos de HomeKit
        let detectedLocks = homeKit.getAllActiveLockTriggers()
        let detectedAccessoryIDs = Set(detectedLocks.map { $0.accessoryUUID })
        let localAccessoryIDs = Set(locks.keys)

        // 1. Detectar NUEVOS locks (creados por otros usuarios)
        for detected in detectedLocks {
            if !localAccessoryIDs.contains(detected.accessoryUUID) {
                print("🆕 [LockManager Sync] Nuevo lock detectado desde HomeKit: \(detected.accessoryName)")

                // Agregar a locks locales (sin crear trigger, ya existe)
                let config = LockConfiguration(
                    id: UUID(),
                    accessoryID: detected.accessoryUUID,
                    accessoryName: detected.accessoryName,
                    triggerID: detected.triggerUUID,
                    lockedState: detected.lockedState,
                    createdAt: Date(),
                    expiresAt: nil // Los locks de otros usuarios no tienen expiración conocida
                )

                locks[detected.accessoryUUID] = config
                saveLocks()

                // Notificar al usuario
                await NotificationManager.shared.showExternalLockNotification(
                    accessoryName: detected.accessoryName,
                    isLocked: true
                )

                // Log event
                logEvent(.locked, accessoryUUID: detected.accessoryUUID, accessoryName: detected.accessoryName, notes: "Locked by another home member")

                // Iniciar polling si no estaba activo
                if !isPolling {
                    startPolling()
                }
            }
        }

        // 2. Detectar locks ELIMINADOS (desbloqueados por otros usuarios)
        for accessoryID in localAccessoryIDs {
            if !detectedAccessoryIDs.contains(accessoryID) {
                if let config = locks[accessoryID] {
                    print("🔓 [LockManager Sync] Lock eliminado desde HomeKit: \(config.accessoryName)")

                    // Cancelar timer de expiración si existe
                    expirationTimers[accessoryID]?.invalidate()
                    expirationTimers.removeValue(forKey: accessoryID)

                    // Cancelar notificación de expiración
                    await NotificationManager.shared.cancelLockExpirationNotification(accessoryID: accessoryID)

                    // Notificar al usuario
                    await NotificationManager.shared.showExternalLockNotification(
                        accessoryName: config.accessoryName,
                        isLocked: false
                    )

                    // Log event
                    logEvent(.unlocked, accessoryUUID: accessoryID, accessoryName: config.accessoryName, notes: "Unlocked by another home member")

                    // Eliminar de locks locales
                    locks.removeValue(forKey: accessoryID)
                    saveLocks()
                }
            }
        }

        // Detener polling si no hay locks
        stopPollingIfNeeded()

        print("🔄 [LockManager Sync] Sincronización completada. Locks activos: \(locks.count)")
    }

    /// Configura el ModelContext para el logging de eventos
    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Event Logging

    /// Logs a lock event to the history
    func logEvent(_ type: LockEventType, accessoryUUID: UUID, accessoryName: String, duration: TimeInterval? = nil, notes: String? = nil) {
        guard let modelContext = modelContext else {
            print("⚠️ [LockManager] ModelContext not available for logging")
            return
        }

        let event = LockEvent(
            accessoryUUID: accessoryUUID,
            accessoryName: accessoryName,
            eventType: type.rawValue,
            duration: duration,
            notes: notes
        )
        modelContext.insert(event)

        print("📝 [LockManager] Logged event: \(type.rawValue) for \(accessoryName)")
    }

    /// Logs a tamper attempt (device state changed while locked)
    func logTamperAttempt(accessoryUUID: UUID, accessoryName: String) {
        logEvent(.tamper, accessoryUUID: accessoryUUID, accessoryName: accessoryName, notes: "State change attempt blocked")
    }

    // MARK: - Public API

    /// Agrega un nuevo lock
    func addLock(
        accessoryID: UUID,
        accessoryName: String,
        triggerID: UUID,
        lockedState: Bool,
        duration: TimeInterval?
    ) {
        let expiresAt = duration.map { Date().addingTimeInterval($0) }

        let config = LockConfiguration(
            id: UUID(),
            accessoryID: accessoryID,
            accessoryName: accessoryName,
            triggerID: triggerID,
            lockedState: lockedState,
            createdAt: Date(),
            expiresAt: expiresAt
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

        // Log the lock event
        logEvent(.locked, accessoryUUID: accessoryID, accessoryName: accessoryName, duration: duration)

        print("🔒 [LockManager] Lock agregado para \(accessoryName), expira: \(expiresAt?.description ?? "nunca")")
    }

    /// Elimina un lock
    /// - Parameters:
    ///   - accessoryID: The accessory to unlock
    ///   - logEvent: Whether to log the unlock event (set to false when called from expiration handling)
    func removeLock(for accessoryID: UUID, logEvent: Bool = true) async {
        guard let config = locks[accessoryID] else { return }

        // Cancelar timer de expiración, background task y notificación
        expirationTimers[accessoryID]?.invalidate()
        expirationTimers.removeValue(forKey: accessoryID)
        cancelBackgroundTask(for: accessoryID)

        // Cancelar notificación local
        Task {
            await NotificationManager.shared.cancelLockExpirationNotification(accessoryID: accessoryID)
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

        // Log the unlock event (unless called from expiration handling which logs its own event)
        if logEvent {
            self.logEvent(.unlocked, accessoryUUID: accessoryID, accessoryName: config.accessoryName)
        }

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

                // Log tamper attempt
                logTamperAttempt(accessoryUUID: accessoryID, accessoryName: config.accessoryName)

                // Show tamper notification to all home members
                await NotificationManager.shared.showTamperNotification(accessoryName: config.accessoryName)

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

        // Log the expiration event before removing the lock
        logEvent(.expired, accessoryUUID: accessoryID, accessoryName: config.accessoryName)

        // Limpiar timer inmediatamente
        expirationTimers[accessoryID]?.invalidate()
        expirationTimers.removeValue(forKey: accessoryID)

        await removeLock(for: accessoryID, logEvent: false)
    }

    private func checkExpiredLocks() async {
        for (accessoryID, config) in locks where config.isExpired {
            logEvent(.expired, accessoryUUID: accessoryID, accessoryName: config.accessoryName)
            await removeLock(for: accessoryID, logEvent: false)
        }
    }


    /// Public method for background task to cleanup expired locks
    func cleanupExpiredLocks() async {
        print("🎯 [LockManager] Background cleanup: checking expired locks")

        var expiredCount = 0
        let currentLocks = locks

        for (accessoryID, config) in currentLocks where config.isExpired {
            print("🚨 [LockManager] Found expired lock in background: \(config.accessoryName)")
            logEvent(.expired, accessoryUUID: accessoryID, accessoryName: config.accessoryName)
            await removeLock(for: accessoryID, logEvent: false)
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
