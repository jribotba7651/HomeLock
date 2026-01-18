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
    @State private var showingPaywall: Bool = false

    // New duration picker state
    @State private var untilUnlock: Bool = false
    @State private var selectedHours: Int = 0
    @State private var selectedMinutes: Int = 30

    @Environment(\.dismiss) private var dismiss

    private var lockConfig: LockConfiguration? {
        lockManager.getLock(for: accessory.uniqueIdentifier)
    }

    private var isLocked: Bool {
        lockConfig != nil
    }

    private var selectedDuration: TimeInterval? {
        if untilUnlock {
            return nil
        } else {
            return TimeInterval(selectedHours * 3600 + selectedMinutes * 60)
        }
    }

    private var durationDisplayText: String {
        if untilUnlock {
            return String(localized: "Until I unlock")
        } else if selectedHours == 0 && selectedMinutes == 0 {
            return String(localized: "No time limit")
        } else {
            let hoursText = selectedHours > 0 ? "\(selectedHours) hr" : ""
            let minutesText = selectedMinutes > 0 ? "\(selectedMinutes) min" : ""
            return [hoursText, minutesText].filter { !$0.isEmpty }.joined(separator: " ")
        }
    }

    private var lockButtonText: String {
        if untilUnlock {
            return String(localized: "Lock Device (Until I unlock)")
        } else if selectedHours == 0 && selectedMinutes == 0 {
            return String(localized: "Lock Device (No time limit)")
        } else {
            let hoursText = selectedHours > 0 ? "\(selectedHours)h" : ""
            let minutesText = selectedMinutes > 0 ? "\(selectedMinutes)m" : ""
            let duration = [hoursText, minutesText].filter { !$0.isEmpty }.joined(separator: " ")
            return String(localized: "Lock Device (\(duration))")
        }
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

                    // Duration selector - iOS Timer style
                    VStack(alignment: .leading, spacing: 16) {
                        // "Until I unlock" toggle
                        Toggle(String(localized: "Until I unlock"), isOn: $untilUnlock)
                            .toggleStyle(SwitchToggleStyle(tint: .orange))

                        // Time picker (hidden when "Until I unlock" is selected)
                        if !untilUnlock {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(String(localized: "Duration"))
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                HStack(spacing: 0) {
                                    Picker("Hours", selection: $selectedHours) {
                                        ForEach(0..<13) { hour in
                                            Text("\(hour)").tag(hour)
                                        }
                                    }
                                    .pickerStyle(.wheel)
                                    .frame(width: 80, height: 150)
                                    .clipped()

                                    Text("hr")
                                        .font(.headline)

                                    Picker("Minutes", selection: $selectedMinutes) {
                                        ForEach(0..<60) { minute in
                                            Text("\(minute)").tag(minute)
                                        }
                                    }
                                    .pickerStyle(.wheel)
                                    .frame(width: 80, height: 150)
                                    .clipped()

                                    Text("min")
                                        .font(.headline)
                                }
                                .frame(maxWidth: .infinity)
                            }
                        }
                    }

                    // Lock button
                    Button {
                        // Only show confirmation for indefinite locks (until unlock)
                        if !lockManager.canAddLock {
                            showingPaywall = true
                        } else if untilUnlock {
                            showingLockConfirmation = true
                        } else {
                            // Direct lock for timed locks
                            Task {
                                await lockDevice()
                            }
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if isLocking {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Image(systemName: "lock.fill")
                            }
                            Text(lockButtonText)
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
            String(localized: "Lock \(accessory.name) indefinitely?"),
            isPresented: $showingLockConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Lock until I unlock"), role: .destructive) {
                Task {
                    await lockDevice()
                }
            }
            Button(String(localized: "Cancel"), role: .cancel) { }
        } message: {
            Text(String(localized: "The device will be kept \(lockToState ? "on" : "off") until you manually unlock it."))
        }
        .alert(String(localized: "Error"), isPresented: $showingError) {
            Button("OK") { }
        } message: {
            Text(errorMessage ?? String(localized: "Unknown error"))
        }
        .sheet(isPresented: $showingPaywall) {
            PaywallView()
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
        guard !isLocking else { return }

        guard homeKit.isAuthorized else {
            await MainActor.run {
                errorMessage = "HomeKit not authorized"
                showingError = true
            }
            return
        }

        guard !isLoading else {
            await MainActor.run {
                errorMessage = "Device still loading, please wait"
                showingError = true
            }
            return
        }

        await MainActor.run {
            isLocking = true
        }

        defer {
            Task { @MainActor in
                isLocking = false
            }
        }

        do {
            try await homeKit.setAccessoryPower(accessory, on: lockToState)
            await MainActor.run {
                isOn = lockToState
            }

            let triggerID = try await homeKit.createLockTrigger(
                for: accessory,
                lockedState: lockToState
            )

            await MainActor.run {
                lockManager.addLock(
                    accessoryID: accessory.uniqueIdentifier,
                    accessoryName: accessory.name,
                    triggerID: triggerID,
                    lockedState: lockToState,
                    duration: selectedDuration
                )
            }

            print("DeviceDetailView: Lock activated successfully")

        } catch {
            await MainActor.run {
                errorMessage = String(localized: "Could not lock the device: \(error.localizedDescription)")
                showingError = true
            }
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
