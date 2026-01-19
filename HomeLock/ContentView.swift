//
//  ContentView.swift
//  HomeLock
//
//  Created by Juan C. Ribot on 1/4/26.
//

import SwiftUI
import SwiftData
import HomeKit

struct ContentView: View {
    @ObservedObject private var homeKit = HomeKitService.shared
    @ObservedObject private var lockManager = LockManager.shared
    @ObservedObject private var scheduleManager = ScheduleManager.shared
    @Environment(\.modelContext) private var modelContext

    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardView(homeKit: homeKit, lockManager: lockManager)
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(0)

            ScheduleListView()
                .environmentObject(homeKit)
                .tabItem { Label("Schedule", systemImage: "calendar") }
                .tag(1)

            HistoryView()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(2)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
                .tag(3)
        }
        .onAppear {
            homeKit.requestAuthorization()
        }
        .onChange(of: homeKit.isAuthorized) { _, isAuthorized in
            if isAuthorized {
                lockManager.configure(with: homeKit)
                lockManager.configure(modelContext: modelContext)
                scheduleManager.configure(
                    modelContext: modelContext,
                    homeKitService: homeKit,
                    lockManager: lockManager
                )
            }
        }
    }
}

// MARK: - Dashboard View (formerly main ContentView content)

struct DashboardView: View {
    @ObservedObject var homeKit: HomeKitService
    @ObservedObject var lockManager: LockManager

    @State private var showingCleanupConfirmation = false
    @State private var isCleaningUp = false
    @State private var cleanupResult: Int?
    @State private var showingEmergencyUnlockConfirmation = false
    @State private var isEmergencyUnlocking = false
    @State private var emergencyUnlockResult: Int?

