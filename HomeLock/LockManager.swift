//
//  LockManager.swift
//  HomeLock
//
//  Created by Juan C. Ribot on 1/4/26.
//

import Foundation
import Combine
import HomeKit

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
class LockManager: NSObject, ObservableObject, HMAccessoryDelegate {
    static let shared = LockManager()

    @Published private(set) var locks: [UUID: LockConfiguration] = [:] // accessoryID -> config

    private let userDefaultsKey = "HomeLock_ActiveLocks"
    private var expirationTimers: [UUID: Timer] = [:]
    private var homeKitService: HomeKitService?

    // MARK: - Polling (Fallback for HMEventTrigger)
    private var pollingTimer: Timer?
    private let pollingInterval: TimeInterval = 60.0 // Reduced from 5s to 60s to avoid saturating bridges (like Lutron)
    private var isPolling = false
    private var isEnforcing = false // Prevent overlapping enforcement

    private override init() {
        super.init()
        loadLocks()
    }

    deinit {
        pollingTimer?.invalidate()
        pollingTimer = nil
        for timer in expirationTimers.values {
            timer.invalidate()
        }
        expirationTimers.removeAll()
    }

    /// Configura el servicio de HomeKit para poder eliminar triggers
    func configure(with homeKitService: HomeKitService) {
        // Solo configurar si es diferente o es la primera vez
        guard self.homeKitService !== homeKitService else { return }

        self.homeKitService = homeKitService

        // Configurar delegados para accesorios ya lockeados
        for accessory in homeKitService.accessories {
            if locks.keys.contains(accessory.uniqueIdentifier) {
                setupAccessoryMonitoring(accessory)
            }
        }

        // Verificar locks expirados al iniciar
        Task { [weak self] in
            await self?.checkExpiredLocks()
        }

        // Iniciar polling si hay locks activos (como fallback ligero)
        if !locks.isEmpty {
            startPolling()
        }
    }

    private func setupAccessoryMonitoring(_ accessory: HMAccessory) {
        print("🔍 [LockManager] Configurando monitoreo para: \(accessory.name)")
        accessory.delegate = self
        
        // Habilitar notificaciones para la característica de power state
        if let homeKit = homeKitService,
           let service = homeKit.getControllableService(for: accessory),
           let characteristic = homeKit.getPowerStateCharacteristic(for: service) {
            
            characteristic.enableNotification(true) { error in
                if let error {
                    print("⚠️ [LockManager] Error habilitando notificaciones para \(accessory.name): \(error.localizedDescription)")
                } else {
                    print("✅ [LockManager] Notificaciones habilitadas para \(accessory.name)")
                }
            }
        }
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
            NotificationManager.shared.scheduleExpirationNotification(
                for: accessoryName,
                accessoryID: accessoryID,
                at: expiresAt
            )
        }

        // Configurar monitoreo inmediato
        if let homeKit = homeKitService,
           let accessory = homeKit.accessories.first(where: { $0.uniqueIdentifier == accessoryID }) {
            setupAccessoryMonitoring(accessory)
        }

        // Iniciar polling si no estaba corriendo
        startPolling()

