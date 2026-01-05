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
                            AccessoryRow(accessory: accessory, homeKit: homeKit)
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
    }
}

struct AccessoryRow: View {
    let accessory: HMAccessory
    let homeKit: HomeKitService
    @State private var isOn: Bool = false
    @State private var isLoading: Bool = true

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(accessory.name)
                    .font(.headline)
                if let room = accessory.room {
                    Text(room.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if isLoading {
                ProgressView()
            } else {
                Toggle("", isOn: $isOn)
                    .labelsHidden()
                    .onChange(of: isOn) { _, newValue in
                        Task {
                            try? await homeKit.setAccessoryPower(accessory, on: newValue)
                        }
                    }
            }
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
