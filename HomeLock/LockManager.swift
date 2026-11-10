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
    /// When set, identifies the family member who created this lock from another
    /// device. Nil for locks created locally. Used to attribute unlock
    /// notifications. Optional so old persisted configs decode without migration.
    var lockedByName: String?

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

enum LockManagerError: LocalizedError {
    case accessoryNotFound
    case lutronNotSupported
    case alreadyLocked

    var errorDescription: String? {
        switch self {
        case .accessoryNotFound:
            return "Device not found."
        case .alreadyLocked:
            return "This device is already locked."
        case .lutronNotSupported:
            return "Lutron devices are currently disabled in HomeLock because their HomeKit bridge loses connection too often, making locks unreliable. You can re-enable them from Settings → HomeKit if you're willing to accept this limitation."
        }
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
    private var modelContext: ModelContext?
    private var homeKitCancellable: AnyCancellable?
    private var syncTimer: Timer?
    private let syncInterval: TimeInterval = 8.0 // Sync every 8s for snappy cross-device updates

    // Background Task Management
    nonisolated static let backgroundTaskIdentifier = "com.jibaroenlaluna.homelock.expireLock"

    // MARK: - Polling (Fallback for HMEventTrigger)
    private var pollingTimer: Timer?
    private let pollingInterval: TimeInterval = 8.0 // Check every 8 seconds (increased from 5)
    private var isPolling = false
    private var isEnforcing = false // Prevent overlapping enforcement
    private var isConfigured = false // Prevent multiple configure() calls
    var isUserOperating = false // Pause polling during user-initiated lock/unlock

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

        isConfigured = false
        print("🧹 [LockManager] Cleanup completed")
    }

