//
//  HistoryView.swift
//  HomeLock
//
//  Created by Claude on 1/18/26.
//

import SwiftUI
import SwiftData

struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \LockEvent.timestamp, order: .reverse) private var events: [LockEvent]

    @State private var selectedFilter: HistoryFilter = .all
    @State private var selectedDevice: UUID?

    enum HistoryFilter: String, CaseIterable {
        case all = "All"
        case today = "Today"
        case week = "This Week"
    }

    var filteredEvents: [LockEvent] {
        var result = events

        // Filtrar por tiempo
        switch selectedFilter {
        case .all:
            break
        case .today:
            let startOfDay = Calendar.current.startOfDay(for: Date())
            result = result.filter { $0.timestamp >= startOfDay }
        case .week:
            let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
            result = result.filter { $0.timestamp >= weekAgo }
        }

        // Filtrar por dispositivo
        if let deviceID = selectedDevice {
            result = result.filter { $0.accessoryUUID == deviceID }
        }

        return result
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Filter picker
                Picker("Filter", selection: $selectedFilter) {
                    ForEach(HistoryFilter.allCases, id: \.self) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .padding()

                if filteredEvents.isEmpty {
                    ContentUnavailableView(
                        "No Events",
                        systemImage: "clock",
                        description: Text("Lock events will appear here")
                    )
                } else {
                    List {
                        ForEach(groupedByDate, id: \.0) { date, events in
                            Section(header: Text(date, style: .date)) {
                                ForEach(events) { event in
                                    HistoryEventRow(event: event)
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("History")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if !events.isEmpty {
                        Menu {
                            Button(role: .destructive) {
                                clearHistory()
                            } label: {
                                Label("Clear History", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
        }
    }

    // Agrupar eventos por día
    var groupedByDate: [(Date, [LockEvent])] {
        let grouped = Dictionary(grouping: filteredEvents) { event in
            Calendar.current.startOfDay(for: event.timestamp)
        }
        return grouped.sorted { $0.key > $1.key }
    }

    private func clearHistory() {
        for event in events {
            modelContext.delete(event)
        }
    }
}

struct HistoryEventRow: View {
    let event: LockEvent

    var eventType: LockEventType {
        LockEventType(rawValue: event.eventType) ?? .locked
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: eventType.icon)
                .font(.title2)
                .foregroundStyle(eventType.color)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.accessoryName)
                    .font(.headline)

                HStack {
                    Text(eventType.rawValue.capitalized)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if let duration = event.duration {
                        Text("• \(formatDuration(duration))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            Text(event.timestamp, style: .time)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}

#Preview {
    HistoryView()
        .modelContainer(for: LockEvent.self, inMemory: true)
}
