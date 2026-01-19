//
//  HomeLockApp.swift
//  HomeLock
//
//  Created by Juan C. Ribot on 1/4/26.
//

import SwiftUI
import SwiftData
import BackgroundTasks
import UserNotifications

@main
struct HomeLockApp: App {
    @AppStorage("appearanceMode") var appearanceMode: Int = 0
    @AppStorage("appLaunchCount") var appLaunchCount: Int = 0

    @ObservedObject private var storeManager = StoreManager.shared
    @State private var showPaywall = false

    let modelContainer: ModelContainer

    init() {
        // Initialize SwiftData ModelContainer
        let schema = Schema([
            LockEvent.self,
            LockSchedule.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            modelContainer = try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }

        registerBackgroundTasks()
        requestNotificationPermissions()
        setupNotificationDelegate()
    }

    var body: some Scene {
        WindowGroup {
            SplashContainer {
                AuthenticationView {
                    ContentView()
                }
            }
            .preferredColorScheme(
                appearanceMode == 0 ? nil :
                appearanceMode == 1 ? .light : .dark
            )
            .fullScreenCover(isPresented: $showPaywall) {
                PaywallView(isPresented: $showPaywall)
            }
            .onAppear {
                checkPaywall()
            }
        }
        .modelContainer(modelContainer)
    }

    private func checkPaywall() {
        // Increment launch count
        appLaunchCount += 1
        print("💰 [Paywall] Launch count: \(appLaunchCount)")

        // Don't show if Pro
        guard !storeManager.isPro else {
            print("💰 [Paywall] User is Pro, skipping")
            return
        }

        // Show on first launch or every 5 launches
        if appLaunchCount == 1 || appLaunchCount % 5 == 0 {
            print("💰 [Paywall] Will show paywall")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                showPaywall = true
            }
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
