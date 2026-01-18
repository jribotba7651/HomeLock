//
//  SharedLocksView.swift
//  HomeLock
//
//  Created by Claude on 1/18/26.
//

import SwiftUI

/// Vista que muestra todos los locks compartidos por la familia
struct SharedLocksView: View {
    @ObservedObject var familyService: FamilyPermissionService
    @ObservedObject var lockManager: LockManager

    @State private var showingRemoveConfirmation = false
    @State private var lockToRemove: SharedLock?

    private var groupedLocks: [String: [SharedLock]] {
        Dictionary(grouping: familyService.sharedLocks.filter { !$0.isExpired }) { lock in
            lock.roomName ?? String(localized: "No Room")
        }
    }

    var body: some View {
        Group {
            if !familyService.isCloudKitAvailable {
                CloudKitUnavailableView()
            } else if familyService.sharedLocks.isEmpty {
                EmptyLocksView()
            } else {
                locksList
            }
        }
        .navigationTitle(String(localized: "Shared Locks"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if familyService.isSyncing {
                    ProgressView()
                } else {
                    Button {
                        Task {
                            await familyService.syncAll()
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
        .refreshable {
            await familyService.syncAll()
        }
        .confirmationDialog(
            String(localized: "Remove this lock?"),
            isPresented: $showingRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Remove Lock"), role: .destructive) {
                if let lock = lockToRemove {
                    Task {
                        _ = await familyService.removeSharedLock(lockID: lock.id)
                    }
                }
            }
            Button(String(localized: "Cancel"), role: .cancel) {
                lockToRemove = nil
            }
        } message: {
            if let lock = lockToRemove {
                Text(String(localized: "This will unlock \(lock.accessoryName) for all family members."))
            }
        }
    }

    private var locksList: some View {
        List {
            ForEach(groupedLocks.keys.sorted(), id: \.self) { roomName in
                Section {
                    ForEach(groupedLocks[roomName] ?? [], id: \.id) { lock in
                        SharedLockRow(
                            lock: lock,
                            familyService: familyService,
                            onRemove: {
                                lockToRemove = lock
                                showingRemoveConfirmation = true
                            }
                        )
                    }
                } header: {
                    Text(roomName)
                }
            }
        }
    }
}

// MARK: - Supporting Views

struct SharedLockRow: View {
    let lock: SharedLock
    @ObservedObject var familyService: FamilyPermissionService
    let onRemove: () -> Void

    @State private var timeRemaining: TimeInterval?

    private var canRemove: Bool {
        familyService.canDeleteOthersLocks || familyService.isLockOwner(lockID: lock.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)

                        Text(lock.accessoryName)
                            .font(.headline)
                    }

                    HStack(spacing: 4) {
                        Text(String(localized: "Locked"))
                        Text(lock.lockedState ? "ON" : "OFF")
                            .fontWeight(.medium)
                            .foregroundStyle(lock.lockedState ? .green : .secondary)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                if canRemove {
                    Button(role: .destructive) {
                        onRemove()
                    } label: {
                        Image(systemName: "lock.open.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                }
            }

            // Time remaining
            if let remaining = timeRemaining, remaining > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.caption)
                    Text(formatTimeRemaining(remaining))
                        .font(.caption)
                }
                .foregroundStyle(.orange)
            } else if lock.expiresAt == nil {
                HStack(spacing: 4) {
                    Image(systemName: "infinity")
                        .font(.caption)
                    Text(String(localized: "Until unlocked"))
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }

            // Created by info
            HStack(spacing: 4) {
                Image(systemName: "person.fill")
                    .font(.caption2)
                Text(lock.createdByName)
                    .font(.caption)

                Text("·")

                Text(lock.createdAt, style: .relative)
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .onAppear {
            startTimer()
        }
    }

    private func startTimer() {
        timeRemaining = lock.timeRemaining

        guard lock.expiresAt != nil else { return }

        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
            if let remaining = lock.timeRemaining, remaining > 0 {
                timeRemaining = remaining
            } else {
                timer.invalidate()
                timeRemaining = 0
            }
        }
    }

    private func formatTimeRemaining(_ interval: TimeInterval) -> String {
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        let seconds = Int(interval) % 60

        if hours > 0 {
            return String(format: "%dh %dm %ds", hours, minutes, seconds)
        } else if minutes > 0 {
            return String(format: "%dm %ds", minutes, seconds)
        } else {
            return String(format: "%ds", seconds)
        }
    }
}

struct CloudKitUnavailableView: View {
    var body: some View {
        ContentUnavailableView {
            Label(String(localized: "iCloud Required"), systemImage: "icloud.slash")
        } description: {
            Text(String(localized: "Family sharing requires iCloud. Please sign in to iCloud in Settings to use this feature."))
        } actions: {
            Button(String(localized: "Open Settings")) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

struct EmptyLocksView: View {
    var body: some View {
        ContentUnavailableView {
            Label(String(localized: "No Shared Locks"), systemImage: "lock.open")
        } description: {
            Text(String(localized: "When you or family members lock devices with family sharing enabled, they will appear here."))
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        SharedLocksView(
            familyService: FamilyPermissionService.shared,
            lockManager: LockManager.shared
        )
    }
}
