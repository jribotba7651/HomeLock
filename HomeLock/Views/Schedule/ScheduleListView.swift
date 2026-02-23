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
    @ObservedObject private var storeManager = StoreManager.shared

    @State private var showingAddSchedule = false
    @State private var showingProRequired = false

    // Free users can have 1 schedule, Pro users get unlimited
    private let freeScheduleLimit = 1

    private var canAddMoreSchedules: Bool {
        storeManager.isPro || schedules.count < freeScheduleLimit
    }

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
                        // Show upgrade banner if at limit
                        if !storeManager.isPro && schedules.count >= freeScheduleLimit {
                            Section {
                                HStack {
                                    Image(systemName: "crown.fill")
                                        .foregroundStyle(.yellow)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Upgrade to Pro")
                                            .font(.subheadline)
                                            .fontWeight(.medium)
                                        Text("Create unlimited schedules")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    showingProRequired = true
                                }
                            }
                        }

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
                        if canAddMoreSchedules {
                            showingAddSchedule = true
                        } else {
                            showingProRequired = true
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddSchedule) {
                AddScheduleView()
            }
            .alert("Pro Required", isPresented: $showingProRequired) {
                Button("Maybe Later", role: .cancel) { }
                Button("View Pro") {
                    // Navigate to settings - this will be handled by the parent
                }
            } message: {
                Text("Upgrade to HomeLock Pro to create unlimited schedules. Free users can have \(freeScheduleLimit) schedule.")
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