        print("🔒 [LockManager] Lock agregado para \(accessoryName), expira: \(expiresAt?.description ?? "nunca")")
    }

    /// Elimina un lock
    func removeLock(for accessoryID: UUID) async {
        guard let config = locks[accessoryID] else { return }

        // Cancelar timer de expiración
        expirationTimers[accessoryID]?.invalidate()
        expirationTimers.removeValue(forKey: accessoryID)
        NotificationManager.shared.cancelNotification(for: accessoryID)

        // Eliminar trigger de HomeKit (best effort, polling is the real enforcement)
        if let homeKit = homeKitService,
           let accessory = homeKit.accessories.first(where: { $0.uniqueIdentifier == accessoryID }) {
            
            // Limpiar monitoreo
            print("🔍 [LockManager] Deteniendo monitoreo para: \(accessory.name)")
            accessory.delegate = nil
            if let service = homeKit.getControllableService(for: accessory),
               let characteristic = homeKit.getPowerStateCharacteristic(for: service) {
                characteristic.enableNotification(false) { _ in }
            }
            
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
        if locks.isEmpty {
            stopPolling()
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

        // Crear timer en el main run loop explícitamente
        let timer = Timer(timeInterval: pollingInterval, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            // Solo ejecutar si no hay otra ejecución en progreso
            guard !self.isEnforcing else {
                print("⏭️ [LockManager] Skipping poll - previous enforcement still running")
                return
            }
            Task { @MainActor [weak self] in
                print("🔄 [LockManager] Periodic poll enforcement starting...")
                await self?.enforceAllLocks()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollingTimer = timer

        // También ejecutar inmediatamente
        Task { [weak self] in
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

    /// Verifica y enforce todos los locks activos
    private func enforceAllLocks() async {
        // Prevent overlapping enforcement
        guard !isEnforcing else { return }
        isEnforcing = true
        defer { isEnforcing = false }

        guard let homeKit = homeKitService else {
            return
        }

        let currentLocks = locks

        for (accessoryID, config) in currentLocks {
            if config.isExpired {
                await removeLock(for: accessoryID)
                continue
            }

            guard let accessory = homeKit.accessories.first(where: { $0.uniqueIdentifier == accessoryID }) else {
                continue
            }

            // En el polling ahora solo leemos si es necesario o para verificar
            // pero siendo mucho más conservadores (60s interval)
            guard let currentState = await homeKit.isAccessoryOn(accessory) else {
                continue
            }

            if currentState != config.lockedState {
                print("🚨 [LockManager] POLLING: Estado incorrecto detectado en \(config.accessoryName)!")
                await enforceLock(accessory, config: config)
            }
        }
    }

    private func enforceLock(_ accessory: HMAccessory, config: LockConfiguration) async {
        guard let homeKit = homeKitService else { return }
        
        do {
            try await homeKit.setAccessoryPower(accessory, on: config.lockedState)
            print("✅ [LockManager] Revertido exitosamente a \(config.lockedState ? "ON" : "OFF")")
        } catch {
            print("❌ [LockManager] Error revirtiendo: \(error.localizedDescription)")
        }
    }

    // MARK: - HMAccessoryDelegate

    nonisolated func accessory(_ accessory: HMAccessory, didUpdateValueFor characteristic: HMCharacteristic) {
        Task { @MainActor in
            guard let config = locks[accessory.uniqueIdentifier] else { return }
            
            if characteristic.characteristicType == HMCharacteristicTypePowerState {
                if let newValue = characteristic.value as? Bool, newValue != config.lockedState {
                    print("🚨 [LockManager] EVENTO: Cambio detectado en \(accessory.name) (\(newValue ? "ON" : "OFF"))")
                    print("   ➡️ Aplicando bloqueo...")
                    await enforceLock(accessory, config: config)
                }
            }
        }
    }

    // MARK: - Persistence

    private func saveLocks() {
        do {
            let data = try JSONEncoder().encode(Array(locks.values))
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        } catch {
            print("❌ [LockManager] Error guardando locks: \(error)")
        }
    }

    private func loadLocks() {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else { return }

        do {
            let configs = try JSONDecoder().decode([LockConfiguration].self, from: data)
            locks = Dictionary(uniqueKeysWithValues: configs.map { ($0.accessoryID, $0) })

            // Re-programar timers para locks con expiración
            for config in configs {
                if let expiresAt = config.expiresAt, !config.isExpired {
                    scheduleExpiration(for: config.accessoryID, at: expiresAt)
                }
            }

            print("🔒 [LockManager] \(locks.count) locks cargados")
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
            Task { [weak self] in
                await self?.handleExpiration(for: accessoryID)
            }
            return
        }

        // Crear timer en el main run loop explícitamente
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] timer in
            timer.invalidate()
            Task { @MainActor [weak self] in
                await self?.handleExpiration(for: accessoryID)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        expirationTimers[accessoryID] = timer
    }

    private func handleExpiration(for accessoryID: UUID) async {
        guard let config = locks[accessoryID] else { return }
        print("⏰ [LockManager] Lock expirado para \(config.accessoryName)")
        await removeLock(for: accessoryID)
    }

    /// Versión simplificada para background tasks
    func checkExpiredLocksInBackground() async {
        print("🗓️ [LockManager] Checking for expired locks in background...")
        let expiredIDs = locks.filter { $0.value.isExpired }.map { $0.key }
        
        for id in expiredIDs {
            await handleExpiration(for: id)
        }
    }

    private func checkExpiredLocks() async {
        for (accessoryID, config) in locks where config.isExpired {
            await removeLock(for: accessoryID)
        }
    }
}