    private var groupedAccessories: [String: [HMAccessory]] {
        Dictionary(grouping: homeKit.outlets) { accessory in
            accessory.room?.name ?? String(localized: "No Room")
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if !homeKit.isAuthorized {
                    ContentUnavailableView(
                        String(localized: "Connecting to HomeKit"),
                        systemImage: "homekit",
                        description: Text(String(localized: "Waiting for authorization..."))
                    )
                } else if homeKit.outlets.isEmpty {
                    ContentUnavailableView(
                        String(localized: "No devices"),
                        systemImage: "poweroutlet.type.b",
                        description: Text(String(localized: "No outlets, switches, or lights found in your HomeKit"))
                    )
                } else {
                    List {
                        ForEach(groupedAccessories.keys.sorted(), id: \.self) { roomName in
                            Section {
                                ForEach(groupedAccessories[roomName] ?? [], id: \.uniqueIdentifier) { accessory in
                                    NavigationLink {
                                        DeviceDetailView(accessory: accessory, homeKit: homeKit)
                                    } label: {
                                        AccessoryRow(
                                            accessory: accessory,
                                            homeKit: homeKit,
                                            lockManager: lockManager
                                        )
                                    }
                                }
                            } header: {
                                Text(roomName)
                            }
                        }
                    }
                }
            }
            .navigationTitle("HomeLock")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        if !lockManager.locks.isEmpty {
                            Button(role: .destructive) {
                                showingEmergencyUnlockConfirmation = true
                            } label: {
                                Label(String(localized: "Liberar todos los locks"), systemImage: "lock.open.fill")
                            }
                            .disabled(isEmergencyUnlocking)

                            Divider()
                        }

                        Button(role: .destructive) {
                            showingCleanupConfirmation = true
                        } label: {
                            Label(String(localized: "Remove all HomeLock automations"), systemImage: "trash")
                        }
                        .disabled(isCleaningUp)
                    } label: {
                        if isCleaningUp || isEmergencyUnlocking {
                            ProgressView()
                        } else {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        // Sync status indicator (tappable for manual sync)
                        Button {
                            Task {
                                await lockManager.syncFromHomeKit()
                            }
                        } label: {
                            if lockManager.isSyncing {
                                HStack(spacing: 4) {
                                    ProgressView()
                                        .scaleEffect(0.6)
                                    Text("Syncing")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            } else if let lastSync = lockManager.lastSyncTime {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                        .foregroundStyle(.green)
                                    Text(lastSync, style: .relative)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .disabled(lockManager.isSyncing)

                        // Device count
                        HStack(spacing: 4) {
                            Image(systemName: homeKit.isAuthorized ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(homeKit.isAuthorized ? .green : .secondary)
                            Text("\(homeKit.outlets.count)")
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }
            }
            .confirmationDialog(
                String(localized: "Remove all HomeLock automations?"),
                isPresented: $showingCleanupConfirmation,
                titleVisibility: .visible
            ) {
                Button(String(localized: "Remove all"), role: .destructive) {
                    Task {
                        await performCleanup()
                    }
                }
                Button(String(localized: "Cancel"), role: .cancel) { }
            } message: {
                Text(String(localized: "This will remove all HomeLock triggers and automations from your HomeKit. Your other automations will not be affected."))
            }
            .confirmationDialog(
                String(localized: "Liberar todos los locks?"),
                isPresented: $showingEmergencyUnlockConfirmation,
                titleVisibility: .visible
            ) {
                Button(String(localized: "Liberar todos"), role: .destructive) {
                    Task {
                        await performEmergencyUnlock()
                    }
                }
                Button(String(localized: "Cancel"), role: .cancel) { }
            } message: {
                Text(String(localized: "Todos los dispositivos bloqueados serán liberados inmediatamente."))
            }
            .alert(
                String(localized: "Cleanup complete"),
                isPresented: Binding(
                    get: { cleanupResult != nil },
                    set: { if !$0 { cleanupResult = nil } }
                )
            ) {
                Button("OK") { cleanupResult = nil }
            } message: {
                if let count = cleanupResult {
                    Text(String(localized: "Removed \(count) HomeLock automation(s)."))
                }
            }
            .alert(
                String(localized: "Locks liberados"),
                isPresented: Binding(
                    get: { emergencyUnlockResult != nil },
                    set: { if !$0 { emergencyUnlockResult = nil } }
                )
            ) {
                Button("OK") { emergencyUnlockResult = nil }
            } message: {
                if let count = emergencyUnlockResult {
                    Text(String(localized: "Se liberaron \(count) locks exitosamente."))
                }
            }
        }
    }

    private func performCleanup() async {
        isCleaningUp = true
        defer { isCleaningUp = false }

        // Also clear local locks
        for accessoryID in lockManager.locks.keys {
            await lockManager.removeLock(for: accessoryID)
        }

        // Remove HomeKit automations
        let removed = await homeKit.removeAllHomeLockAutomations()
        cleanupResult = removed
    }

    private func performEmergencyUnlock() async {
        isEmergencyUnlocking = true
        defer { isEmergencyUnlocking = false }

        let lockCount = lockManager.locks.count
        print("🚨 [DashboardView] Emergency unlock started for \(lockCount) locks")

        // Remove all locks using LockManager
        for accessoryID in lockManager.locks.keys {
            await lockManager.removeLock(for: accessoryID)
        }

        // Cancel all pending notifications as well
        await NotificationManager.shared.cancelAllLockExpirationNotifications()

        emergencyUnlockResult = lockCount
        print("🚨 [DashboardView] Emergency unlock completed for \(lockCount) locks")
    }
}

// MARK: - Accessory Row

struct AccessoryRow: View {
    let accessory: HMAccessory
    let homeKit: HomeKitService
    @ObservedObject var lockManager: LockManager

    @State private var isOn: Bool = false
    @State private var isLoading: Bool = true

    private var isLocked: Bool {
        lockManager.isLocked(accessory.uniqueIdentifier)
    }

    private var lockConfig: LockConfiguration? {
        lockManager.getLock(for: accessory.uniqueIdentifier)
    }

    private var isExternalLock: Bool {
        // A lock without expiration time that we didn't create is from another user
        if let config = lockConfig {
            return config.expiresAt == nil
        }
        return false
    }

    var body: some View {
        HStack(spacing: 12) {
            // Power state indicator
            ZStack {
                Circle()
                    .fill(isLoading ? Color.clear : (isOn ? Color.green : Color.gray.opacity(0.3)))
                    .frame(width: 12, height: 12)

                if isLoading {
                    ProgressView()
                        .scaleEffect(0.5)
                }
            }
            .frame(width: 20)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(accessory.name)
                        .font(.headline)

                    // Lock indicator
                    if isLocked {
                        HStack(spacing: 2) {
                            Image(systemName: "lock.fill")
                                .foregroundStyle(.orange)
                            if isExternalLock {
                                Image(systemName: "person.2.fill")
                                    .foregroundStyle(.blue)
                            }
                        }
                        .font(.caption2)
                    }
                }

                if !isLoading {
                    Text(isOn ? String(localized: "On") : String(localized: "Off"))
                        .font(.caption)
                        .foregroundStyle(isOn ? .green : .secondary)
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
        .task {
            if let state = await homeKit.isAccessoryOn(accessory) {
                isOn = state
            }
            isLoading = false
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [LockEvent.self, LockSchedule.self], inMemory: true)
}
