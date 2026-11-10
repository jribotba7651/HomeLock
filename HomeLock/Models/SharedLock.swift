import Foundation
import CloudKit

struct SharedLock: Identifiable {
    let id: CKRecord.ID
    let accessoryUUID: String
    let accessoryName: String
    let homeID: String
    let lockedByUserID: String
    let lockedByName: String
    let expiresAt: Date?
    let createdAt: Date
    let triggerUUID: String
    /// True si `creatorUserRecordID` (system field) matchea `lockedByUserID`.
    /// CloudKitService filtra los no-trusted, así que los callers pueden asumir
    /// true, pero el flag queda explícito para UI que quiera mostrarlo.
    let isTrusted: Bool

    init(from record: CKRecord, isTrusted: Bool = false) {
        self.id = record.recordID
        self.accessoryUUID = record["accessoryUUID"] as? String ?? ""
        self.accessoryName = record["accessoryName"] as? String ?? "Unknown"
        self.homeID = record["homeID"] as? String ?? ""
        self.lockedByUserID = record["lockedByUserID"] as? String ?? ""
        self.lockedByName = record["lockedByName"] as? String ?? "Unknown"
        self.expiresAt = record["expiresAt"] as? Date
        self.createdAt = record["createdAt"] as? Date ?? Date()
        self.triggerUUID = record["triggerUUID"] as? String ?? ""
        self.isTrusted = isTrusted
    }
}
