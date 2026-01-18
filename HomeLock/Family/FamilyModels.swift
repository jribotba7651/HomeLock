//
//  FamilyModels.swift
//  HomeLock
//
//  Created by Claude on 1/18/26.
//

import Foundation
import CloudKit

// MARK: - Family Member

/// Representa un miembro de la familia con acceso a HomeLock
struct FamilyMember: Codable, Identifiable, Equatable {
    let id: String // CloudKit record ID
    let name: String
    let iCloudUserID: String
    var role: FamilyRole
    let joinedAt: Date
    var lastSeenAt: Date

    enum FamilyRole: String, Codable, CaseIterable {
        case admin = "admin"       // Puede crear/eliminar locks y gestionar miembros
        case member = "member"     // Puede crear/eliminar sus propios locks
        case viewer = "viewer"     // Solo puede ver locks

        var displayName: String {
            switch self {
            case .admin: return String(localized: "Admin")
            case .member: return String(localized: "Member")
            case .viewer: return String(localized: "Viewer")
            }
        }

        var canCreateLocks: Bool {
            self == .admin || self == .member
        }

        var canDeleteOthersLocks: Bool {
            self == .admin
        }

        var canManageMembers: Bool {
            self == .admin
        }
    }

    // CloudKit record conversion
    static let recordType = "FamilyMember"

    init(id: String, name: String, iCloudUserID: String, role: FamilyRole, joinedAt: Date = Date(), lastSeenAt: Date = Date()) {
        self.id = id
        self.name = name
        self.iCloudUserID = iCloudUserID
        self.role = role
        self.joinedAt = joinedAt
        self.lastSeenAt = lastSeenAt
    }

    init?(from record: CKRecord) {
        guard let name = record["name"] as? String,
              let iCloudUserID = record["iCloudUserID"] as? String,
              let roleRaw = record["role"] as? String,
              let role = FamilyRole(rawValue: roleRaw),
              let joinedAt = record["joinedAt"] as? Date,
              let lastSeenAt = record["lastSeenAt"] as? Date else {
            return nil
        }

        self.id = record.recordID.recordName
        self.name = name
        self.iCloudUserID = iCloudUserID
        self.role = role
        self.joinedAt = joinedAt
        self.lastSeenAt = lastSeenAt
    }

    func toRecord(homeID: String) -> CKRecord {
        let recordID = CKRecord.ID(recordName: id)
        let record = CKRecord(recordType: Self.recordType, recordID: recordID)
        record["name"] = name
        record["iCloudUserID"] = iCloudUserID
        record["role"] = role.rawValue
        record["joinedAt"] = joinedAt
        record["lastSeenAt"] = lastSeenAt
        record["homeID"] = homeID
        return record
    }
}

// MARK: - Shared Lock

/// Representa un lock compartido sincronizado via CloudKit
struct SharedLock: Codable, Identifiable, Equatable {
    let id: String // CloudKit record ID
    let accessoryID: UUID
    let accessoryName: String
    let roomName: String?
    let lockedState: Bool
    let createdAt: Date
    let expiresAt: Date?
    let createdByID: String // FamilyMember ID
    let createdByName: String
    let homeID: String

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() >= expiresAt
    }

    var timeRemaining: TimeInterval? {
        guard let expiresAt else { return nil }
        let remaining = expiresAt.timeIntervalSinceNow
        return remaining > 0 ? remaining : 0
    }

    // CloudKit record conversion
    static let recordType = "SharedLock"

    init(id: String = UUID().uuidString,
         accessoryID: UUID,
         accessoryName: String,
         roomName: String?,
         lockedState: Bool,
         createdAt: Date = Date(),
         expiresAt: Date?,
         createdByID: String,
         createdByName: String,
         homeID: String) {
        self.id = id
        self.accessoryID = accessoryID
        self.accessoryName = accessoryName
        self.roomName = roomName
        self.lockedState = lockedState
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.createdByID = createdByID
        self.createdByName = createdByName
        self.homeID = homeID
    }

    init?(from record: CKRecord) {
        guard let accessoryIDString = record["accessoryID"] as? String,
              let accessoryID = UUID(uuidString: accessoryIDString),
              let accessoryName = record["accessoryName"] as? String,
              let lockedState = record["lockedState"] as? Bool,
              let createdAt = record["createdAt"] as? Date,
              let createdByID = record["createdByID"] as? String,
              let createdByName = record["createdByName"] as? String,
              let homeID = record["homeID"] as? String else {
            return nil
        }

        self.id = record.recordID.recordName
        self.accessoryID = accessoryID
        self.accessoryName = accessoryName
        self.roomName = record["roomName"] as? String
        self.lockedState = lockedState
        self.createdAt = createdAt
        self.expiresAt = record["expiresAt"] as? Date
        self.createdByID = createdByID
        self.createdByName = createdByName
        self.homeID = homeID
    }

    func toRecord() -> CKRecord {
        let recordID = CKRecord.ID(recordName: id)
        let record = CKRecord(recordType: Self.recordType, recordID: recordID)
        record["accessoryID"] = accessoryID.uuidString
        record["accessoryName"] = accessoryName
        record["roomName"] = roomName
        record["lockedState"] = lockedState
        record["createdAt"] = createdAt
        record["expiresAt"] = expiresAt
        record["createdByID"] = createdByID
        record["createdByName"] = createdByName
        record["homeID"] = homeID
        return record
    }
}

