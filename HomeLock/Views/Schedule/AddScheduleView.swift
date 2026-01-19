//
//  AddScheduleView.swift
//  HomeLock
//
//  Created by Claude on 1/18/26.
//

import SwiftUI
import SwiftData
import HomeKit

struct AddScheduleView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var homeKit = HomeKitService.shared

    @State private var selectedAccessory: HMAccessory?
    @State private var startTime = Calendar.current.date(from: DateComponents(hour: 21, minute: 0))!
    @State private var endTime = Calendar.current.date(from: DateComponents(hour: 7, minute: 0))!
    @State private var selectedDays: Set<Int> = [2, 3, 4, 5, 6]  // Weekdays default

    let allDays = [
        (1, "Sun"), (2, "Mon"), (3, "Tue"), (4, "Wed"),
        (5, "Thu"), (6, "Fri"), (7, "Sat")
    ]

    var body: some View {
        NavigationStack {
            Form {
                // Device picker
                Section("Device") {
                    Picker("Select Device", selection: $selectedAccessory) {
                        Text("Choose...").tag(nil as HMAccessory?)
                        ForEach(homeKit.outlets, id: \.uniqueIdentifier) { accessory in
                            Text(accessory.name).tag(accessory as HMAccessory?)
                        }
                    }
                }

                // Time range
                Section("Lock Period") {
                    DatePicker("Start", selection: $startTime, displayedComponents: .hourAndMinute)
                    DatePicker("End", selection: $endTime, displayedComponents: .hourAndMinute)
                }

                // Days of week
                Section("Repeat") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 8) {
                        ForEach(allDays, id: \.0) { day, name in
                            DayToggle(
                                name: name,
                                isSelected: selectedDays.contains(day)
                            ) {
                                if selectedDays.contains(day) {
                                    selectedDays.remove(day)
                                } else {
                                    selectedDays.insert(day)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 8)

                    // Quick select
                    HStack {
                        Button("Weekdays") {
                            selectedDays = [2, 3, 4, 5, 6]
                        }
                        .buttonStyle(.bordered)

                        Button("Weekends") {
                            selectedDays = [1, 7]
                        }
                        .buttonStyle(.bordered)

                        Button("Every Day") {
                            selectedDays = [1, 2, 3, 4, 5, 6, 7]
                        }
                        .buttonStyle(.bordered)
                    }
                    .font(.caption)
                }
            }
            .navigationTitle("New Schedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveSchedule()
                        dismiss()
                    }
                    .disabled(selectedAccessory == nil || selectedDays.isEmpty)
                }
            }
        }
    }

    func saveSchedule() {
        guard let accessory = selectedAccessory else { return }

        let schedule = LockSchedule(
            accessoryUUID: accessory.uniqueIdentifier,
            accessoryName: accessory.name,
            startTime: startTime,
            endTime: endTime,
            daysOfWeek: Array(selectedDays).sorted()
        )

        modelContext.insert(schedule)
    }
}

struct DayToggle: View {
    let name: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(name)
                .font(.caption)
                .fontWeight(isSelected ? .bold : .regular)
                .frame(width: 36, height: 36)
                .background(isSelected ? Color.blue : Color.secondary.opacity(0.2))
                .foregroundStyle(isSelected ? .white : .primary)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    AddScheduleView()
        .environmentObject(HomeKitService())
        .modelContainer(for: LockSchedule.self, inMemory: true)
}
