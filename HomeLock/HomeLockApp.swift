//
//  HomeLockApp.swift
//  HomeLock
//
//  Created by Juan C. Ribot on 1/4/26.
//

import SwiftUI
import BackgroundTasks

@main
struct HomeLockApp: App {
    @StateObject private var homeKit = HomeKitService()
    @Environment(\.scenePhase) private var phase
    
    private let cleanupTaskID = "com.jribot.homelock.cleanup"
    private let notificationManager = NotificationManager.shared

    init() {
        registerBackgroundTasks()
        notificationManager.requestAuthorization()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(homeKit: homeKit)
        }
        .onChange(of: phase) { _, newPhase in
            if newPhase == .background {
                scheduleAppRefresh()
            }
        }
    }

    private func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: cleanupTaskID, using: nil) { task in
            handleAppRefresh(task: task as! BGAppRefreshTask)
        }
    }

    private func scheduleAppRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: cleanupTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // At least 15 minutes
        
        do {
            try BGTaskScheduler.shared.submit(request)
            print("🗓️ [HomeLock] Task scheduled: \(cleanupTaskID)")
        } catch {
            print("❌ [HomeLock] Could not schedule app refresh: \(error)")
        }
    }

    private func handleAppRefresh(task: BGAppRefreshTask) {
        scheduleAppRefresh() // Schedule next
        
        let lockManager = LockManager.shared
        
        task.expirationHandler = {
            // Cleanup on expiration
        }

        Task {
            // Since we need to interact with HomeKit, we should ensure it's loaded
            // In background, this is tricky. HMEventTrigger does the heavy lifting.
            // This task is mainly for local state cleanup and notifications.
            await LockManager.shared.checkExpiredLocksInBackground()
            task.setTaskCompleted(success: true)
        }
    }
}
