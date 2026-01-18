//
//  HomeLockApp.swift
//  HomeLock
//
//  Created by Juan C. Ribot on 1/4/26.
//

import SwiftUI
import BackgroundTasks
import UserNotifications
import CloudKit

@main
struct HomeLockApp: App {
    @AppStorage("appearanceMode") var appearanceMode: Int = 0
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        registerBackgroundTasks()
        requestNotificationPermissions()
        setupNotificationDelegate()
    }

    var body: some Scene {
        WindowGroup {
            SplashContainer {
                AuthenticationView {
                    MainTabView()
                }
            }
            .preferredColorScheme(
                appearanceMode == 0 ? nil :
                appearanceMode == 1 ? .light : .dark
            )
        }
    }

    private func registerBackgroundTasks() {
        print("🎯 [HomeLockApp] Registering background task handler")

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: "com.jibaroenaluna.homelock.expireLock",
            using: nil
        ) { task in
            print("🎯 [HomeLockApp] Background task triggered!")

            let backgroundTask = task as! BGAppRefreshTask

            backgroundTask.expirationHandler = {
                print("⏰ [HomeLockApp] Background task expired, marking as failed")
                backgroundTask.setTaskCompleted(success: false)
            }

            Task { @MainActor in
                await LockManager.shared.cleanupExpiredLocks()
                backgroundTask.setTaskCompleted(success: true)
            }
        }
    }

    private func requestNotificationPermissions() {
        Task { @MainActor in
            await NotificationManager.shared.requestPermission()
        }
    }

    private func setupNotificationDelegate() {
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
    }
}

class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()

    private override init() {
        super.init()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        guard let accessoryIDString = response.notification.request.content.userInfo["accessoryID"] as? String,
              let accessoryID = UUID(uuidString: accessoryIDString),
              response.notification.request.content.userInfo["type"] as? String == "lock-expiration" else {
            completionHandler()
            return
        }

        Task { @MainActor in
            switch response.actionIdentifier {
            case "RELEASE_LOCK":
                print("📱 [NotificationDelegate] User chose to release lock for accessory \(accessoryID)")
                await LockManager.shared.removeLock(for: accessoryID)

            case "KEEP_LOCKED":
                print("📱 [NotificationDelegate] User chose to keep lock for accessory \(accessoryID)")
                // Do nothing, lock remains active

            case UNNotificationDefaultActionIdentifier:
                // User tapped the notification (not a button)
                print("📱 [NotificationDelegate] User tapped notification for accessory \(accessoryID)")
                await LockManager.shared.removeLock(for: accessoryID)

            default:
                print("📱 [NotificationDelegate] Unknown action identifier: \(response.actionIdentifier)")
            }

            completionHandler()
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.alert, .sound, .badge])
    }
}

// MARK: - App Delegate for CloudKit Push Notifications

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Register for remote notifications (required for CloudKit subscriptions)
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        print("📬 [AppDelegate] Registered for remote notifications")
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("❌ [AppDelegate] Failed to register for remote notifications: \(error)")
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        // Check if this is a CloudKit notification
        if let notification = CKNotification(fromRemoteNotificationDictionary: userInfo as! [String: NSObject]) {
            print("📬 [AppDelegate] Received CloudKit notification: \(notification.subscriptionID ?? "unknown")")

            Task {
                await FamilyPermissionService.shared.handleRemoteNotification(userInfo)
                completionHandler(.newData)
            }
        } else {
            completionHandler(.noData)
        }
    }
}