// MARK: - Family Home

/// Representa un hogar compartido de HomeKit
struct FamilyHome: Codable, Identifiable, Equatable {
    let id: String // HomeKit home UUID
    let name: String
    var members: [FamilyMember]
    var sharedLocks: [SharedLock]
    let createdAt: Date

    static let recordType = "FamilyHome"

    init(id: String, name: String, members: [FamilyMember] = [], sharedLocks: [SharedLock] = [], createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.members = members
        self.sharedLocks = sharedLocks
        self.createdAt = createdAt
    }

    init?(from record: CKRecord) {
        guard let name = record["name"] as? String,
              let createdAt = record["createdAt"] as? Date else {
            return nil
        }

        self.id = record.recordID.recordName
        self.name = name
        self.members = []
        self.sharedLocks = []
        self.createdAt = createdAt
    }

    func toRecord() -> CKRecord {
        let recordID = CKRecord.ID(recordName: id)
        let record = CKRecord(recordType: Self.recordType, recordID: recordID)
        record["name"] = name
        record["createdAt"] = createdAt
        return record
    }
}

// MARK: - Lock Activity

/// Representa una actividad/cambio en un lock para el historial
struct LockActivity: Codable, Identifiable {
    let id: String
    let lockID: String
    let accessoryName: String
    let action: LockAction
    let performedByID: String
    let performedByName: String
    let timestamp: Date
    let homeID: String

    enum LockAction: String, Codable {
        case created = "created"
        case removed = "removed"
        case expired = "expired"
        case modified = "modified"

        var displayName: String {
            switch self {
            case .created: return String(localized: "Locked")
            case .removed: return String(localized: "Unlocked")
            case .expired: return String(localized: "Expired")
            case .modified: return String(localized: "Modified")
            }
        }

        var systemImage: String {
            switch self {
            case .created: return "lock.fill"
            case .removed: return "lock.open.fill"
            case .expired: return "clock.badge.xmark"
            case .modified: return "pencil"
            }
        }
    }

    static let recordType = "LockActivity"

    init(id: String = UUID().uuidString,
         lockID: String,
         accessoryName: String,
         action: LockAction,
         performedByID: String,
         performedByName: String,
         timestamp: Date = Date(),
         homeID: String) {
        self.id = id
        self.lockID = lockID
        self.accessoryName = accessoryName
        self.action = action
        self.performedByID = performedByID
        self.performedByName = performedByName
        self.timestamp = timestamp
        self.homeID = homeID
    }

    init?(from record: CKRecord) {
        guard let lockID = record["lockID"] as? String,
              let accessoryName = record["accessoryName"] as? String,
              let actionRaw = record["action"] as? String,
              let action = LockAction(rawValue: actionRaw),
              let performedByID = record["performedByID"] as? String,
              let performedByName = record["performedByName"] as? String,
              let timestamp = record["timestamp"] as? Date,
              let homeID = record["homeID"] as? String else {
            return nil
        }

        self.id = record.recordID.recordName
        self.lockID = lockID
        self.accessoryName = accessoryName
        self.action = action
        self.performedByID = performedByID
        self.performedByName = performedByName
        self.timestamp = timestamp
        self.homeID = homeID
    }

    func toRecord() -> CKRecord {
        let recordID = CKRecord.ID(recordName: id)
        let record = CKRecord(recordType: Self.recordType, recordID: recordID)
        record["lockID"] = lockID
        record["accessoryName"] = accessoryName
        record["action"] = action.rawValue
        record["performedByID"] = performedByID
        record["performedByName"] = performedByName
        record["timestamp"] = timestamp
        record["homeID"] = homeID
        return record
    }
}
