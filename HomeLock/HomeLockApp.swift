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
                Task {
                     try? await UNUserNotificationCenter.current().setBadgeCount(0)
                }
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
        completionHandler([.banner, .list, .sound, .badge])
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
