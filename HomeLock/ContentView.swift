//
//  ContentView.swift
//  HomeLock
//
//  Created by Juan C. Ribot on 1/4/26.
//

import SwiftUI
import HomeKit

struct ContentView: View {
    @StateObject private var homeKit = HomeKitService()
    @ObservedObject private var lockManager = LockManager.shared

    @State private var showingCleanupConfirmation = false
    @State private var isCleaningUp = false
    @State private var cleanupResult: Int?

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
                    List(homeKit.outlets, id: \.uniqueIdentifier) { accessory in
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
                }
            }
            .navigationTitle("HomeLock")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button(role: .destructive) {
                            showingCleanupConfirmation = true
                        } label: {
                            Label(String(localized: "Remove all HomeLock automations"), systemImage: "trash")
                        }
                        .disabled(isCleaningUp)
                    } label: {
                        if isCleaningUp {
                            ProgressView()
                        } else {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack {
                        Image(systemName: homeKit.isAuthorized ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(homeKit.isAuthorized ? .green : .secondary)
                        Text("\(homeKit.outlets.count)")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
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
        }
        .onAppear {
            homeKit.requestAuthorization()
        }
        .onChange(of: homeKit.isAuthorized) { _, isAuthorized in
            if isAuthorized {
                lockManager.configure(with: homeKit)
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
}

struct AccessoryRow: View {
    let accessory: HMAccessory
    let homeKit: HomeKitService
    @ObservedObject var lockManager: LockManager

    @State private var isOn: Bool = false
    @State private var isLoading: Bool = true

    private var isLocked: Bool {
        lockManager.isLocked(accessory.uniqueIdentifier)
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
                }

                HStack(spacing: 8) {
                    if let room = accessory.room {
                        Text(room.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if !isLoading {
                        Text(isOn ? String(localized: "On") : String(localized: "Off"))
                            .font(.caption)
                            .foregroundStyle(isOn ? .green : .secondary)
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
    ContentView()
}
