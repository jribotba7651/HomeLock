//
//  DeviceDetailView.swift
//  HomeLock
//
//  Created by Juan C. Ribot on 1/4/26.
//

import SwiftUI
import HomeKit

enum LockDuration: String, CaseIterable, Identifiable {
    case fifteenMinutes = "15 min"
    case thirtyMinutes = "30 min"
    case oneHour = "1 hora"
    case twoHours = "2 horas"
    case untilUnlock = "Hasta desbloquear"

    var id: String { rawValue }

    var seconds: TimeInterval? {
        switch self {
        case .fifteenMinutes: return 15 * 60
        case .thirtyMinutes: return 30 * 60
        case .oneHour: return 60 * 60
        case .twoHours: return 2 * 60 * 60
        case .untilUnlock: return nil
        }
    }

    var displayName: String { rawValue }
}

struct DeviceDetailView: View {
    let accessory: HMAccessory
    @ObservedObject var homeKit: HomeKitService
    @ObservedObject var lockManager = LockManager.shared

    @State private var isOn: Bool = false
    @State private var isLoading: Bool = true
    @State private var isLocking: Bool = false
    @State private var selectedDuration: LockDuration = .thirtyMinutes
    @State private var lockToState: Bool = false
    @State private var showingLockConfirmation: Bool = false
    @State private var errorMessage: String?
    @State private var showingError: Bool = false

    @Environment(\.dismiss) private var dismiss

    private var lockConfig: LockConfiguration? {
        lockManager.getLock(for: accessory.uniqueIdentifier)
    }

    private var isLocked: Bool {
        lockConfig != nil
    }

    var body: some View {
        List {
            // MARK: - Device Info Section
            Section {
                HStack {
                    Label("Estado", systemImage: isOn ? "power.circle.fill" : "power.circle")
                        .foregroundStyle(isOn ? .green : .secondary)
                    Spacer()
                    if isLoading {
                        ProgressView()
                    } else {
                        Text(isOn ? "Encendido" : "Apagado")
                            .foregroundStyle(.secondary)
                    }
                }

                if let room = accessory.room {
                    HStack {
                        Label("Habitación", systemImage: "door.left.hand.closed")
                        Spacer()
                        Text(room.name)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Label("Modelo", systemImage: "info.circle")
                    Spacer()
                    Text(accessory.model ?? "Desconocido")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Información")
            }

            // MARK: - Lock Section
            Section {
                if let config = lockConfig {
                    // Mostrar estado bloqueado
                    LockedStatusView(
                        lockToState: config.lockedState,
                        lockEndTime: config.expiresAt,
                        onUnlock: {
                            Task {
                                await unlockDevice()
                            }
                        }
                    )
                } else {
                    // Selector de estado a bloquear
                    Picker("Bloquear en", selection: $lockToState) {
                        Text("Apagado").tag(false)
                        Text("Encendido").tag(true)
                    }
                    .pickerStyle(.segmented)

                    // Selector de duración
                    Picker("Duración", selection: $selectedDuration) {
                        ForEach(LockDuration.allCases) { duration in
                            Text(duration.displayName).tag(duration)
                        }
                    }

                    // Botón de bloquear
                    Button {
                        showingLockConfirmation = true
                    } label: {
                        HStack {
                            Spacer()
                            if isLocking {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Image(systemName: "lock.fill")
                            }
                            Text("Bloquear dispositivo")
                            Spacer()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(isLocking)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0))
                }
            } header: {
                HStack {
                    Text("Control Parental")
                    if isLocked {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.orange)
                    }
                }
            } footer: {
                if !isLocked {
                    Text("Al bloquear, el dispositivo se mantendrá en el estado seleccionado. Cualquier intento de cambiarlo será revertido automáticamente por HomeKit.")
                }
            }
        }
        .navigationTitle(accessory.name)
        .navigationBarTitleDisplayMode(.large)
        .task {
            await loadCurrentState()
        }
        .confirmationDialog(
            "¿Bloquear \(accessory.name)?",
            isPresented: $showingLockConfirmation,
            titleVisibility: .visible
        ) {
            Button("Bloquear \(selectedDuration.displayName)") {
                Task {
                    await lockDevice()
                }
            }
            Button("Cancelar", role: .cancel) { }
        } message: {
            Text("El dispositivo se mantendrá \(lockToState ? "encendido" : "apagado") durante \(selectedDuration.displayName.lowercased()).")
        }
        .alert("Error", isPresented: $showingError) {
            Button("OK") { }
        } message: {
            Text(errorMessage ?? "Error desconocido")
        }
    }

    private func loadCurrentState() async {
        // Cargar estado actual del dispositivo
        if let state = await homeKit.isAccessoryOn(accessory) {
            isOn = state
            lockToState = state // Por defecto bloquear en el estado actual
        }
        isLoading = false

        // Configurar LockManager con HomeKitService
        lockManager.configure(with: homeKit)
    }

    private func lockDevice() async {
        isLocking = true
        defer { isLocking = false }

        do {
            // 1. Establecer el dispositivo en el estado deseado
            try await homeKit.setAccessoryPower(accessory, on: lockToState)
            isOn = lockToState

            // 2. Crear el HMEventTrigger
            let triggerID = try await homeKit.createLockTrigger(
                for: accessory,
                lockedState: lockToState
            )

            // 3. Persistir la configuración
            lockManager.addLock(
                accessoryID: accessory.uniqueIdentifier,
                accessoryName: accessory.name,
                triggerID: triggerID,
                lockedState: lockToState,
                duration: selectedDuration.seconds
            )

            print("DeviceDetailView: Lock activado exitosamente")

        } catch {
            errorMessage = "No se pudo bloquear el dispositivo: \(error.localizedDescription)"
            showingError = true
            print("DeviceDetailView: Error al bloquear: \(error)")
        }
    }

    private func unlockDevice() async {
        do {
            await lockManager.removeLock(for: accessory.uniqueIdentifier)
            print("DeviceDetailView: Lock desactivado exitosamente")
        }
    }
}

// MARK: - Locked Status View
struct LockedStatusView: View {
    let lockToState: Bool
    let lockEndTime: Date?
    let onUnlock: () -> Void

