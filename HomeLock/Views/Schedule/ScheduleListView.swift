//
//  ScheduleListView.swift
//  HomeLock
//
//  Created by Claude on 1/18/26.
//

import SwiftUI
import SwiftData

struct ScheduleListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \LockSchedule.createdAt, order: .reverse) private var schedules: [LockSchedule]

    @State private var showingAddSchedule = false

    var body: some View {
        NavigationStack {
            Group {
                if schedules.isEmpty {
                    ContentUnavailableView(
                        "No Schedules",
                        systemImage: "calendar.badge.clock",
                        description: Text("Create schedules to automatically lock devices at specific times")
                    )
                } else {
                    List {
                        ForEach(schedules) { schedule in
                            ScheduleRow(schedule: schedule)
                        }
                        .onDelete(perform: deleteSchedules)
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Schedules")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddSchedule = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddSchedule) {
                AddScheduleView()
            }
        }
    }

    func deleteSchedules(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(schedules[index])
        }
    }
}

struct ScheduleRow: View {
    @Bindable var schedule: LockSchedule

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(schedule.accessoryName)
                    .font(.headline)

                Text(schedule.formattedTimeRange)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text(schedule.formattedDays)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Toggle("", isOn: $schedule.isEnabled)
                .labelsHidden()
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    ScheduleListView()
        .modelContainer(for: LockSchedule.self, inMemory: true)
}
