import Foundation
import CloudKit
import HomeKit
import Combine
import UIKit

@MainActor
class CloudKitService: ObservableObject {
    static let shared = CloudKitService()
    
    @Published var sharedLocks: [SharedLock] = []
    @Published var isSyncing = false
    @Published var error: Error?
    
    private let container: CKContainer
    private var sharedZone: CKRecordZone?
    private var share: CKShare?

    /// True when the local user is a participant of someone else's shared zone.
    /// When true, all reads/writes go through `container.sharedCloudDatabase`
    /// instead of `container.privateCloudDatabase`. Without this distinction,
    /// participants would write to (and read from) their own private DB and
    /// never see records from the share owner.
    private var isParticipant: Bool = false

    /// Database to use for the shared zone, depending on owner vs participant.
    private var database: CKDatabase {
        isParticipant ? container.sharedCloudDatabase : container.privateCloudDatabase
    }

    private init() {
        container = CKContainer(identifier: "iCloud.com.jibaroenlaluna.HomeLock")
    }

    // MARK: - Zone Setup

    func setupSharedZone(for homeID: UUID) async throws {
        // 1. If we accepted a share, the zone lives in our sharedCloudDatabase.
        //    Detect that first so participant devices read/write the right DB.
        do {
            let participantZones = try await container.sharedCloudDatabase.allRecordZones()
            if let participantZone = participantZones.first(where: { $0.zoneID.zoneName.hasPrefix("HomeLockFamily-") }) {
                sharedZone = participantZone
                isParticipant = true
                print("☁️ [CloudKit] Participant zone detected: \(participantZone.zoneID.zoneName)")
                return
            }
        } catch {
            print("☁️ [CloudKit] sharedCloudDatabase lookup failed: \(error.localizedDescription)")
        }

        // 2. Otherwise we are the owner — create or fetch the zone in privateCloudDatabase.
        let zoneID = CKRecordZone.ID(zoneName: "HomeLockFamily-\(homeID.uuidString)", ownerName: CKCurrentUserDefaultName)
        do {
            let zone = CKRecordZone(zoneID: zoneID)
            sharedZone = try await container.privateCloudDatabase.save(zone)
            isParticipant = false
            print("☁️ [CloudKit] Owner zone created: \(zoneID.zoneName)")
        } catch {
            sharedZone = try await container.privateCloudDatabase.recordZone(for: zoneID)
            isParticipant = false
            print("☁️ [CloudKit] Owner zone retrieved: \(zoneID.zoneName)")
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
        share[CKShare.SystemFieldKey.shareType] = "com.jibaroenlaluna.homelock.family"
        
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

    /// Crea un SharedLock en CloudKit.
    ///
    /// **Seguridad:** `lockedByUserID` y `lockedByName` NO se reciben del
    /// caller — se derivan del iCloud user actual y `UIDevice.current.name`
    /// respectivamente. Así un participante malicioso del CKShare no puede
    /// crear records que atribuyen el lock a otro padre.
    ///
    /// En fetch, además, validamos que `creatorUserRecordID` (system field,
    /// puesto por CloudKit y no editable) matchea `lockedByUserID`. Si no,
    /// el record fue spoofed y se descarta.
    func createSharedLock(accessory: HMAccessory, home: HMHome, triggerUUID: UUID, expiresAt: Date?) async throws -> SharedLock {
        guard let zone = sharedZone else {
            throw CloudKitError.zoneNotSetup
        }

        let currentUserID = try await getCurrentUserID()
        let recordID = CKRecord.ID(recordName: UUID().uuidString, zoneID: zone.zoneID)
        let record = CKRecord(recordType: "SharedLock", recordID: recordID)

        record["accessoryUUID"] = accessory.uniqueIdentifier.uuidString
        record["accessoryName"] = accessory.name
        record["homeID"] = home.uniqueIdentifier.uuidString
        record["lockedByUserID"] = currentUserID
        record["lockedByName"] = UIDevice.current.name
        record["expiresAt"] = expiresAt
        record["createdAt"] = Date()
        record["triggerUUID"] = triggerUUID.uuidString

        let savedRecord = try await database.save(record)
        // En creación el creator siempre somos nosotros, así que isTrusted=true.
        let lock = SharedLock(from: savedRecord, isTrusted: true)

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

        let (results, _) = try await database.records(
            matching: query,
            inZoneWith: zone.zoneID
        )

        let locks = results.compactMap { _, result -> SharedLock? in
            guard case .success(let record) = result else { return nil }
            // Drop records forged by other share participants: si el
            // `creatorUserRecordID` (system, no-spoofable) no matchea con el
            // `lockedByUserID` escrito por el cliente, alguien intentó hacerse
            // pasar por otro usuario. Descartamos el record.
            guard Self.isRecordAuthentic(record) else {
                print("⚠️ [CloudKit] Record \(record.recordID.recordName) descartado: creator != lockedByUserID")
                return nil
            }
            return SharedLock(from: record, isTrusted: true)
        }

        await MainActor.run {
            self.sharedLocks = locks
        }

        return locks
    }

    func deleteLock(for accessoryID: UUID) async throws {
        guard sharedZone != nil else { return }

        let accessoryIDString = accessoryID.uuidString
        guard let lockToDelete = sharedLocks.first(where: { $0.accessoryUUID == accessoryIDString }) else {
            return
        }

        // Solo el creator del lock puede borrarlo. CloudKit enforza esto a
        // nivel de CKShare permissions (un `.readWrite` participant puede
        // borrar records ajenos si la zone se lo permite), así que añadimos
        // una guard client-side extra: si no somos el creator, rechazamos.
        let currentUserID = try await getCurrentUserID()
        if lockToDelete.lockedByUserID != currentUserID {
            throw CloudKitError.notAuthorized
        }

        try await database.deleteRecord(withID: lockToDelete.id)
        await MainActor.run {
            sharedLocks.removeAll { $0.accessoryUUID == accessoryIDString }
        }
    }

    /// Valida que el record no fue forged: el creator (system field) debe
    /// ser el mismo que `lockedByUserID` (user-writable). Si difieren, otro
    /// participante del CKShare creó el record y le puso un userID ajeno.
    private static func isRecordAuthentic(_ record: CKRecord) -> Bool {
        guard let creator = record.creatorUserRecordID?.recordName,
              let claimed = record["lockedByUserID"] as? String else {
            // Record sin creator = record local nunca subido, o sin userID
            // declarado = malformed. En ambos casos, descartamos.
            return false
        }
        return creator == claimed
    }
    
    func acceptShareMetadata(_ metadata: CKShare.Metadata) async throws {
        try await container.accept(metadata)

        // Refresh zone state so we pick up the new shared zone immediately,
        // without waiting for the next app launch / configure() pass.
        do {
            let participantZones = try await container.sharedCloudDatabase.allRecordZones()
            if let participantZone = participantZones.first(where: { $0.zoneID.zoneName.hasPrefix("HomeLockFamily-") }) {
                sharedZone = participantZone
                isParticipant = true
                print("☁️ [CloudKit] Participant zone activated after accept: \(participantZone.zoneID.zoneName)")
            }
        } catch {
            print("☁️ [CloudKit] Failed to refresh participant zone after accept: \(error.localizedDescription)")
        }
    }
    
    private func getCurrentUserID() async throws -> String {
        let recordID = try await container.userRecordID()
        return recordID.recordName
    }
    
    enum CloudKitError: Error {
        case zoneNotSetup
        case shareNotCreated
        case noShareURL
        case notAuthorized
    }
}