    func configure() {
        guard !isConfigured else {
            print("⏭️ [LockManager] Already configured, skipping")
            return
        }
        isConfigured = true

        // Verificar locks expirados al iniciar. Orphan cleanup runs only after
        // a successful sync (see below).
        Task { [weak self] in
            await self?.checkExpiredLocks()
        }

        // Iniciar polling si hay locks activos
        if !locks.isEmpty {
            startPolling()
        }

        // CloudKit Family Sync removed: HomeKit triggers are the source of truth.
        // CloudKitService remains available for history/SharedLocksView but is not
        // used for active lock state.

        // Suscribirse a actualizaciones de HomeKit para sincronización multi-usuario
        homeKitCancellable = HomeKitService.shared.$homesLastUpdated
            .dropFirst()
            .debounce(for: .seconds(3), scheduler: RunLoop.main) // Debounce increased to 3s
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.syncFromHomeKit()
                }
            }

        // Iniciar sincronización periódica
        startSyncTimer()

        // Sincronizar inmediatamente; limpiar triggers huérfanos solo si la sync tuvo éxito
        Task { [weak self] in
            guard let self else { return }
            if await self.syncFromHomeKit() {
                await self.cleanupOrphanedTriggers()
            }
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

    /// Sincroniza el estado local con los triggers de HomeKit.
    /// HomeKit triggers are the SOURCE OF TRUTH for active locks.
    /// UserDefaults is just a local cache for fast UI on cold launch.
    /// - Returns: true if the sync ran to completion.
    @discardableResult
    func syncFromHomeKit() async -> Bool {
        guard !isSyncing else {
            print("⏭️ [LockManager Sync] Ya hay una sincronización en progreso")
            return false
        }

        let homeKit = HomeKitService.shared

        isSyncing = true
        defer {
            isSyncing = false
            lastSyncTime = Date()
        }

        print("🔄 [LockManager Sync] Iniciando sincronización desde HomeKit (source of truth)...")

        // HomeKit triggers are the source of truth
        let detectedLocks = homeKit.getAllActiveLockTriggers()
        var detectedByAccessory: [UUID: HomeKitService.DetectedLock] = [:]
        for (accessoryID, group) in Dictionary(grouping: detectedLocks, by: \.accessoryUUID) {
            guard let keep = Self.newestLock(in: group, knownTriggerID: locks[accessoryID]?.triggerID) else { continue }
            detectedByAccessory[accessoryID] = keep

            // Duplicates: keep the newest trigger, remove the rest
            let extras = group.filter { $0.triggerUUID != keep.triggerUUID }
            if !extras.isEmpty,
               let accessory = homeKit.accessories.first(where: { $0.uniqueIdentifier == accessoryID }) {
                for extra in extras {
                    print("🧹 [LockManager Sync] Removing duplicate trigger for \(extra.accessoryName): \(extra.triggerUUID)")
                    try? await homeKit.removeLockTrigger(triggerID: extra.triggerUUID, for: accessory)
                }
            }
        }
        let detectedAccessoryIDs = Set(detectedByAccessory.keys)
        let localAccessoryIDs = Set(locks.keys)

        var didChange = false

        // 1. ADD or UPDATE locks from HomeKit triggers
        for (accessoryID, detected) in detectedByAccessory {
            // Check if this lock is expired per the trigger name timestamp
            if let expiresAt = detected.expiresAt, Date() >= expiresAt {
                print("⏰ [LockManager Sync] Trigger expired per name timestamp: \(detected.accessoryName), cleaning up")
                logEvent(.expired, accessoryUUID: accessoryID, accessoryName: detected.accessoryName, notes: "Expired (cleaned by sync)")
                // Remove the expired trigger — idempotent
                if let accessory = homeKit.accessories.first(where: { $0.uniqueIdentifier == accessoryID }) {
                    try? await homeKit.removeLockTrigger(triggerID: detected.triggerUUID, for: accessory)
                    try? await homeKit.removeLockTrigger(for: accessory)
                }
                // Remove from local if present
                if locks[accessoryID] != nil {
                    expirationTimers[accessoryID]?.invalidate()
                    expirationTimers.removeValue(forKey: accessoryID)
                    await NotificationManager.shared.cancelLockExpirationNotification(accessoryID: accessoryID)
                    locks.removeValue(forKey: accessoryID)
                    didChange = true
                }
                continue
            }

            if let existing = locks[accessoryID] {
                // UPDATE: refresh expiresAt from HomeKit trigger name if it changed
                if existing.expiresAt != detected.expiresAt || existing.triggerID != detected.triggerUUID {
                    print("🔄 [LockManager Sync] Updating lock from HomeKit: \(detected.accessoryName), expiresAt: \(detected.expiresAt?.description ?? "never")")
                    let updated = LockConfiguration(
                        id: existing.id,
                        accessoryID: accessoryID,
                        accessoryName: detected.accessoryName,
                        triggerID: detected.triggerUUID,
                        lockedState: detected.lockedState,
                        createdAt: existing.createdAt,
                        expiresAt: detected.expiresAt
                    )
                    locks[accessoryID] = updated
                    didChange = true

                    // Reschedule expiration timer with the authoritative timestamp
                    expirationTimers[accessoryID]?.invalidate()
                    expirationTimers.removeValue(forKey: accessoryID)
                    if let expiresAt = detected.expiresAt {
                        scheduleExpiration(for: accessoryID, at: expiresAt)
                        scheduleBackgroundTask(for: accessoryID, expiresAt: expiresAt)
                        Task {
                            await NotificationManager.shared.scheduleLockExpirationNotification(
                                accessoryID: accessoryID,
                                accessoryName: detected.accessoryName,
                                expiresAt: expiresAt
                            )
                        }
                    }
                }
            } else {
                // NEW lock detected from HomeKit (created by another device)
                print("🆕 [LockManager Sync] Nuevo lock detectado desde HomeKit: \(detected.accessoryName), expiresAt: \(detected.expiresAt?.description ?? "never")")

                let config = LockConfiguration(
                    id: UUID(),
                    accessoryID: accessoryID,
                    accessoryName: detected.accessoryName,
                    triggerID: detected.triggerUUID,
                    lockedState: detected.lockedState,
                    createdAt: Date(),
                    expiresAt: detected.expiresAt
                )

                locks[accessoryID] = config
                didChange = true

                // Schedule expiration from the trigger name timestamp
                if let expiresAt = detected.expiresAt {
                    scheduleExpiration(for: accessoryID, at: expiresAt)
                    scheduleBackgroundTask(for: accessoryID, expiresAt: expiresAt)
                    Task {
                        await NotificationManager.shared.scheduleLockExpirationNotification(
                            accessoryID: accessoryID,
                            accessoryName: detected.accessoryName,
                            expiresAt: expiresAt
                        )
                    }
                }

                // Notificar al usuario
                await NotificationManager.shared.showExternalLockNotification(
                    accessoryName: detected.accessoryName,
                    isLocked: true,
                    userName: nil
                )

                logEvent(.locked, accessoryUUID: accessoryID, accessoryName: detected.accessoryName, notes: "Locked by another home member")

                if !isPolling {
                    startPolling()
                }
            }
        }

        // 2. REMOVE locks that no longer have a HomeKit trigger (unlocked by another device)
        for accessoryID in localAccessoryIDs {
            if !detectedAccessoryIDs.contains(accessoryID) {
                if let config = locks[accessoryID] {
                    // Grace period: don't remove recently created locks — trigger may not have synced yet
                    let lockAge = Date().timeIntervalSince(config.createdAt)
                    guard lockAge > 60 else {
                        print("⏭️ [LockManager Sync] Skipping recently created lock: \(config.accessoryName) (age: \(Int(lockAge))s)")
                        continue
                    }
                    print("🔓 [LockManager Sync] Lock eliminado desde HomeKit: \(config.accessoryName)")

                    expirationTimers[accessoryID]?.invalidate()
                    expirationTimers.removeValue(forKey: accessoryID)
                    await NotificationManager.shared.cancelLockExpirationNotification(accessoryID: accessoryID)

                    await NotificationManager.shared.showExternalLockNotification(
                        accessoryName: config.accessoryName,
                        isLocked: false,
                        userName: config.lockedByName
                    )

                    logEvent(.unlocked, accessoryUUID: accessoryID, accessoryName: config.accessoryName, notes: "Unlocked by another home member")

                    locks.removeValue(forKey: accessoryID)
                    didChange = true
                }
            }
        }

        if didChange {
            saveLocks()
            // Force SwiftUI to pick up the changes. @Published on dictionary mutations
            // inside async methods can be coalesced or missed by SwiftUI's observation.
            objectWillChange.send()
            print("🔄 [LockManager Sync] objectWillChange.send() — UI refresh forzado")
        }

        // Detener polling si no hay locks
        stopPollingIfNeeded()

        print("🔄 [LockManager Sync] Sincronización completada. Locks activos: \(locks.count)")
        return true
    }

    /// Picks the trigger to keep when one accessory has several HomeLock_ triggers.
    /// HomeKit exposes no creation date on triggers, so "newest" is: the trigger this
    /// device created most recently (the one recorded in the local lock), otherwise
    /// the one with the latest expiration (indefinite counts as latest).
    nonisolated static func newestLock(in group: [HomeKitService.DetectedLock], knownTriggerID: UUID?) -> HomeKitService.DetectedLock? {
        if let knownTriggerID, let known = group.first(where: { $0.triggerUUID == knownTriggerID }) {
            return known
        }
        return group.max { a, b in
            switch (a.expiresAt, b.expiresAt) {
            case (nil, _): return false
            case (_, nil): return true
            case let (x?, y?): return x < y
            }
        }
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

    /// Locks a device with the given parameters (Shortcuts entry point)
    func lockDevice(accessoryID: UUID, duration: TimeInterval?, lockedState: Bool = false) async throws {
        isUserOperating = true
        defer { isUserOperating = false }

        let homeKit = HomeKitService.shared

        // 0. Asegurar que HomeKit está cargado (crítico para Atajos en background)
        await homeKit.waitServiceReady()

        guard let accessory = homeKit.accessories.first(where: { $0.uniqueIdentifier == accessoryID }) else {
            print("❌ [LockManager] Accessory \(accessoryID) not found")
            throw LockManagerError.accessoryNotFound
        }

        guard !homeKit.isLutronDevice(accessory) else {
            print("🚫 [LockManager] Lutron device blocked: \(accessory.name)")
            throw LockManagerError.lutronNotSupported
        }

        // Don't stack a second lock (and trigger) on an accessory that is already locked
        guard !isLocked(accessoryID) else {
            print("⏭️ [LockManager] Accessory already locked: \(accessory.name)")
            throw LockManagerError.alreadyLocked
        }

        // Compute expiresAt BEFORE creating trigger so it gets embedded in the trigger name
        let expiresAt = duration.map { Date().addingTimeInterval($0) }

        // 1. Set power state (Lutron already rejected above)
        try await homeKit.setAccessoryPower(accessory, on: lockedState)

        // 2. Create trigger with expiration embedded in name
        let triggerID = try await homeKit.createLockTrigger(for: accessory, lockedState: lockedState, expiresAt: expiresAt)

        // 3. Add to local state (UserDefaults cache)
        addLock(
            accessoryID: accessoryID,
            accessoryName: accessory.name,
            triggerID: triggerID,
            lockedState: lockedState,
            duration: duration
        )

        // CloudKit sync removed: HomeKit triggers are now the source of truth
        // for active locks across all devices in the Home.
    }

    /// Agrega un nuevo lock
    func addLock(
        accessoryID: UUID,
        accessoryName: String,
        triggerID: UUID,
        lockedState: Bool,
        duration: TimeInterval?
    ) {
        // Enforce device limit for free users
        guard canAddLock || isLocked(accessoryID) else {
            print("🚫 [LockManager] Device limit reached for free tier")
            return
        }

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

    /// Elimina un lock. Idempotent: if another device already removed the trigger,
    /// this completes without error.
    /// - Parameters:
    ///   - accessoryID: The accessory to unlock
    ///   - logEvent: Whether to log the unlock event (set to false when called from expiration handling)
    func removeLock(for accessoryID: UUID, logEvent: Bool = true) async {
        isUserOperating = true
        defer { isUserOperating = false }

        guard let config = locks[accessoryID] else { return }

        // Cancelar timer de expiración, background task y notificación
        expirationTimers[accessoryID]?.invalidate()
        expirationTimers.removeValue(forKey: accessoryID)
        cancelBackgroundTask(for: accessoryID)

        // Cancelar notificación local
        Task {
            await NotificationManager.shared.cancelLockExpirationNotification(accessoryID: accessoryID)
        }

        // Eliminar trigger de HomeKit — idempotent, another device may have already removed it
        let homeKit = HomeKitService.shared
        await homeKit.waitServiceReady()

        if let accessory = homeKit.accessories.first(where: { $0.uniqueIdentifier == accessoryID }) {
            // Try by trigger UUID first, then by prefix (catches both old and new name formats)
            try? await homeKit.removeLockTrigger(triggerID: config.triggerID, for: accessory)
            try? await homeKit.removeLockTrigger(for: accessory)
        }

        // Eliminar de la lista (UserDefaults cache)
        locks.removeValue(forKey: accessoryID)
        saveLocks()

        // CloudKit sync removed: HomeKit triggers are the source of truth.

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

    /// Indica si el usuario puede agregar más locks basándose en su suscripción
    var canAddLock: Bool {
        if StoreManager.shared.isPro {
            return true
        }
        return locks.count < 2
    }

    /// Obtiene la configuración de lock para un accesorio
    func getLock(for accessoryID: UUID) -> LockConfiguration? {
        guard let config = locks[accessoryID], !config.isExpired else { return nil }
        return config
    }

    /// Returns the lock status and remaining time for an accessory (Shortcuts entry point)
    func getLockStatus(accessoryID: UUID) -> (isLocked: Bool, remainingTime: TimeInterval?) {
        guard let config = locks[accessoryID], !config.isExpired else {
            return (false, nil)
        }
        return (true, config.timeRemaining)
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
            guard self != nil else {
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
                guard !self.isUserOperating else {
                    print("⏭️ [LockManager] Skipping poll - user operation in progress")
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
        // Skip if user is actively locking/unlocking to avoid Code 74
        guard !isUserOperating else {
            print("⏭️ [LockManager] Skipping enforcement - user operation in progress")
            return
        }
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

        let homeKit = HomeKitService.shared

        // Capturar locks al inicio para evitar mutación durante iteración
        let currentLocks = locks

        for (accessoryID, config) in currentLocks {
            // Buscar el accesorio
            guard let accessory = homeKit.accessories.first(where: { $0.uniqueIdentifier == accessoryID }) else {
                print("⚠️ [LockManager] Accesorio no encontrado: \(config.accessoryName)")
                continue
            }

            // Verificar si expiró
            if config.isExpired {
                print("⏰ [LockManager] Lock expirado durante polling: \(config.accessoryName)")
                await removeLock(for: accessoryID)
                continue
            }

            // Leer estado actual (puede fallar en background)
            guard let currentState = await homeKit.isAccessoryOn(accessory) else {
                continue
            }

            // Verificar si el estado es el deseado
            if currentState != config.lockedState {
                print("🚨 [LockManager] Estado incorrecto detectado en \(config.accessoryName)!")

                // Log tamper attempt
                logTamperAttempt(accessoryUUID: accessoryID, accessoryName: config.accessoryName)

                // Show tamper notification
                await NotificationManager.shared.showTamperNotification(accessoryName: config.accessoryName)

                // Revertir al estado bloqueado
                do {
                    try await homeKit.setAccessoryPower(accessory, on: config.lockedState)
                    print("✅ [LockManager] Revertido exitosamente a \(config.lockedState ? "ON" : "OFF")")
                } catch {
                    print("❌ [LockManager] Error revirtiendo: \(error.localizedDescription)")
                }
            }
            
            // Pausa mínima entre accesorios para evitar ráfagas al Wi-Fi
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
        }
    }

    // MARK: - Persistence

    private func saveLocks() {
        do {
            let data = try JSONEncoder().encode(Array(locks.values))
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
            print("💾 [LockManager] Locks guardados: \(locks.count)")
        } catch {
            print("❌ [LockManager] Error guardando locks: \(error)")
        }
    }

    private func loadLocks() {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else { return }

        do {
            let configs = try JSONDecoder().decode([LockConfiguration].self, from: data)
            let expiredLocks = configs.filter { $0.isExpired }
            let validLocks = configs.filter { !$0.isExpired }

            // SINCRONO: locks disponibles inmediatamente para la UI
            self.locks = Dictionary(uniqueKeysWithValues: validLocks.map { ($0.accessoryID, $0) })

            print("🔒 [LockManager] Cargando locks: Total=\(configs.count), Validos=\(validLocks.count), Expirados=\(expiredLocks.count)")

            // SINCRONO: Re-programar expiration timers y background tasks
            for config in validLocks {
                if let expiresAt = config.expiresAt {
                    scheduleExpiration(for: config.accessoryID, at: expiresAt)
                    scheduleBackgroundTask(for: config.accessoryID, expiresAt: expiresAt)
                }
            }

            // SINCRONO: Guardar sin locks expirados
            if !expiredLocks.isEmpty {
                saveLocks()
                print("💾 [LockManager] Guardado actualizado sin locks expirados")
            }

            // ASYNC (no critico): Limpiar triggers expirados y reprogramar notificaciones
            if !expiredLocks.isEmpty || !validLocks.isEmpty {
                Task { @MainActor [weak self] in
                    guard self != nil else { return }

                    for expiredLock in expiredLocks {
                        print("🚨 [LockManager] Lock expirado detectado al cargar: \(expiredLock.accessoryName)")
                        await NotificationManager.shared.cancelLockExpirationNotification(accessoryID: expiredLock.accessoryID)

                        let homeKit = HomeKitService.shared
                        if let accessory = homeKit.accessories.first(where: { $0.uniqueIdentifier == expiredLock.accessoryID }) {
                            do {
                                try await homeKit.removeLockTrigger(triggerID: expiredLock.triggerID, for: accessory)
                                print("✅ [LockManager] Trigger removido para lock expirado: \(expiredLock.accessoryName)")
                            } catch {
                                print("⚠️ [LockManager] Error eliminando trigger expirado: \(error)")
                            }
                        }
                    }

                    for config in validLocks {
                        if let expiresAt = config.expiresAt {
                            await NotificationManager.shared.scheduleLockExpirationNotification(
                                accessoryID: config.accessoryID,
                                accessoryName: config.accessoryName,
                                expiresAt: expiresAt
                            )
                        }
                    }
                }
            }

            print("🔒 [LockManager] Carga completada: \(self.locks.count) locks activos")
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

    /// Public method for checking expired locks when app returns to foreground
    func checkAndCleanExpiredLocks() async {
        print("🔄 [LockManager] Checking for expired locks (app returned to foreground)")
        var expiredCount = 0
        for (accessoryID, config) in locks where config.isExpired {
            print("⏰ [LockManager] Found expired lock: \(config.accessoryName)")
            logEvent(.expired, accessoryUUID: accessoryID, accessoryName: config.accessoryName)
            await removeLock(for: accessoryID, logEvent: false)
            expiredCount += 1
        }
        if expiredCount > 0 {
            print("✅ [LockManager] Auto-released \(expiredCount) expired lock(s)")
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
        let homeKit = HomeKitService.shared
        let isolateLutron = HomeKitService.shouldIgnoreLutron

        print("🧹 [LockManager] Iniciando limpieza de triggers huérfanos...")

        var removedCount = 0

        for home in homeKit.homes {
            let homeLockTriggers = home.triggers.filter { $0.name.hasPrefix("HomeLock_") }
            print("🔍 [LockManager] Encontrados \(homeLockTriggers.count) triggers HomeLock en \(home.name)")

            for trigger in homeLockTriggers {
                print("🔍 [LockManager] Verificando trigger: \(trigger.name)")

                // Aislamiento Lutron: no tocamos triggers Lutron, ni para borrarlos.
                // El bridge se satura con cualquier write y eso es exactamente lo
                // que estamos evitando.
                if isolateLutron && homeKit.triggerReferencesLutron(trigger, in: home) {
                    print("🚫 [LockManager] Skip trigger huérfano Lutron (aislado): \(trigger.name)")
                    continue
                }

                // Orphan decision: resolve the accessory via the trigger's event chain
                // (never via the UUID in the name, which differs per device). Orphaned
                // only if the chain is broken or the _exp timestamp has passed.
                let chainResolved = homeKit.resolveAccessory(for: trigger) != nil
                let expiresAt = HomeKitService.parseTriggerName(trigger.name)?.expiresAt
                let isOrphan = HomeKitService.isOrphanedTrigger(chainResolved: chainResolved, expiresAt: expiresAt)

                if isOrphan {
                    print("🚨 [LockManager] Trigger huérfano detectado (chain: \(chainResolved), exp: \(expiresAt?.description ?? "none")): \(trigger.name)")
                    do {
                        try await homeKit.removeHomeLockTrigger(trigger, in: home)
                        removedCount += 1
                    } catch {
                        print("❌ [LockManager] Error eliminando trigger huérfano: \(error)")
                    }
                } else {
                    print("✅ [LockManager] Trigger válido: \(trigger.name)")
                }
            }

            // Limpiar ActionSets huérfanos que no están asociados a ningún trigger
            let homeLockActionSets = home.actionSets.filter { $0.name.hasPrefix("HomeLock_Revert_") }
            for actionSet in homeLockActionSets {
                // Aislamiento Lutron: si el ActionSet escribe sobre una característica
                // de un accesorio Lutron, lo dejamos en paz para no tocar el bridge.
                if isolateLutron,
                   let action = actionSet.actions.first as? HMCharacteristicWriteAction<NSCopying>,
                   let actionAccessory = action.characteristic.service?.accessory,
                   homeKit.isLutronDevice(actionAccessory) {
                    print("🚫 [LockManager] Skip ActionSet huérfano Lutron (aislado): \(actionSet.name)")
                    continue
                }

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
