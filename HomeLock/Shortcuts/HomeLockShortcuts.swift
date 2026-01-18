//
//  HomeLockShortcuts.swift
//  HomeLock
//
//  Created by Claude on 1/18/26.
//

import AppIntents

/// Provider principal de Shortcuts para HomeLock
struct HomeLockShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        // Lock Device Shortcut
        AppShortcut(
            intent: LockDeviceIntent(),
            phrases: [
                "Lock \(\.$device) with \(.applicationName)",
                "Lock \(\.$device) in \(.applicationName)",
                "Block \(\.$device) with \(.applicationName)"
            ],
            shortTitle: "Lock Device",
            systemImageName: "lock.fill"
        )

        // Unlock Device Shortcut
        AppShortcut(
            intent: UnlockDeviceIntent(),
            phrases: [
                "Unlock \(\.$device) with \(.applicationName)",
                "Unblock \(\.$device) with \(.applicationName)",
                "Release \(\.$device) in \(.applicationName)"
            ],
            shortTitle: "Unlock Device",
            systemImageName: "lock.open.fill"
        )

        // Get Locked Devices Shortcut
        AppShortcut(
            intent: GetLockedDevicesIntent(),
            phrases: [
                "Show locked devices in \(.applicationName)",
                "What devices are locked in \(.applicationName)",
                "List locked devices with \(.applicationName)"
            ],
            shortTitle: "Locked Devices",
            systemImageName: "list.bullet"
        )

        // Check if Device is Locked
        AppShortcut(
            intent: IsDeviceLockedIntent(),
            phrases: [
                "Is \(\.$device) locked in \(.applicationName)",
                "Check if \(\.$device) is locked with \(.applicationName)"
            ],
            shortTitle: "Check Lock",
            systemImageName: "questionmark.circle"
        )

        // Get Lock Info
        AppShortcut(
            intent: GetLockInfoIntent(),
            phrases: [
                "Get lock info for \(\.$device) in \(.applicationName)",
                "Lock status of \(\.$device) in \(.applicationName)"
            ],
            shortTitle: "Lock Info",
            systemImageName: "info.circle"
        )

        // Unlock All Devices
        AppShortcut(
            intent: UnlockAllDevicesIntent(),
            phrases: [
                "Unlock all devices in \(.applicationName)",
                "Release all locks in \(.applicationName)"
            ],
            shortTitle: "Unlock All",
            systemImageName: "lock.open"
        )
    }
}
