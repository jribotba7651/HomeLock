//
//  SharedLock.swift
//  HomeLock
//
//  Created by Claude on 1/18/26.
//

import Foundation
import CloudKit

// MARK: - CloudKit Schema Documentation
/*
 CloudKit Dashboard Schema Setup:

 Container: iCloud.com.jibaroenlaluna.HomeLock

 Record Type: SharedLock

 Fields:
 - lockID (String): Unique identifier for the lock (UUID string)
 - accessoryID (String): HomeKit accessory UUID
 - accessoryName (String): Display name of the device
 - lockedState (Int64): 1 = ON, 0 = OFF
 - createdAt (Date/Time): When the lock was created
 - expiresAt (Date/Time): Optional expiration date (queryable)
 - ownerDeviceID (String): Device that created the lock
 - ownerDeviceName (String): Name of the device that created the lock

 Indexes:
 - accessoryID (Queryable, Sortable)
 - createdAt (Queryable, Sortable)
 - expiresAt (Queryable, Sortable)
 - ownerDeviceID (Queryable)

 Security:
 - Zone: _defaultZone (public database for sharing between user's devices)
 - Or use private database with CKShare for family sharing
 */

/// Represents a lock configuration synced via CloudKit
struct SharedLock: Identifiable, Equatable {
    // MARK: - CloudKit Record Type
    static let recordType = "SharedLock"

    // MARK: - CloudKit Field Keys
    enum FieldKey: String {
        case lockID = "lockID"
        case accessoryID = "accessoryID"
        case accessoryName = "accessoryName"
        case lockedState = "lockedState"
        case createdAt = "createdAt"
        case expiresAt = "expiresAt"
        case ownerDeviceID = "ownerDeviceID"
        case ownerDeviceName = "ownerDeviceName"
    }

    // MARK: - Properties
    let id: UUID
    let accessoryID: UUID
    let accessoryName: String
    let lockedState: Bool
    let createdAt: Date
    let expiresAt: Date?
    let ownerDeviceID: String
    let ownerDeviceName: String

    /// CloudKit record ID for this lock
    var recordID: CKRecord.ID {
        CKRecord.ID(recordName: id.uuidString)
    }

    // MARK: - Computed Properties

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() >= expiresAt
    }

    var timeRemaining: TimeInterval? {
        guard let expiresAt else { return nil }
        let remaining = expiresAt.timeIntervalSinceNow
        return remaining > 0 ? remaining : 0
    }

    var isFromCurrentDevice: Bool {
        ownerDeviceID == SharedLock.currentDeviceID
    }

    // MARK: - Device Identification

    static var currentDeviceID: String {
        // Use a persistent device identifier stored in Keychain
        if let stored = UserDefaults.standard.string(forKey: "HomeLock_DeviceID") {
            return stored
        }
        let newID = UUID().uuidString
        UserDefaults.standard.set(newID, forKey: "HomeLock_DeviceID")
        return newID
    }

    static var currentDeviceName: String {
        #if os(iOS)
        return UIDevice.current.name
        #elseif os(macOS)
        return Host.current().localizedName ?? "Mac"
        #else
        return "Unknown Device"
        #endif
    }

    // MARK: - Initialization

    init(
        id: UUID = UUID(),
        accessoryID: UUID,
        accessoryName: String,
        lockedState: Bool,
        createdAt: Date = Date(),
        expiresAt: Date?,
        ownerDeviceID: String = SharedLock.currentDeviceID,
        ownerDeviceName: String = SharedLock.currentDeviceName
    ) {
        self.id = id
        self.accessoryID = accessoryID
        self.accessoryName = accessoryName
        self.lockedState = lockedState
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.ownerDeviceID = ownerDeviceID
        self.ownerDeviceName = ownerDeviceName
    }

    /// Initialize from a CloudKit record
    init?(record: CKRecord) {
        guard record.recordType == SharedLock.recordType else { return nil }

        guard let lockIDString = record[FieldKey.lockID.rawValue] as? String,
              let lockID = UUID(uuidString: lockIDString),
              let accessoryIDString = record[FieldKey.accessoryID.rawValue] as? String,
              let accessoryID = UUID(uuidString: accessoryIDString),
              let accessoryName = record[FieldKey.accessoryName.rawValue] as? String,
              let lockedStateInt = record[FieldKey.lockedState.rawValue] as? Int64,
              let createdAt = record[FieldKey.createdAt.rawValue] as? Date,
              let ownerDeviceID = record[FieldKey.ownerDeviceID.rawValue] as? String,
              let ownerDeviceName = record[FieldKey.ownerDeviceName.rawValue] as? String
        else {
            return nil
        }

        self.id = lockID
        self.accessoryID = accessoryID
        self.accessoryName = accessoryName
        self.lockedState = lockedStateInt == 1
        self.createdAt = createdAt
        self.expiresAt = record[FieldKey.expiresAt.rawValue] as? Date
        self.ownerDeviceID = ownerDeviceID
        self.ownerDeviceName = ownerDeviceName
    }

    /// Initialize from an existing LockConfiguration
    init(from config: LockConfiguration) {
        self.id = config.id
        self.accessoryID = config.accessoryID
        self.accessoryName = config.accessoryName
        self.lockedState = config.lockedState
        self.createdAt = config.createdAt
        self.expiresAt = config.expiresAt
        self.ownerDeviceID = SharedLock.currentDeviceID
        self.ownerDeviceName = SharedLock.currentDeviceName
    }

    // MARK: - CloudKit Record Conversion

    /// Convert to a CloudKit record
    func toRecord() -> CKRecord {
        let record = CKRecord(recordType: SharedLock.recordType, recordID: recordID)

        record[FieldKey.lockID.rawValue] = id.uuidString
        record[FieldKey.accessoryID.rawValue] = accessoryID.uuidString
        record[FieldKey.accessoryName.rawValue] = accessoryName
        record[FieldKey.lockedState.rawValue] = lockedState ? 1 : 0
        record[FieldKey.createdAt.rawValue] = createdAt
        record[FieldKey.expiresAt.rawValue] = expiresAt
        record[FieldKey.ownerDeviceID.rawValue] = ownerDeviceID
        record[FieldKey.ownerDeviceName.rawValue] = ownerDeviceName

        return record
    }

    /// Convert to LockConfiguration for local use
    /// Note: triggerID will need to be set separately when creating the local lock
    func toLockConfiguration(triggerID: UUID) -> LockConfiguration {
        LockConfiguration(
            id: id,
            accessoryID: accessoryID,
            accessoryName: accessoryName,
            triggerID: triggerID,
            lockedState: lockedState,
            createdAt: createdAt,
            expiresAt: expiresAt
        )
    }
}

// MARK: - Equatable

extension SharedLock {
    static func == (lhs: SharedLock, rhs: SharedLock) -> Bool {
        lhs.id == rhs.id
    }
}
