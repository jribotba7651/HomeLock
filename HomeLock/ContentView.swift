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

    var body: some View {
        NavigationStack {
            Group {
                if !homeKit.isAuthorized {
                    ContentUnavailableView(
                        "Conectando a HomeKit",
                        systemImage: "homekit",
                        description: Text("Esperando autorización...")
                    )
                } else if homeKit.outlets.isEmpty {
                    ContentUnavailableView(
                        "Sin dispositivos",
                        systemImage: "poweroutlet.type.b",
                        description: Text("No se encontraron enchufes, switches o luces en tu HomeKit")
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
                        Text(isOn ? "Encendido" : "Apagado")
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
