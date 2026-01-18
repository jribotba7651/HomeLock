//
//  MainTabView.swift
//  HomeLock
//
//  Created by Claude on 1/18/26.
//

import SwiftUI
import HomeKit

/// Vista principal con tabs para Dispositivos y Familia
struct MainTabView: View {
    @StateObject private var homeKit = HomeKitService()
    @StateObject private var familyService = FamilyPermissionService.shared
    @ObservedObject private var lockManager = LockManager.shared

    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            // Devices Tab
            DevicesTabView(homeKit: homeKit, lockManager: lockManager, familyService: familyService)
                .tabItem {
                    Label(String(localized: "Devices"), systemImage: "poweroutlet.type.b")
                }
                .tag(0)

            // Family Tab
            FamilyView(familyService: familyService, lockManager: lockManager, homeKit: homeKit)
                .tabItem {
                    Label(String(localized: "Family"), systemImage: "person.2.fill")
                }
                .tag(1)
                .badge(familyService.sharedLocks.filter { !$0.isExpired }.count)
        }
        .onAppear {
            homeKit.requestAuthorization()
            Task {
                await familyService.setup()
            }
        }
        .onChange(of: homeKit.isAuthorized) { _, isAuthorized in
            if isAuthorized {
                lockManager.configure(with: homeKit)
                lockManager.configureFamily(with: familyService)
            }
        }
    }
}

/// Vista de la tab de dispositivos (refactorizada de ContentView)
struct DevicesTabView: View {
    @ObservedObject var homeKit: HomeKitService
    @ObservedObject var lockManager: LockManager
    @ObservedObject var familyService: FamilyPermissionService

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
                    devicesList
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
                    HStack(spacing: 16) {
                        // Family sync indicator
                        if lockManager.isFamilySyncEnabled {
                            Image(systemName: "person.2.fill")
                                .foregroundStyle(.blue)
                                .font(.caption)
                        }

                        NavigationLink(destination: SettingsView()) {
                            Image(systemName: "gearshape")
                                .foregroundStyle(.blue)
                        }

                        HStack {
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

    private var devicesList: some View {
        List {
            ForEach(groupedAccessories.keys.sorted(), id: \.self) { roomName in
                Section {
                    ForEach(groupedAccessories[roomName] ?? [], id: \.uniqueIdentifier) { accessory in
                        NavigationLink {
                            DeviceDetailView(
                                accessory: accessory,
                                homeKit: homeKit,
                                familyService: familyService
                            )
                        } label: {
                            AccessoryRow(
                                accessory: accessory,
                                homeKit: homeKit,
                                lockManager: lockManager,
                                familyService: familyService
                            )
                        }
                    }
                } header: {
                    Text(roomName)
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
        print("🚨 [DevicesTab] Emergency unlock started for \(lockCount) locks")

        // Remove all locks using LockManager
        for accessoryID in lockManager.locks.keys {
            await lockManager.removeLock(for: accessoryID)
        }

        // Cancel all pending notifications as well
        await NotificationManager.shared.cancelAllLockExpirationNotifications()

        emergencyUnlockResult = lockCount
        print("🚨 [DevicesTab] Emergency unlock completed for \(lockCount) locks")
    }
}

/// Row de accesorio actualizado con indicador de familia
struct AccessoryRow: View {
    let accessory: HMAccessory
    let homeKit: HomeKitService
    @ObservedObject var lockManager: LockManager
    @ObservedObject var familyService: FamilyPermissionService

    @State private var isOn: Bool = false
    @State private var isLoading: Bool = true

    private var isLocked: Bool {
        lockManager.isLocked(accessory.uniqueIdentifier)
    }

    private var lockConfig: LockConfiguration? {
        lockManager.getLock(for: accessory.uniqueIdentifier)
    }

    private var sharedLock: SharedLock? {
        familyService.hasSharedLock(accessoryID: accessory.uniqueIdentifier)
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
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.orange)
                            .font(.caption2)
                    }

                    // Family shared indicator
                    if lockConfig?.isShared == true || sharedLock != nil {
                        Image(systemName: "person.2.fill")
                            .foregroundStyle(.blue)
                            .font(.caption2)
                    }
                }

                HStack(spacing: 8) {
                    if !isLoading {
                        Text(isOn ? String(localized: "On") : String(localized: "Off"))
                            .font(.caption)
                            .foregroundStyle(isOn ? .green : .secondary)
                    }

                    // Show who locked it if shared
                    if let config = lockConfig, let createdBy = config.createdByName {
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(createdBy)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
    MainTabView()
}
