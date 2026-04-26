//
//  ScheduleManager.swift
//  HomeLock
//
//  Created by Claude on 1/18/26.
//

import Foundation
import SwiftData
import HomeKit
import UserNotifications
import Combine

@MainActor
class ScheduleManager: ObservableObject {
    static let shared = ScheduleManager()

    private var timer: Timer?
    private var modelContext: ModelContext?

    // Track which schedules have active locks created by this manager
    @Published private(set) var activeScheduleLocks: Set<UUID> = [] // schedule IDs with active locks

    private init() {
        print("📅 [ScheduleManager] Initializing singleton instance")
    }

    deinit {
        timer?.invalidate()
        print("📅 [ScheduleManager] ScheduleManager deallocated")
    }

    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext

        startMonitoring()
    }

    func startMonitoring() {
        guard timer == nil else { return }

        print("📅 [ScheduleManager] Starting schedule monitoring (every 60s)")

        // Check schedules every minute
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor [weak self] in
                self?.checkSchedules()
            }
        }

        // Check immediately
        checkSchedules()
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        print("📅 [ScheduleManager] Stopped schedule monitoring")
    }

    func checkSchedules() {
        guard let modelContext = modelContext else {
            print("📅 [ScheduleManager] ModelContext not available")
            return
        }

        let now = Date()
        let calendar = Calendar.current
        let currentDayOfWeek = calendar.component(.weekday, from: now)

        // Fetch enabled schedules
        let descriptor = FetchDescriptor<LockSchedule>(
            predicate: #Predicate { $0.isEnabled }
        )

        guard let schedules = try? modelContext.fetch(descriptor) else {
            print("📅 [ScheduleManager] Failed to fetch schedules")
            return
        }

        print("📅 [ScheduleManager] Checking \(schedules.count) enabled schedules")

        for schedule in schedules {
            // Check if today is a scheduled day
            guard schedule.daysOfWeek.contains(currentDayOfWeek) else {
                // Not scheduled for today, ensure lock is deactivated
                if activeScheduleLocks.contains(schedule.id) {
                    Task {
                        await deactivateLockIfNeeded(for: schedule)
                    }
                }
                continue
            }

            // Check if current time is within schedule
            if isTimeInRange(now: now, start: schedule.startTime, end: schedule.endTime) {
                // Should be locked
                if !activeScheduleLocks.contains(schedule.id) {
                    Task {
                        await activateLockIfNeeded(for: schedule)
                    }
                }
            } else {
                // Should be unlocked
                if activeScheduleLocks.contains(schedule.id) {
                    Task {
                        await deactivateLockIfNeeded(for: schedule)
                    }
                }
            }
        }
    }

    private func isTimeInRange(now: Date, start: Date, end: Date) -> Bool {
        let calendar = Calendar.current
        let nowMinutes = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        let startMinutes = calendar.component(.hour, from: start) * 60 + calendar.component(.minute, from: start)
        let endMinutes = calendar.component(.hour, from: end) * 60 + calendar.component(.minute, from: end)

        if startMinutes <= endMinutes {
            // Same day range (e.g., 9am - 5pm)
            return nowMinutes >= startMinutes && nowMinutes < endMinutes
        } else {
            // Overnight range (e.g., 9pm - 7am)
            return nowMinutes >= startMinutes || nowMinutes < endMinutes
        }
    }

    private func activateLockIfNeeded(for schedule: LockSchedule) async {
        let homeKit = HomeKitService.shared
        let lockManager = LockManager.shared

        // Check if already locked (by any means, not just schedule)
        guard !lockManager.isLocked(schedule.accessoryUUID) else {
            print("📅 [ScheduleManager] \(schedule.accessoryName) already locked")
            activeScheduleLocks.insert(schedule.id)
            return
        }

        // Find the accessory
        guard let accessory = homeKit.outlets.first(where: { $0.uniqueIdentifier == schedule.accessoryUUID }) else {
            print("📅 [ScheduleManager] Accessory not found: \(schedule.accessoryName)")
            return
        }

        // Lutron isolation guard: if isolated, refuse to write. Defense in depth —
        // the outlets filter should already exclude Lutron, but stale schedules
        // from before isolation toggled on could still have Lutron UUIDs.
        if HomeKitService.shouldIgnoreLutron && homeKit.isLutronDevice(accessory) {
            print("🚫 [ScheduleManager] Skipping scheduled lock for isolated Lutron device: \(accessory.name)")
            return
        }

        print("📅 [ScheduleManager] Activating scheduled lock for \(schedule.accessoryName)")

        let isLutron = homeKit.isLutronDevice(accessory)

        do {
            let triggerID: UUID
            if isLutron {
                // Serialize through the bridge gatekeeper to avoid saturating the
                // Caséta Smart Hub's Clear Connect radio.
                triggerID = try await LutronBridgeGatekeeper.shared.run(for: accessory) {
                    try await homeKit.setAccessoryPower(accessory, on: false)
                    return try await homeKit.createLockTrigger(for: accessory, lockedState: false)
                }
            } else {
                try await homeKit.setAccessoryPower(accessory, on: false)
                triggerID = try await homeKit.createLockTrigger(for: accessory, lockedState: false)
            }

            // Add the lock (no expiration for scheduled locks - they're managed by schedule)
            lockManager.addLock(
                accessoryID: accessory.uniqueIdentifier,
                accessoryName: accessory.name,
                triggerID: triggerID,
                lockedState: false,
                duration: nil  // Indefinite - schedule manager controls duration
            )

            activeScheduleLocks.insert(schedule.id)

            // Log event
            logEvent(.locked, accessoryUUID: schedule.accessoryUUID, accessoryName: schedule.accessoryName, notes: "Scheduled lock")

            print("📅 [ScheduleManager] Scheduled lock activated for \(schedule.accessoryName)")

        } catch {
            print("📅 [ScheduleManager] Error activating scheduled lock: \(error)")
        }
    }

    private func deactivateLockIfNeeded(for schedule: LockSchedule) async {
        let lockManager = LockManager.shared

        // Check if locked
        guard lockManager.isLocked(schedule.accessoryUUID) else {
            print("📅 [ScheduleManager] \(schedule.accessoryName) not locked")
            activeScheduleLocks.remove(schedule.id)
            return
        }

        print("📅 [ScheduleManager] Deactivating scheduled lock for \(schedule.accessoryName)")

        await lockManager.removeLock(for: schedule.accessoryUUID)
        activeScheduleLocks.remove(schedule.id)

        // Log event
        logEvent(.expired, accessoryUUID: schedule.accessoryUUID, accessoryName: schedule.accessoryName, notes: "Schedule ended")

        print("📅 [ScheduleManager] Scheduled lock deactivated for \(schedule.accessoryName)")
    }

    // MARK: - Event Logging

    private func logEvent(_ type: LockEventType, accessoryUUID: UUID, accessoryName: String, duration: TimeInterval? = nil, notes: String? = nil) {
        guard let modelContext = modelContext else { return }

        let event = LockEvent(
            accessoryUUID: accessoryUUID,
            accessoryName: accessoryName,
            eventType: type.rawValue,
            duration: duration,
            notes: notes
        )
        modelContext.insert(event)

        print("📝 [ScheduleManager] Logged event: \(type.rawValue) for \(accessoryName)")
    }
}
