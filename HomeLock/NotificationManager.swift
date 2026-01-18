//
//  NotificationManager.swift
//  HomeLock
//
//  Created by Juan C. Ribot on 1/9/26.
//

import Foundation
import UserNotifications
import Combine

@MainActor
class NotificationManager: ObservableObject {
    static let shared = NotificationManager()

    private init() {
        setupNotificationCategories()
    }

    @Published var isAuthorized: Bool = false

    private func setupNotificationCategories() {
        let releaseAction = UNNotificationAction(
            identifier: "RELEASE_LOCK",
            title: String(localized: "Release Lock"),
            options: [.foreground]
        )

        let keepAction = UNNotificationAction(
            identifier: "KEEP_LOCKED",
            title: String(localized: "Keep Locked"),
            options: [.destructive]
        )

        let category = UNNotificationCategory(
            identifier: "LOCK_EXPIRED",
            actions: [releaseAction, keepAction],
            intentIdentifiers: [],
            options: []
        )

        UNUserNotificationCenter.current().setNotificationCategories([category])
        print("📱 [NotificationManager] Notification categories configured")
    }

    func requestPermission() async {
        let center = UNUserNotificationCenter.current()

        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            isAuthorized = granted

            if granted {
                print("📱 [NotificationManager] Notification permission granted")
            } else {
                print("📱 [NotificationManager] Notification permission denied")
            }
        } catch {
            print("📱 [NotificationManager] Error requesting notification permission: \(error)")
            isAuthorized = false
        }
    }

    func checkAuthorizationStatus() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        isAuthorized = settings.authorizationStatus == .authorized
    }

    func scheduleLockExpirationNotification(
        accessoryID: UUID,
        accessoryName: String,
        expiresAt: Date
    ) async {
        guard isAuthorized else {
            print("📱 [NotificationManager] Not authorized to schedule notifications")
            return
        }

        let identifier = "lock-expiration-\(accessoryID.uuidString)"

        let content = UNMutableNotificationContent()
        content.title = String(localized: "Lock Expired")
        content.body = String(localized: "\(accessoryName) lock has expired. Tap to unlock the device.")
        content.sound = .default
        content.badge = 1
        content.categoryIdentifier = "LOCK_EXPIRED"
        content.userInfo = [
            "accessoryID": accessoryID.uuidString,
            "accessoryName": accessoryName,
            "type": "lock-expiration"
        ]

        let triggerDate = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: expiresAt)
        let trigger = UNCalendarNotificationTrigger(dateMatching: triggerDate, repeats: false)

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

        do {
            let center = UNUserNotificationCenter.current()
            try await center.add(request)
            print("📱 [NotificationManager] Scheduled notification for \(accessoryName) at \(expiresAt)")
        } catch {
            print("📱 [NotificationManager] Error scheduling notification: \(error)")
        }
    }

    func cancelLockExpirationNotification(accessoryID: UUID) async {
        let identifier = "lock-expiration-\(accessoryID.uuidString)"
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        print("📱 [NotificationManager] Cancelled notification for accessory \(accessoryID)")
    }

    func cancelAllLockExpirationNotifications() async {
        let center = UNUserNotificationCenter.current()
        let pendingRequests = await center.pendingNotificationRequests()

        let lockNotificationIdentifiers = pendingRequests
            .filter { $0.identifier.hasPrefix("lock-expiration-") }
            .map { $0.identifier }

        center.removePendingNotificationRequests(withIdentifiers: lockNotificationIdentifiers)
        print("📱 [NotificationManager] Cancelled \(lockNotificationIdentifiers.count) lock expiration notifications")
    }

    // MARK: - Multi-User Notifications

    /// Shows an immediate notification when another home member locks/unlocks a device
    func showExternalLockNotification(accessoryName: String, isLocked: Bool) async {
        guard isAuthorized else {
            print("📱 [NotificationManager] Not authorized to show notifications")
            return
        }

        let identifier = "external-lock-\(UUID().uuidString)"

        let content = UNMutableNotificationContent()
        if isLocked {
            content.title = String(localized: "Device Locked")
            content.body = String(localized: "\(accessoryName) was locked by another home member")
        } else {
            content.title = String(localized: "Device Unlocked")
            content.body = String(localized: "\(accessoryName) was unlocked by another home member")
        }
        content.sound = .default
        content.userInfo = [
            "accessoryName": accessoryName,
            "type": "external-lock-change",
            "isLocked": isLocked
        ]

        // Trigger immediately (1 second delay for iOS requirement)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

        do {
            let center = UNUserNotificationCenter.current()
            try await center.add(request)
            print("📱 [NotificationManager] Showing external lock notification for \(accessoryName)")
        } catch {
            print("📱 [NotificationManager] Error showing external lock notification: \(error)")
        }
    }

    /// Shows a tamper alert notification
    func showTamperNotification(accessoryName: String) async {
        guard isAuthorized else { return }

        let identifier = "tamper-alert-\(UUID().uuidString)"

        let content = UNMutableNotificationContent()
        content.title = String(localized: "Tamper Alert")
        content.body = String(localized: "Someone tried to change \(accessoryName) while it was locked")
        content.sound = UNNotificationSound.defaultCritical
        content.userInfo = [
            "accessoryName": accessoryName,
            "type": "tamper-alert"
        ]

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

        do {
            let center = UNUserNotificationCenter.current()
            try await center.add(request)
            print("📱 [NotificationManager] Showing tamper notification for \(accessoryName)")
        } catch {
            print("📱 [NotificationManager] Error showing tamper notification: \(error)")
        }
    }
}