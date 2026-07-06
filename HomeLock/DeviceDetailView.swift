//
//  DeviceDetailView.swift
//  HomeLock
//
//  Created by Juan C. Ribot on 1/4/26.
//

import SwiftUI
import HomeKit

struct DeviceDetailView: View {
    let accessory: HMAccessory
    @ObservedObject var homeKit: HomeKitService
    @ObservedObject var lockManager = LockManager.shared

    @State private var isOn: Bool = false
    @State private var isLoading: Bool = true
    @State private var isLocking: Bool = false
    @State private var lockToState: Bool = false
    @State private var showingLockConfirmation: Bool = false
    @State private var errorMessage: String?
    @State private var showingError: Bool = false
    
    // New duration states
    @State private var durationHours: Int = 0
    @State private var durationMinutes: Int = 30
    @State private var durationSeconds: Int = 0
    @State private var lockIndefinitely: Bool = false

    @Environment(\.dismiss) private var dismiss

    private var totalDurationSeconds: TimeInterval {
        TimeInterval(durationHours * 3600 + durationMinutes * 60 + durationSeconds)
    }

    private var selectedDurationString: String {
        if durationHours > 0 {
            return "\(durationHours)h \(durationMinutes)m \(durationSeconds)s"
        } else if durationMinutes > 0 {
            return "\(durationMinutes)m \(durationSeconds)s"
        } else {
            return "\(durationSeconds)s"
        }
    }

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
                    Label(String(localized: "Status"), systemImage: isOn ? "power.circle.fill" : "power.circle")
                        .foregroundStyle(isOn ? .green : .secondary)
                    Spacer()
                    if isLoading {
                        ProgressView()
                    } else {
                        Text(isOn ? String(localized: "On") : String(localized: "Off"))
                            .foregroundStyle(.secondary)
                    }
                }

                if let room = accessory.room {
                    HStack {
                        Label(String(localized: "Room"), systemImage: "door.left.hand.closed")
                        Spacer()
                        Text(room.name)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Label(String(localized: "Model"), systemImage: "info.circle")
                    Spacer()
                    Text(accessory.model ?? String(localized: "Unknown"))
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(String(localized: "Information"))
            }

            // MARK: - Lock Section
            Section {
                if let config = lockConfig {
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
                    // Lock state selector
                    Picker(String(localized: "Lock to"), selection: $lockToState) {
                        Text(String(localized: "Off")).tag(false)
                        Text(String(localized: "On")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .padding(.vertical, 8)

                    // Duration selector (Native Style)
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(isOn: $lockIndefinitely) {
                            Label(String(localized: "Lock indefinitely"), systemImage: "infinity")
                                .font(.subheadline)
                        }
                        .tint(.orange)
                        
                        if !lockIndefinitely {
                            HStack(spacing: 0) {
                                Spacer()
                                Picker("Hours", selection: $durationHours) {
                                    ForEach(0..<24) { i in
                                        Text("\(i)").tag(i)
                                    }
                                }
                                .pickerStyle(.wheel)
                                .frame(width: 50)
                                .clipped()
                                Text(String(localized: "hours"))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .padding(.trailing, 10)

                                Picker("Min", selection: $durationMinutes) {
                                    ForEach(0..<60) { i in
                                        Text("\(i)").tag(i)
                                    }
                                }
                                .pickerStyle(.wheel)
                                .frame(width: 50)
                                .clipped()
                                Text(String(localized: "min"))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .padding(.trailing, 10)

                                Picker("Sec", selection: $durationSeconds) {
                                    ForEach(0..<60) { i in
                                        Text("\(i)").tag(i)
                                    }
                                }
                                .pickerStyle(.wheel)
                                .frame(width: 50)
                                .clipped()
                                Text(String(localized: "sec"))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                
                                Spacer()
                            }
                            .frame(height: 120)
                            .mask(LinearGradient(gradient: Gradient(colors: [.clear, .black, .black, .clear]), startPoint: .top, endPoint: .bottom))
                        }
                    }
                    .listRowBackground(Color.secondary.opacity(0.05))

                    // Lock button
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
                            Text(String(localized: "Lock device"))
                            Spacer()
                        }
                        .font(.headline)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(isLocking || (!lockIndefinitely && totalDurationSeconds == 0))
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0))
                }
            } header: {
                HStack {
                    Text(String(localized: "Parental Control"))
                    if isLocked {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.orange)
                    }
                }
            } footer: {
                if !isLocked {
                    Text(String(localized: "When locked, the device will stay in the selected state. Any attempt to change it will be automatically reverted by HomeKit."))
                }
            }
        }
        .navigationTitle(accessory.name)
        .navigationBarTitleDisplayMode(.large)
        .task {
            await loadCurrentState()
        }
        .confirmationDialog(
            String(localized: "Lock \(accessory.name)?"),
            isPresented: $showingLockConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: lockIndefinitely ? "Lock indefinitely" : "Lock for \(selectedDurationString)")) {
                Task {
                    await lockDevice()
                }
            }
            Button(String(localized: "Cancel"), role: .cancel) { }
        } message: {
            Text(String(localized: "The device will be kept \(lockToState ? "on" : "off") \(lockIndefinitely ? "indefinitely" : "for " + selectedDurationString)."))
        }
        .alert(String(localized: "Error"), isPresented: $showingError) {
            Button("OK") { }
        } message: {
            Text(errorMessage ?? String(localized: "Unknown error"))
        }
    }

    private func loadCurrentState() async {
        if let state = await homeKit.isAccessoryOn(accessory) {
            isOn = state
            lockToState = state
        }
        isLoading = false
        lockManager.configure(with: homeKit)
    }

    private func lockDevice() async {
        isLocking = true
        defer { isLocking = false }

        do {
            try await homeKit.setAccessoryPower(accessory, on: lockToState)
            isOn = lockToState

            let triggerID = try await homeKit.createLockTrigger(
                for: accessory,
                lockedState: lockToState
            )

            lockManager.addLock(
                accessoryID: accessory.uniqueIdentifier,
                accessoryName: accessory.name,
                triggerID: triggerID,
                lockedState: lockToState,
                duration: lockIndefinitely ? nil : totalDurationSeconds
            )

            print("DeviceDetailView: Lock activated successfully")

        } catch {
            errorMessage = String(localized: "Could not lock the device: \(error.localizedDescription)")
            showingError = true
            print("DeviceDetailView: Error locking: \(error)")
        }
    }

    private func unlockDevice() async {
        await lockManager.removeLock(for: accessory.uniqueIdentifier)
        print("DeviceDetailView: Lock deactivated successfully")
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
                    Text(String(localized: "Device locked"))
                        .font(.headline)
                    Text(String(localized: "Keeping \(lockToState ? "on" : "off")"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            if lockEndTime != nil {
                HStack {
                    Image(systemName: "clock")
                    Text(String(localized: "Time remaining:"))
                    Spacer()
                    Text(timeRemaining)
                        .monospacedDigit()
                        .fontWeight(.semibold)
                }
                .foregroundStyle(.secondary)
            } else {
                HStack {
                    Image(systemName: "infinity")
                    Text(String(localized: "Locked indefinitely"))
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
                    Text(String(localized: "Unlock"))
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
            timeRemaining = String(localized: "Expiring...")
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
