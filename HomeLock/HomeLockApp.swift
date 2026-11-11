//
//  HomeLockApp.swift
//  HomeLock
//
//  Created by Juan C. Ribot on 1/4/26.
//

import SwiftUI
import UIKit
import SwiftData
import BackgroundTasks
import UserNotifications
import CloudKit

@main
struct HomeLockApp: App {
    let modelContainer: ModelContainer

    init() {
        // 1. Definir el esquema
        let schema = Schema([
            LockEvent.self,
            LockSchedule.self,
        ])
        
        // 2. Crear la configuración compatible con las últimas APIs de Apple
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .private("iCloud.com.jibaroenlaluna.HomeLock")
        )

        // 3. Inicializar el contenedor con manejo de errores resiliente
        do {
            modelContainer = try ModelContainer(for: schema, configurations: [modelConfiguration])
            print("📦 [SwiftData] ModelContainer inicializado con éxito")
        } catch {
            print("🚨 [SwiftData] No se pudo cargar la base de datos: \(error.localizedDescription)")
            
            // Intento de recuperación: Usar memoria temporal como red de seguridad
            // Esto asegura que el app siempre suba, incluso si el disco o iCloud fallan.
            let fallbackConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            do {
                modelContainer = try ModelContainer(for: schema, configurations: [fallbackConfig])
                print("🧠 [SwiftData] Usando memoria temporal por seguridad")
            } catch {
                fatalError("Error crítico: Fallo total en la inicialización de datos.")
            }
        }

        registerBackgroundTasks()
        requestNotificationPermissions()
        setupNotificationDelegate()
        
        // Initialize HomeKit for background/Shortcuts support
        HomeKitService.shared.requestAuthorization()
    }

    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .onOpenURL { url in
                    // Handle deep links if any
                }
        }
        .modelContainer(modelContainer)
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                print("📱 [HomeLockApp] App became active, clearing badge count")
                Task { @MainActor in
                    try? await UNUserNotificationCenter.current().setBadgeCount(0)
                    // Wait for HomeKit to be ready before syncing
                    await HomeKitService.shared.waitServiceReady()
                    await LockManager.shared.syncFromHomeKit()
                    // Reconcile schedules on foreground
                    ScheduleManager.shared.checkSchedules()
                }
            }
        }
    }

    private func registerBackgroundTasks() {
        print("🎯 [HomeLockApp] Registering background task handler")

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: "com.jibaroenlaluna.homelock.expireLock",
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

        // "Release Lock": replace the PIN screen with the release status screen
        // right away (delegate callbacks arrive on the main thread), before the
        // app's first frame shows the PIN gate as far as possible.
        var statusName: String?
        if response.actionIdentifier == "RELEASE_LOCK" {
            statusName = MainActor.assumeIsolated {
                let name = LockManager.shared.locks[accessoryID]?.accessoryName
                    ?? response.notification.request.content.userInfo["accessoryName"] as? String
                    ?? String(localized: "Device")
                NotificationReleaseCoordinator.shared.begin(name)
                return name
            }
        }

        Task { @MainActor in
            switch response.actionIdentifier {
            case "RELEASE_LOCK":
                print("📱 [NotificationDelegate] User chose to release lock for accessory \(accessoryID)")
                // On a cold launch from the notification, HomeKit homes load asynchronously.
                await HomeKitService.shared.waitServiceReady()
                await Self.releaseLock(accessoryID, statusName: statusName)

            case "KEEP_LOCKED":
                print("📱 [NotificationDelegate] User chose to keep lock for accessory \(accessoryID)")
                // Do nothing, lock remains active

            case UNNotificationDefaultActionIdentifier:
                // User tapped the notification (not a button)
                print("📱 [NotificationDelegate] User tapped notification for accessory \(accessoryID)")
                await HomeKitService.shared.waitServiceReady()
                await Self.releaseLock(accessoryID)

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
        completionHandler([.banner, .list, .sound, .badge])
    }

    /// Release Lock from a notification. Always frees the device locally (as in
    /// build 7); if HomeKit fails to remove the trigger, the user gets a
    /// notification with the error code instead of a silent failure.
    @MainActor
    /// - Parameter statusName: set for "Release Lock" — the status screen shown
    ///   instead of the PIN is updated with the result.
    static func releaseLock(_ accessoryID: UUID, statusName: String? = nil) async {
        // The action opens the app (.foreground); HomeKit calls made before the
        // app is active can fail, so wait briefly for it to become active.
        for _ in 0..<20 where UIApplication.shared.applicationState != .active {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        do {
            try await LockManager.shared.unlockDevice(accessoryID: accessoryID, source: .notification)
            if let statusName { NotificationReleaseCoordinator.shared.finish(statusName) }
        } catch {
            if let statusName {
                NotificationReleaseCoordinator.shared.fail(
                    statusName, message: ErrorCodeTag.message(error.localizedDescription, for: error))
            }
            await NotificationManager.shared.showUnlockFailedNotification(
                message: ErrorCodeTag.message(error.localizedDescription, for: error)
            )
        }
    }
}

// MARK: - App Delegate for CloudKit Sharing
class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        userDidAcceptCloudKitShareWith shareMetadata: CKShare.Metadata
    ) {
        print("☁️ [AppDelegate] Accepted CloudKit share for container: \(shareMetadata.containerIdentifier)")
        
        Task {
            do {
                try await CloudKitService.shared.acceptShareMetadata(shareMetadata)
                print("✅ [AppDelegate] CloudKit share accepted successfully")
            } catch {
                print("❌ [AppDelegate] Failed to accept CloudKit share: \(error.localizedDescription)")
            }
        }
    }
}
