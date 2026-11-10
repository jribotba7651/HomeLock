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

    // Track which schedules have active locks created by this manager.
    // Persisted (scheduleID -> accessoryUUID) so it survives relaunch and so a
    // deleted schedule's lock can still be released.
    @Published private(set) var activeScheduleLocks: Set<UUID> = [] // schedule IDs with active locks
    private var activeScheduleAccessories: [UUID: UUID] = [:] { // scheduleID -> accessoryUUID
        didSet {
            activeScheduleLocks = Set(activeScheduleAccessories.keys)
            persistActiveScheduleLocks()
        }
    }
    private var inFlight: Set<UUID> = []
    // Schedules whose window started while the accessory already had a lock this
    // manager didn't create (e.g. a manual lock). scheduleID -> window end. The
    // schedule never takes ownership of that lock; this only avoids re-logging the
    // skip every minute for the same window.
    private var skippedWindows: [UUID: Date] = [:]
    private static let activeScheduleLocksKey = "HomeLock_ActiveScheduleLocks"

    private init() {
        print("📅 [ScheduleManager] Initializing singleton instance")
        loadActiveScheduleLocks()
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

    // MARK: - Persistence

    private func persistActiveScheduleLocks() {
        let dict = Dictionary(uniqueKeysWithValues: activeScheduleAccessories.map { ($0.key.uuidString, $0.value.uuidString) })
        UserDefaults.standard.set(dict, forKey: Self.activeScheduleLocksKey)
    }

    private func loadActiveScheduleLocks() {
        guard let dict = UserDefaults.standard.dictionary(forKey: Self.activeScheduleLocksKey) as? [String: String] else { return }
        var restored: [UUID: UUID] = [:]
        for (key, value) in dict {
            if let scheduleID = UUID(uuidString: key), let accessoryID = UUID(uuidString: value) {
                restored[scheduleID] = accessoryID
            }
        }
        activeScheduleAccessories = restored
        print("📅 [ScheduleManager] Restored \(restored.count) active schedule lock(s)")
    }

    // MARK: - Window Math

    /// Returns the end of the schedule window that contains `now`, or nil if `now`
    /// is outside every window. `days` uses Calendar weekdays (1=Sunday ... 7=Saturday).
    /// Overnight windows (start > end, e.g. 21:00-07:00) belong to their START day:
    /// a Monday-only 21:00-07:00 schedule is active Monday 21:00 to Tuesday 07:00.
    /// Equal start and end times never produce an active window.
    nonisolated static func activeWindowEnd(now: Date, start: Date, end: Date, days: [Int], calendar: Calendar = .current) -> Date? {
        let startMinutes = calendar.component(.hour, from: start) * 60 + calendar.component(.minute, from: start)
        let endMinutes = calendar.component(.hour, from: end) * 60 + calendar.component(.minute, from: end)
        let nowMinutes = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        let today = calendar.startOfDay(for: now)

        func at(_ minutes: Int, on day: Date) -> Date? {
            calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day)
        }
        func isScheduled(_ day: Date) -> Bool {
            days.contains(calendar.component(.weekday, from: day))
        }

        if startMinutes < endMinutes {
            // Same-day window
            guard isScheduled(today), nowMinutes >= startMinutes, nowMinutes < endMinutes else { return nil }
            return at(endMinutes, on: today)
        } else if startMinutes > endMinutes {
            // Overnight window
            if nowMinutes >= startMinutes, isScheduled(today),
               let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) {
                return at(endMinutes, on: tomorrow)
            }
            if nowMinutes < endMinutes,
               let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
               isScheduled(yesterday) {
                return at(endMinutes, on: today)
            }
            return nil
        }
        return nil
    }

    // MARK: - Ownership

    enum ActivationDecision: Equatable {
        /// Accessory is free: lock it until the window end and record ownership.
        case lock
        /// Accessory already has a lock the schedule didn't create: leave it alone,
        /// don't record ownership. `log` is true only the first time in a window.
        case skipExistingLock(log: Bool)
    }

    /// Pure ownership decision for a schedule whose window is active and that has no
    /// lock of its own yet.
    nonisolated static func activationDecision(isAccessoryLocked: Bool, skippedWindowEnd: Date?, windowEnd: Date) -> ActivationDecision {
        guard isAccessoryLocked else { return .lock }
        return .skipExistingLock(log: skippedWindowEnd != windowEnd)
    }

    // MARK: - Reconciliation

    /// Reconciles schedules with locks. Called every minute and when the app
    /// returns to foreground.
    func checkSchedules() {
        guard let modelContext = modelContext else {
            print("📅 [ScheduleManager] ModelContext not available")
            return
        }

        let now = Date()

        // Fetch enabled schedules
        let descriptor = FetchDescriptor<LockSchedule>(
            predicate: #Predicate { $0.isEnabled }
        )

        guard let schedules = try? modelContext.fetch(descriptor) else {
            print("📅 [ScheduleManager] Failed to fetch schedules")
            return
        }

        print("📅 [ScheduleManager] Checking \(schedules.count) enabled schedules")

        // Schedules that were disabled or deleted: release their locks
        let enabledIDs = Set(schedules.map(\.id))
        for scheduleID in activeScheduleLocks where !enabledIDs.contains(scheduleID) {
            releaseLock(forScheduleID: scheduleID)
        }

        // Forget skip markers for windows that ended or schedules no longer enabled
        skippedWindows = skippedWindows.filter { enabledIDs.contains($0.key) && $0.value > now }

        for schedule in schedules {
            if let windowEnd = Self.activeWindowEnd(now: now, start: schedule.startTime, end: schedule.endTime, days: schedule.daysOfWeek) {
                // Should be locked
                if !activeScheduleLocks.contains(schedule.id) && !inFlight.contains(schedule.id) {
                    inFlight.insert(schedule.id)
                    Task {
                        await activateLockIfNeeded(for: schedule, until: windowEnd)
                        inFlight.remove(schedule.id)
                    }
                }
            } else if activeScheduleLocks.contains(schedule.id) && !inFlight.contains(schedule.id) {
                // Should be unlocked
                inFlight.insert(schedule.id)
                Task {
                    await deactivateLockIfNeeded(scheduleID: schedule.id, accessoryUUID: schedule.accessoryUUID, accessoryName: schedule.accessoryName)
                    inFlight.remove(schedule.id)
                }
            }
        }
    }

    /// Releases the active lock of a schedule that is being disabled or deleted.
    /// Safe to call when the schedule has no active lock.
    func releaseLock(forScheduleID scheduleID: UUID) {
        guard let accessoryUUID = activeScheduleAccessories[scheduleID], !inFlight.contains(scheduleID) else { return }
        let name = LockManager.shared.locks[accessoryUUID]?.accessoryName ?? ""
        inFlight.insert(scheduleID)
        Task {
            await deactivateLockIfNeeded(scheduleID: scheduleID, accessoryUUID: accessoryUUID, accessoryName: name, notes: "Schedule disabled or deleted")
            inFlight.remove(scheduleID)
        }
    }

    private func activateLockIfNeeded(for schedule: LockSchedule, until windowEnd: Date) async {
        let homeKit = HomeKitService.shared
        let lockManager = LockManager.shared

        // An existing lock (manual, Shortcut, another schedule) is never adopted:
        // the schedule doesn't record it and won't remove it at window end. If that
        // lock ends while the window is still active, the next check locks normally.
        switch Self.activationDecision(
            isAccessoryLocked: lockManager.isLocked(schedule.accessoryUUID),
            skippedWindowEnd: skippedWindows[schedule.id],
            windowEnd: windowEnd
        ) {
        case .skipExistingLock(let log):
            if log {
                print("📅 [ScheduleManager] \(schedule.accessoryName) already locked by another lock; schedule will not take ownership")
            }
            skippedWindows[schedule.id] = windowEnd
            return
        case .lock:
            skippedWindows.removeValue(forKey: schedule.id)
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

        print("📅 [ScheduleManager] Activating scheduled lock for \(schedule.accessoryName) until \(windowEnd)")

        let isLutron = homeKit.isLutronDevice(accessory)

        do {
            // Schedule locks expire at the end of the window (never indefinite), so
            // they are released even if the app isn't running when the window ends.
            let triggerID: UUID
            if isLutron {
                // Serialize through the bridge gatekeeper to avoid saturating the
                // Caséta Smart Hub's Clear Connect radio.
                triggerID = try await LutronBridgeGatekeeper.shared.run(for: accessory) {
                    try await homeKit.setAccessoryPower(accessory, on: false)
                    return try await homeKit.createLockTrigger(for: accessory, lockedState: false, expiresAt: windowEnd)
                }
            } else {
                try await homeKit.setAccessoryPower(accessory, on: false)
                triggerID = try await homeKit.createLockTrigger(for: accessory, lockedState: false, expiresAt: windowEnd)
            }

            lockManager.addLock(
                accessoryID: accessory.uniqueIdentifier,
                accessoryName: accessory.name,
                triggerID: triggerID,
                lockedState: false,
                duration: windowEnd.timeIntervalSinceNow,
                expiresAt: windowEnd
            )

            activeScheduleAccessories[schedule.id] = schedule.accessoryUUID

            // Log event
            logEvent(.locked, accessoryUUID: schedule.accessoryUUID, accessoryName: schedule.accessoryName, notes: "Scheduled lock")

            print("📅 [ScheduleManager] Scheduled lock activated for \(schedule.accessoryName)")

        } catch {
            print("📅 [ScheduleManager] Error activating scheduled lock: \(error)")
        }
    }

    private func deactivateLockIfNeeded(scheduleID: UUID, accessoryUUID: UUID, accessoryName: String, notes: String = "Schedule ended") async {
        let lockManager = LockManager.shared

        // Check if locked (it may already have expired at window end)
        guard lockManager.isLocked(accessoryUUID) else {
            print("📅 [ScheduleManager] \(accessoryName) not locked")
            activeScheduleAccessories.removeValue(forKey: scheduleID)
            return
        }

        print("📅 [ScheduleManager] Deactivating scheduled lock for \(accessoryName)")

        await lockManager.removeLock(for: accessoryUUID)
        activeScheduleAccessories.removeValue(forKey: scheduleID)

        // Log event
        logEvent(.expired, accessoryUUID: accessoryUUID, accessoryName: accessoryName, notes: notes)

        print("📅 [ScheduleManager] Scheduled lock deactivated for \(accessoryName)")
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
