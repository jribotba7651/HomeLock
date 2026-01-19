import AppIntents
import HomeKit
import Foundation

struct HomeLockDeviceEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Device"
    static var defaultQuery = HomeLockDeviceQuery()
    
    var id: String
    var name: String
    var roomName: String?
    
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: roomName.map { "\($0)" } ?? "")
    }
}

struct HomeLockDeviceQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [HomeLockDeviceEntity] {
        let homeKit = HomeKitService.shared
        return homeKit.outlets
            .filter { identifiers.contains($0.uniqueIdentifier.uuidString) }
            .map { HomeLockDeviceEntity(id: $0.uniqueIdentifier.uuidString, name: $0.name, roomName: $0.room?.name) }
    }
    
    @MainActor
    func suggestedEntities() async throws -> [HomeLockDeviceEntity] {
        let homeKit = HomeKitService.shared
        // Ensure home kit is initialized
        if homeKit.homes.isEmpty {
            homeKit.requestAuthorization()
        }
        
        return homeKit.outlets
            .map { HomeLockDeviceEntity(id: $0.uniqueIdentifier.uuidString, name: $0.name, roomName: $0.room?.name) }
    }
}

struct LockDeviceIntent: AppIntent {
    static var title: LocalizedStringResource = "Lock Device"
    static var description = IntentDescription("Temporarily lock a smart home device with HomeLock")
    
    @Parameter(title: "Device")
    var device: HomeLockDeviceEntity
    
    @Parameter(title: "Duration in minutes", default: 30)
    var durationMinutes: Int
    
    static var parameterSummary: some ParameterSummary {
        Summary("Lock \(\.$device) for \(\.$durationMinutes) minutes")
    }
    
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let accessoryID = UUID(uuidString: device.id) else {
             throw IntentError.invalidDevice
        }
        
        do {
            try await LockManager.shared.lockDevice(
                accessoryID: accessoryID,
                duration: TimeInterval(durationMinutes * 60),
                lockedState: false // Default to OFF for protection
            )
            return .result(dialog: "Locked \(device.name) for \(durationMinutes) minutes")
        } catch {
            throw IntentError.lockFailed(device.name)
        }
    }
}

struct UnlockDeviceIntent: AppIntent {
    static var title: LocalizedStringResource = "Unlock Device"
    static var description = IntentDescription("Remove lock from a smart home device")
    
    @Parameter(title: "Device")
    var device: HomeLockDeviceEntity
    
    static var parameterSummary: some ParameterSummary {
        Summary("Unlock \(\.$device)")
    }
    
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let accessoryID = UUID(uuidString: device.id) else {
             throw IntentError.invalidDevice
        }
        
        await LockManager.shared.removeLock(for: accessoryID)
        return .result(dialog: "Unlocked \(device.name)")
    }
}

struct CheckLockStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Check Lock Status"
    static var description = IntentDescription("Check if a device is currently locked")
    
    @Parameter(title: "Device")
    var device: HomeLockDeviceEntity
    
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let accessoryID = UUID(uuidString: device.id) else {
             throw IntentError.invalidDevice
        }
        
        let status = LockManager.shared.getLockStatus(accessoryID: accessoryID)
        
        if let remainingTime = status.remainingTime {
            let minutes = Int(remainingTime / 60)
            return .result(dialog: "\(device.name) is locked for \(minutes) more minutes")
        } else if status.isLocked {
            return .result(dialog: "\(device.name) is locked indefinitely")
        } else {
            return .result(dialog: "\(device.name) is not locked")
        }
    }
}

struct HomeLockShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LockDeviceIntent(),
            phrases: [
                "Lock \(\.$device) with \(.applicationName)",
                "Lock a device with \(.applicationName)",
                "Block \(\.$device) with \(.applicationName)"
            ],
            shortTitle: "Lock Device",
            systemImageName: "lock.fill"
        )
        
        AppShortcut(
            intent: UnlockDeviceIntent(),
            phrases: [
                "Unlock \(\.$device) with \(.applicationName)",
                "Unblock \(\.$device) with \(.applicationName)"
            ],
            shortTitle: "Unlock Device",
            systemImageName: "lock.open.fill"
        )
        
        AppShortcut(
            intent: CheckLockStatusIntent(),
            phrases: [
                "Check \(\.$device) lock status with \(.applicationName)",
                "Is \(\.$device) locked with \(.applicationName)"
            ],
            shortTitle: "Check Status",
            systemImageName: "info.circle"
        )
    }
}

enum IntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case lockFailed(String)
    case invalidDevice
    
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .lockFailed(let name):
            return "Failed to lock \(name)"
        case .invalidDevice:
            return "Invalid device selected"
        }
    }
}
