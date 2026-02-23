import Foundation
import CloudKit
import HomeKit
import Combine

@MainActor
class CloudKitService: ObservableObject {
    static let shared = CloudKitService()
    
    @Published var sharedLocks: [SharedLock] = []
    @Published var isSyncing = false
    @Published var error: Error?
    
    private let container: CKContainer
    private var sharedZone: CKRecordZone?
    private var share: CKShare?
    
    private init() {
        container = CKContainer(identifier: "iCloud.com.jibaroenlaluna.HomeLock")
    }
    
    // MARK: - Zone Setup
    
    func setupSharedZone(for homeID: UUID) async throws {
        let zoneID = CKRecordZone.ID(zoneName: "HomeLockFamily-\(homeID.uuidString)", ownerName: CKCurrentUserDefaultName)
        
        do {
            let zone = CKRecordZone(zoneID: zoneID)
            sharedZone = try await container.privateCloudDatabase.save(zone)
            print("☁️ [CloudKit] Shared zone created: \(zoneID.zoneName)")
        } catch {
            // Zone already exists
            sharedZone = try await container.privateCloudDatabase.recordZone(for: zoneID)
            print("☁️ [CloudKit] Shared zone retrieved: \(zoneID.zoneName)")
        }
    }
    
    // MARK: - Sharing
    
    func createFamilyShare(for homeID: UUID) async throws -> CKShare {
        guard let zone = sharedZone else {
            throw CloudKitError.zoneNotSetup
        }
        
        let rootRecordID = CKRecord.ID(recordName: "FamilyRoot-\(homeID.uuidString)", zoneID: zone.zoneID)
        
        // 1. Try to fetch existing share first
        do {
            let record = try await container.privateCloudDatabase.record(for: rootRecordID)
            if let shareReference = record.share {
                let share = try await container.privateCloudDatabase.record(for: shareReference.recordID) as! CKShare
                self.share = share
                print("☁️ [CloudKit] Existing share retrieved")
                return share
            }
            
            // If record exists but no share, create it below
            return try await createNewShare(for: record)
        } catch {
            // 2. If record doesn't exist, create both record and share
            let rootRecord = CKRecord(recordType: "FamilyRoot", recordID: rootRecordID)
            rootRecord["homeID"] = homeID.uuidString
            return try await createNewShare(for: rootRecord)
        }
    }
    
    private func createNewShare(for rootRecord: CKRecord) async throws -> CKShare {
        let share = CKShare(rootRecord: rootRecord)
        share.publicPermission = .none // Solo invitados pueden verlo
        share[CKShare.SystemFieldKey.title] = "HomeLock Family"
        share[CKShare.SystemFieldKey.shareType] = "com.jibaroenaluna.homelock.family"
        
        let operation = CKModifyRecordsOperation(recordsToSave: [rootRecord, share])
        operation.qualityOfService = .userInitiated
        
        return try await withCheckedThrowingContinuation { continuation in
            operation.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    self.share = share
                    continuation.resume(returning: share)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            container.privateCloudDatabase.add(operation)
        }
    }
    
    // MARK: - CRUD Operations
    
    func createSharedLock(accessory: HMAccessory, home: HMHome, triggerUUID: UUID, expiresAt: Date?, lockedByName: String) async throws -> SharedLock {
        guard let zone = sharedZone else {
            throw CloudKitError.zoneNotSetup
        }
        
        let recordID = CKRecord.ID(recordName: UUID().uuidString, zoneID: zone.zoneID)
        let record = CKRecord(recordType: "SharedLock", recordID: recordID)
        
        record["accessoryUUID"] = accessory.uniqueIdentifier.uuidString
        record["accessoryName"] = accessory.name
        record["homeID"] = home.uniqueIdentifier.uuidString
        record["lockedByUserID"] = try await getCurrentUserID()
        record["lockedByName"] = lockedByName
        record["expiresAt"] = expiresAt
        record["createdAt"] = Date()
        record["triggerUUID"] = triggerUUID.uuidString
        
        let savedRecord = try await container.privateCloudDatabase.save(record)
        let lock = SharedLock(from: savedRecord)
        
        await MainActor.run {
            sharedLocks.append(lock)
        }
        
        return lock
    }
    
    func fetchLocks(for home: HMHome) async throws -> [SharedLock] {
        guard let zone = sharedZone else {
            return []
        }
        
        let predicate = NSPredicate(format: "homeID == %@", home.uniqueIdentifier.uuidString)
        let query = CKQuery(recordType: "SharedLock", predicate: predicate)
        
        let (results, _) = try await container.privateCloudDatabase.records(
            matching: query,
            inZoneWith: zone.zoneID
        )
        
        let locks = results.compactMap { _, result -> SharedLock? in
            guard case .success(let record) = result else { return nil }
            return SharedLock(from: record)
        }
        
        await MainActor.run {
            self.sharedLocks = locks
        }
        
        return locks
    }
    
    func deleteLock(for accessoryID: UUID) async throws {
        guard sharedZone != nil else { return }
        
        // Find the record ID locally or via query
        let accessoryIDString = accessoryID.uuidString
        if let lockToDelete = sharedLocks.first(where: { $0.accessoryUUID == accessoryIDString }) {
            try await container.privateCloudDatabase.deleteRecord(withID: lockToDelete.id)
            await MainActor.run {
                sharedLocks.removeAll { $0.accessoryUUID == accessoryIDString }
            }
        }
    }
    
    func acceptShareMetadata(_ metadata: CKShare.Metadata) async throws {
        try await container.accept(metadata)
    }
    
    private func getCurrentUserID() async throws -> String {
        let recordID = try await container.userRecordID()
        return recordID.recordName
    }
    
    enum CloudKitError: Error {
        case zoneNotSetup
        case shareNotCreated
        case noShareURL
    }
}
