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
class LockManager: ObservableObject {
    static let shared = LockManager()

    @Published private(set) var locks: [UUID: LockConfiguration] = [:] // accessoryID -> config

    private let userDefaultsKey = "HomeLock_ActiveLocks"
    private var expirationTimers: [UUID: Timer] = [:]
    private var homeKitService: HomeKitService?

    // MARK: - Polling (Fallback for HMEventTrigger)
    private var pollingTimer: Timer?
    private let pollingInterval: TimeInterval = 5.0 // Check every 5 seconds
    private var isPolling = false
    private var isEnforcing = false // Prevent overlapping enforcement

    private init() {
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

        // Verificar locks expirados al iniciar
        Task { [weak self] in
            await self?.checkExpiredLocks()
        }

        // Iniciar polling si hay locks activos
        if !locks.isEmpty {
            startPolling()
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
        }

        // Iniciar polling
        startPolling()

        print("🔒 [LockManager] Lock agregado para \(accessoryName), expira: \(expiresAt?.description ?? "nunca")")
    }

    /// Elimina un lock
    func removeLock(for accessoryID: UUID) async {
        guard let config = locks[accessoryID] else { return }

        // Cancelar timer de expiración
        expirationTimers[accessoryID]?.invalidate()
        expirationTimers.removeValue(forKey: accessoryID)

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

            // Leer estado actual
            guard let currentState = await homeKit.isAccessoryOn(accessory) else {
                print("⚠️ [LockManager] No se pudo leer estado de: \(config.accessoryName)")
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

    private func checkExpiredLocks() async {
        for (accessoryID, config) in locks where config.isExpired {
            await removeLock(for: accessoryID)
        }
    }
}
