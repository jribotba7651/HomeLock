//
//  CloudKitService.swift
//  HomeLock
//
//  Created by Claude on 1/18/26.
//

import Foundation
import CloudKit
import Combine

/// Service for syncing locks via CloudKit
@MainActor
class CloudKitService: ObservableObject {
    // MARK: - Singleton
    static let shared = CloudKitService()

    // MARK: - CloudKit Configuration
    private let containerIdentifier = "iCloud.com.jibaroenlaluna.HomeLock"
    private lazy var container = CKContainer(identifier: containerIdentifier)
    private lazy var privateDatabase = container.privateCloudDatabase

    // MARK: - Published Properties
    @Published private(set) var isAvailable = false
    @Published private(set) var accountStatus: CKAccountStatus = .couldNotDetermine
    @Published private(set) var sharedLocks: [SharedLock] = []
    @Published private(set) var lastSyncDate: Date?
    @Published private(set) var syncError: Error?

    // MARK: - Error Types
    enum CloudKitError: LocalizedError {
        case notAuthenticated
        case networkUnavailable
        case recordNotFound
        case saveFailed(Error)
        case fetchFailed(Error)
        case deleteFailed(Error)

        var errorDescription: String? {
            switch self {
            case .notAuthenticated:
                return "iCloud account not available. Please sign in to iCloud in Settings."
            case .networkUnavailable:
                return "Network unavailable. Please check your connection."
            case .recordNotFound:
                return "Lock not found in iCloud."
            case .saveFailed(let error):
                return "Failed to save lock: \(error.localizedDescription)"
            case .fetchFailed(let error):
                return "Failed to fetch locks: \(error.localizedDescription)"
            case .deleteFailed(let error):
                return "Failed to delete lock: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Initialization
    private init() {
        print("☁️ [CloudKitService] Initializing...")
        Task {
            await checkAccountStatus()
        }
    }

    // MARK: - Account Status

    /// Check iCloud account status
    func checkAccountStatus() async {
        do {
            let status = try await container.accountStatus()
            accountStatus = status
            isAvailable = (status == .available)

            print("☁️ [CloudKitService] Account status: \(statusDescription(status))")

            if isAvailable {
                // Fetch locks when account becomes available
                await fetchAllLocks()
            }
        } catch {
            print("❌ [CloudKitService] Error checking account status: \(error)")
            isAvailable = false
            syncError = error
        }
    }

    private func statusDescription(_ status: CKAccountStatus) -> String {
        switch status {
        case .available: return "Available"
        case .noAccount: return "No Account"
        case .restricted: return "Restricted"
        case .couldNotDetermine: return "Could Not Determine"
        case .temporarilyUnavailable: return "Temporarily Unavailable"
        @unknown default: return "Unknown"
        }
    }

    // MARK: - Create Lock

    /// Save a new shared lock to CloudKit
    /// - Parameter lock: The SharedLock to save
    /// - Returns: The saved SharedLock with any server-side modifications
    func createLock(_ lock: SharedLock) async throws -> SharedLock {
        guard isAvailable else {
            throw CloudKitError.notAuthenticated
        }

        print("☁️ [CloudKitService] Creating lock for: \(lock.accessoryName)")

        let record = lock.toRecord()

        do {
            let savedRecord = try await privateDatabase.save(record)
            print("✅ [CloudKitService] Lock saved successfully: \(lock.accessoryName)")

            guard let savedLock = SharedLock(record: savedRecord) else {
                throw CloudKitError.saveFailed(NSError(domain: "CloudKitService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to parse saved record"]))
            }

            // Update local cache
            if let index = sharedLocks.firstIndex(where: { $0.accessoryID == savedLock.accessoryID }) {
                sharedLocks[index] = savedLock
            } else {
                sharedLocks.append(savedLock)
            }

            syncError = nil
            return savedLock

        } catch {
            print("❌ [CloudKitService] Error saving lock: \(error)")
            syncError = error
            throw CloudKitError.saveFailed(error)
        }
    }

    // MARK: - Fetch Locks

    /// Fetch all shared locks from CloudKit
    func fetchAllLocks() async {
        guard isAvailable else {
            print("⚠️ [CloudKitService] Cannot fetch - iCloud not available")
            return
        }

        print("☁️ [CloudKitService] Fetching all locks...")

        let query = CKQuery(recordType: SharedLock.recordType, predicate: NSPredicate(value: true))
        query.sortDescriptors = [NSSortDescriptor(key: SharedLock.FieldKey.createdAt.rawValue, ascending: false)]

        do {
            let (matchResults, _) = try await privateDatabase.records(matching: query)

            var fetchedLocks: [SharedLock] = []

            for (_, result) in matchResults {
                switch result {
                case .success(let record):
                    if let lock = SharedLock(record: record) {
                        // Filter out expired locks
                        if !lock.isExpired {
                            fetchedLocks.append(lock)
                        } else {
                            // Delete expired lock from CloudKit
                            Task {
                                try? await deleteLock(lock)
                            }
                        }
                    }
                case .failure(let error):
                    print("⚠️ [CloudKitService] Error fetching record: \(error)")
                }
            }

            sharedLocks = fetchedLocks
            lastSyncDate = Date()
            syncError = nil

            print("✅ [CloudKitService] Fetched \(fetchedLocks.count) locks")

        } catch {
            print("❌ [CloudKitService] Error fetching locks: \(error)")
            syncError = error
        }
    }

    /// Fetch a specific lock by accessory ID
    /// - Parameter accessoryID: The UUID of the accessory
    /// - Returns: The SharedLock if found
    func fetchLock(for accessoryID: UUID) async throws -> SharedLock? {
        guard isAvailable else {
            throw CloudKitError.notAuthenticated
        }

        print("☁️ [CloudKitService] Fetching lock for accessory: \(accessoryID)")

        let predicate = NSPredicate(format: "%K == %@", SharedLock.FieldKey.accessoryID.rawValue, accessoryID.uuidString)
        let query = CKQuery(recordType: SharedLock.recordType, predicate: predicate)

        do {
            let (matchResults, _) = try await privateDatabase.records(matching: query)

            for (_, result) in matchResults {
                switch result {
                case .success(let record):
                    if let lock = SharedLock(record: record), !lock.isExpired {
                        return lock
                    }
                case .failure(let error):
                    print("⚠️ [CloudKitService] Error fetching record: \(error)")
                }
            }

            return nil

        } catch {
            print("❌ [CloudKitService] Error fetching lock: \(error)")
            throw CloudKitError.fetchFailed(error)
        }
    }

    // MARK: - Delete Lock

    /// Delete a shared lock from CloudKit
    /// - Parameter lock: The SharedLock to delete
    func deleteLock(_ lock: SharedLock) async throws {
        guard isAvailable else {
            throw CloudKitError.notAuthenticated
        }

        print("☁️ [CloudKitService] Deleting lock: \(lock.accessoryName)")

        do {
            try await privateDatabase.deleteRecord(withID: lock.recordID)
            print("✅ [CloudKitService] Lock deleted successfully: \(lock.accessoryName)")

            // Update local cache
            sharedLocks.removeAll { $0.id == lock.id }
            syncError = nil

        } catch {
            print("❌ [CloudKitService] Error deleting lock: \(error)")
            syncError = error
            throw CloudKitError.deleteFailed(error)
        }
    }

    /// Delete a lock by accessory ID
    /// - Parameter accessoryID: The UUID of the accessory
    func deleteLock(for accessoryID: UUID) async throws {
        // First, try to find in local cache
        if let lock = sharedLocks.first(where: { $0.accessoryID == accessoryID }) {
            try await deleteLock(lock)
            return
        }

        // If not in cache, fetch from CloudKit and delete
        if let lock = try await fetchLock(for: accessoryID) {
            try await deleteLock(lock)
        }
    }

    // MARK: - Subscription for Real-time Updates

    /// Subscribe to lock changes for real-time updates
    func subscribeToChanges() async {
        guard isAvailable else { return }

        let subscriptionID = "shared-locks-changes"

        // Check if subscription already exists
        do {
            _ = try await privateDatabase.subscription(for: subscriptionID)
            print("☁️ [CloudKitService] Subscription already exists")
            return
        } catch {
            // Subscription doesn't exist, create it
        }

        let subscription = CKQuerySubscription(
            recordType: SharedLock.recordType,
            predicate: NSPredicate(value: true),
            subscriptionID: subscriptionID,
            options: [.firesOnRecordCreation, .firesOnRecordDeletion, .firesOnRecordUpdate]
        )

        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true
        subscription.notificationInfo = notificationInfo

        do {
            try await privateDatabase.save(subscription)
            print("✅ [CloudKitService] Subscribed to lock changes")
        } catch {
            print("⚠️ [CloudKitService] Error creating subscription: \(error)")
        }
    }

    // MARK: - Helper Methods

    /// Check if a lock exists for the given accessory
    func hasLock(for accessoryID: UUID) -> Bool {
        sharedLocks.contains { $0.accessoryID == accessoryID && !$0.isExpired }
    }

    /// Get the lock for a specific accessory from local cache
    func getLock(for accessoryID: UUID) -> SharedLock? {
        sharedLocks.first { $0.accessoryID == accessoryID && !$0.isExpired }
    }

    /// Force refresh locks from CloudKit
    func refresh() async {
        await fetchAllLocks()
    }
}
