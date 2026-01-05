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

    @State private var isOn: Bool = false
    @State private var isLoading: Bool = true
    @State private var selectedDuration: LockDuration = .thirtyMinutes
    @State private var lockToState: Bool = false // Estado al que se bloqueará (on/off)
    @State private var isLocked: Bool = false
    @State private var lockEndTime: Date?
    @State private var showingLockConfirmation: Bool = false

    @Environment(\.dismiss) private var dismiss

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
                        Label("Habitación", systemImage: "room")
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
                if isLocked {
                    // Mostrar estado bloqueado
                    LockedStatusView(
                        lockToState: lockToState,
                        lockEndTime: lockEndTime,
                        onUnlock: unlockDevice
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
                            Image(systemName: "lock.fill")
                            Text("Bloquear dispositivo")
                            Spacer()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
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
                    Text("Al bloquear, el dispositivo se mantendrá en el estado seleccionado. Cualquier intento de cambiarlo será revertido automáticamente.")
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
    }

    private func loadCurrentState() async {
        if let state = await homeKit.isAccessoryOn(accessory) {
            isOn = state
            lockToState = state // Por defecto bloquear en el estado actual
        }
        isLoading = false

        // TODO: Cargar estado de lock desde persistencia
    }

    private func lockDevice() async {
        // Primero, establecer el estado deseado
        do {
            try await homeKit.setAccessoryPower(accessory, on: lockToState)
            isOn = lockToState
        } catch {
            print("Error setting power state: \(error)")
        }

        // Calcular tiempo de expiración
        if let seconds = selectedDuration.seconds {
            lockEndTime = Date().addingTimeInterval(seconds)
        } else {
            lockEndTime = nil
        }

        isLocked = true

        // TODO: Crear HMEventTrigger
        // TODO: Persistir configuración
    }

    private func unlockDevice() {
        isLocked = false
        lockEndTime = nil

        // TODO: Eliminar HMEventTrigger
        // TODO: Eliminar de persistencia
    }
}

// MARK: - Locked Status View
struct LockedStatusView: View {
    let lockToState: Bool
    let lockEndTime: Date?
    let onUnlock: () -> Void

    @State private var timeRemaining: String = ""
    @State private var timer: Timer?

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
                onUnlock()
            } label: {
                HStack {
                    Spacer()
                    Image(systemName: "lock.open.fill")
                    Text("Desbloquear")
                    Spacer()
                }
            }
            .buttonStyle(.bordered)
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
            timeRemaining = "Expirado"
            timer?.invalidate()
            onUnlock()
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