    @State private var timeRemaining: String = ""
    @State private var timer: Timer?
    @State private var isUnlocking: Bool = false

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "lock.fill")
                    .font(.title)
                    .foregroundStyle(.orange)

                VStack(alignment: .leading) {
                    Text("Dispositivo bloqueado")
                        .font(.headline)
                    Text("Manteniendo \(lockToState ? "encendido" : "apagado")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            if lockEndTime != nil {
                HStack {
                    Image(systemName: "clock")
                    Text("Tiempo restante:")
                    Spacer()
                    Text(timeRemaining)
                        .monospacedDigit()
                        .fontWeight(.semibold)
                }
                .foregroundStyle(.secondary)
            } else {
                HStack {
                    Image(systemName: "infinity")
                    Text("Bloqueado indefinidamente")
                    Spacer()
                }
                .foregroundStyle(.secondary)
            }

            Button(role: .destructive) {
                isUnlocking = true
                onUnlock()
            } label: {
                HStack {
                    Spacer()
                    if isUnlocking {
                        ProgressView()
                    } else {
                        Image(systemName: "lock.open.fill")
                    }
                    Text("Desbloquear")
                    Spacer()
                }
            }
            .buttonStyle(.bordered)
            .disabled(isUnlocking)
        }
        .padding(.vertical, 8)
        .onAppear {
            startTimer()
        }
        .onDisappear {
            timer?.invalidate()
        }
    }

    private func startTimer() {
        updateTimeRemaining()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            updateTimeRemaining()
        }
    }

    private func updateTimeRemaining() {
        guard let endTime = lockEndTime else {
            timeRemaining = ""
            return
        }

        let remaining = endTime.timeIntervalSinceNow
        if remaining <= 0 {
            timeRemaining = "Expirando..."
            timer?.invalidate()
            return
        }

        let hours = Int(remaining) / 3600
        let minutes = (Int(remaining) % 3600) / 60
        let seconds = Int(remaining) % 60

        if hours > 0 {
            timeRemaining = String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            timeRemaining = String(format: "%02d:%02d", minutes, seconds)
        }
    }
}

#Preview {
    NavigationStack {
        Text("Preview requires HomeKit device")
    }
}
