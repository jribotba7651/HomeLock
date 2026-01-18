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

}