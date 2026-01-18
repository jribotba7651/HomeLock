//
//  DeviceEntity.swift
//  HomeLock
//
//  Created by Claude on 1/18/26.
//

import AppIntents
import HomeKit

/// Entidad que representa un dispositivo HomeKit para Shortcuts
struct DeviceEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Device")
    }

    static var defaultQuery = DeviceQuery()

    var id: String
    var name: String
    var roomName: String?
    var isLocked: Bool

    var displayRepresentation: DisplayRepresentation {
        let subtitle: String
        if let roomName {
            subtitle = isLocked ? "\(roomName) • Locked" : roomName
        } else {
            subtitle = isLocked ? "Locked" : ""
        }

        return DisplayRepresentation(
            title: LocalizedStringResource(stringLiteral: name),
            subtitle: LocalizedStringResource(stringLiteral: subtitle),
            image: .init(systemName: isLocked ? "lock.fill" : "poweroutlet.type.b")
        )
    }

    init(id: String, name: String, roomName: String? = nil, isLocked: Bool = false) {
        self.id = id
        self.name = name
        self.roomName = roomName
        self.isLocked = isLocked
    }

    @MainActor
    init(from accessory: HMAccessory, lockManager: LockManager) {
        self.id = accessory.uniqueIdentifier.uuidString
        self.name = accessory.name
        self.roomName = accessory.room?.name
        self.isLocked = lockManager.isLocked(accessory.uniqueIdentifier)
    }
}

/// Query para buscar dispositivos HomeKit
struct DeviceQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [DeviceEntity] {
        let homeKitService = HomeKitService.shared
        let lockManager = LockManager.shared

        return identifiers.compactMap { id -> DeviceEntity? in
            guard let uuid = UUID(uuidString: id),
                  let accessory = homeKitService.outlets.first(where: { $0.uniqueIdentifier == uuid }) else {
                return nil
            }
            return DeviceEntity(from: accessory, lockManager: lockManager)
        }
    }

    @MainActor
    func suggestedEntities() async throws -> [DeviceEntity] {
        let homeKitService = HomeKitService.shared
        let lockManager = LockManager.shared

        return homeKitService.outlets.map { accessory in
            DeviceEntity(from: accessory, lockManager: lockManager)
        }
    }

    @MainActor
    func defaultResult() async -> DeviceEntity? {
        try? await suggestedEntities().first
    }
}

// MARK: - EntityStringQuery for search
extension DeviceQuery: EntityStringQuery {
    @MainActor
    func entities(matching string: String) async throws -> [DeviceEntity] {
        let homeKitService = HomeKitService.shared
        let lockManager = LockManager.shared

        let lowercasedQuery = string.lowercased()

        return homeKitService.outlets
            .filter { accessory in
                accessory.name.lowercased().contains(lowercasedQuery) ||
                (accessory.room?.name.lowercased().contains(lowercasedQuery) ?? false)
            }
            .map { DeviceEntity(from: $0, lockManager: lockManager) }
    }
}
