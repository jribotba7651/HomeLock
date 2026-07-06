//
//  NotificationManager.swift
//  HomeLock
//
//  Created by Juan C. Ribot on 1/14/26.
//

import Foundation
import UserNotifications

class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()
    
    private let categoryIdentifier = "LOCK_EXPIRATION"
    
    enum ActionIdentifier: String {
        case unlock = "UNLOCK_ACTION"
        case keep = "KEEP_ACTION"
    }
    
    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        setupCategories()
    }
    
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                print("✅ [NotificationManager] Permiso concedido")
            } else if let error = error {
                print("❌ [NotificationManager] Error pidiendo permiso: \(error.localizedDescription)")
            }
        }
    }
    
    private func setupCategories() {
        let unlockAction = UNNotificationAction(
            identifier: ActionIdentifier.unlock.rawValue,
            title: String(localized: "Unlock now"),
            options: .destructive
        )
        
        let keepAction = UNNotificationAction(
            identifier: ActionIdentifier.keep.rawValue,
            title: String(localized: "Keep locked"),
            options: .foreground
        )
        
        let category = UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [unlockAction, keepAction],
            intentIdentifiers: [],
            options: .customDismissAction
        )
        
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }
    
    func scheduleExpirationNotification(for accessoryName: String, accessoryID: UUID, at date: Date) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Lock Expired")
        content.body = String(localized: "The lock timer for \(accessoryName) has finished.")
        content.sound = .default
        content.categoryIdentifier = categoryIdentifier
        content.userInfo = ["accessoryID": accessoryID.uuidString]
        
        let timeInterval = date.timeIntervalSinceNow
        guard timeInterval > 0 else { return }
        
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: timeInterval, repeats: false)
        let request = UNNotificationRequest(
            identifier: "EXP_\(accessoryID.uuidString)",
            content: content,
            trigger: trigger
        )
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("❌ [NotificationManager] Error programando notificación: \(error.localizedDescription)")
            } else {
                print("📅 [NotificationManager] Notificación programada para \(accessoryName) en \(date)")
            }
        }
    }
    
    func cancelNotification(for accessoryID: UUID) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["EXP_\(accessoryID.uuidString)"])
    }
    
    // MARK: - UNUserNotificationCenterDelegate
    
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        guard let idString = userInfo["accessoryID"] as? String,
              let accessoryID = UUID(uuidString: idString) else {
            completionHandler()
            return
        }
        
        Task { @MainActor in
            if response.actionIdentifier == ActionIdentifier.unlock.rawValue {
                print("🔓 [NotificationManager] Usuario eligió UNLOCK desde notificación")
                await LockManager.shared.removeLock(for: accessoryID)
            } else {
                print("🔒 [NotificationManager] Usuario abrió la app o eligió KEEP")
                // Si es KEEP o simplemente abre la app, no hacemos nada (mantenemos el estado)
            }
            completionHandler()
        }
    }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
