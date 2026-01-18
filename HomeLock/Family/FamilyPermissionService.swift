//
//  FamilyPermissionService.swift
//  HomeLock
//
//  Created by Claude on 1/18/26.
//

import Foundation
import CloudKit
import Combine
import HomeKit

/// Servicio para gestionar permisos de familia y sincronización via CloudKit
@MainActor
class FamilyPermissionService: ObservableObject {
    static let shared = FamilyPermissionService()

    // MARK: - Published Properties

    @Published private(set) var isCloudKitAvailable = false
    @Published private(set) var currentUser: FamilyMember?
    @Published private(set) var familyHomes: [FamilyHome] = []
    @Published private(set) var sharedLocks: [SharedLock] = []
    @Published private(set) var familyMembers: [FamilyMember] = []
    @Published private(set) var recentActivities: [LockActivity] = []
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncDate: Date?
    @Published var errorMessage: String?

    // MARK: - Private Properties

    private let container: CKContainer
    private let privateDatabase: CKDatabase
    private let sharedDatabase: CKDatabase
    private var subscriptions: [CKSubscription] = []
    private var cancellables = Set<AnyCancellable>()

    private let userDefaultsCurrentHomeKey = "HomeLock_CurrentFamilyHomeID"
    private let userDefaultsUserNameKey = "HomeLock_UserDisplayName"

    // Zone for shared data
    private let sharedZoneName = "HomeLockSharedZone"
    private var sharedZone: CKRecordZone?

    // MARK: - Initialization

    private init() {
        // Use the default container or create one with your app's identifier
        self.container = CKContainer.default()
        self.privateDatabase = container.privateCloudDatabase
        self.sharedDatabase = container.sharedCloudDatabase

        print("👨‍👩‍👧‍👦 [FamilyService] Initialized")
    }

    // MARK: - Setup

    /// Inicializa el servicio y verifica disponibilidad de CloudKit
    func setup() async {
        print("👨‍👩‍👧‍👦 [FamilyService] Setting up...")

        // Check CloudKit availability
        do {
            let status = try await container.accountStatus()
            isCloudKitAvailable = status == .available

            if isCloudKitAvailable {
                print("✅ [FamilyService] CloudKit available")

                // Setup shared zone
                await setupSharedZone()

                // Get or create current user
                await fetchOrCreateCurrentUser()

                // Setup subscriptions for real-time updates
                await setupSubscriptions()

                // Initial sync
                await syncAll()
            } else {
                print("⚠️ [FamilyService] CloudKit not available: \(status)")
                errorMessage = String(localized: "iCloud is not available. Family sharing requires iCloud.")
            }
        } catch {
            print("❌ [FamilyService] Error checking CloudKit status: \(error)")
            isCloudKitAvailable = false
            errorMessage = error.localizedDescription
        }
    }

    /// Setup the shared record zone
    private func setupSharedZone() async {
        let zone = CKRecordZone(zoneName: sharedZoneName)

        do {
            let savedZone = try await privateDatabase.save(zone)
            sharedZone = savedZone
            print("✅ [FamilyService] Shared zone ready: \(savedZone.zoneID.zoneName)")
        } catch let error as CKError where error.code == .serverRecordChanged {
            // Zone already exists
            sharedZone = zone
            print("✅ [FamilyService] Shared zone already exists")
        } catch {
            print("❌ [FamilyService] Error creating shared zone: \(error)")
        }
    }

    // MARK: - User Management

    /// Obtiene o crea el usuario actual basado en su iCloud ID
    private func fetchOrCreateCurrentUser() async {
        do {
            let userID = try await container.userRecordID()
            let iCloudUserID = userID.recordName

            print("👤 [FamilyService] iCloud user ID: \(iCloudUserID)")

            // Try to find existing user
            let predicate = NSPredicate(format: "iCloudUserID == %@", iCloudUserID)
            let query = CKQuery(recordType: FamilyMember.recordType, predicate: predicate)

            let results = try await privateDatabase.records(matching: query)
            let records = results.matchResults.compactMap { try? $0.1.get() }

            if let record = records.first, let member = FamilyMember(from: record) {
                currentUser = member
                print("✅ [FamilyService] Found existing user: \(member.name)")

                // Update last seen
                await updateLastSeen(for: member)
            } else {
                // Create new user - will be set up when joining a home
                print("ℹ️ [FamilyService] No existing user found, will create when joining home")
            }
        } catch {
            print("❌ [FamilyService] Error fetching current user: \(error)")
        }
    }

    /// Crea un nuevo miembro para el usuario actual
    func createCurrentUser(name: String, forHomeID homeID: String) async -> FamilyMember? {
        guard isCloudKitAvailable else { return nil }

        do {
            let userID = try await container.userRecordID()
            let iCloudUserID = userID.recordName

            // Check if this is the first member (becomes admin)
            let existingMembers = await fetchMembersForHome(homeID: homeID)
            let role: FamilyMember.FamilyRole = existingMembers.isEmpty ? .admin : .member

            let member = FamilyMember(
                id: UUID().uuidString,
                name: name,
                iCloudUserID: iCloudUserID,
                role: role
            )

            let record = member.toRecord(homeID: homeID)
            let savedRecord = try await privateDatabase.save(record)

            if let savedMember = FamilyMember(from: savedRecord) {
                currentUser = savedMember
                UserDefaults.standard.set(name, forKey: userDefaultsUserNameKey)
                print("✅ [FamilyService] Created user: \(savedMember.name) as \(role.displayName)")
                return savedMember
            }
        } catch {
            print("❌ [FamilyService] Error creating user: \(error)")
            errorMessage = error.localizedDescription
        }

        return nil
    }

    /// Actualiza la fecha de última actividad del usuario
    private func updateLastSeen(for member: FamilyMember) async {
        var updatedMember = member
        updatedMember.lastSeenAt = Date()

        // Find the home ID for this member
        if let homeID = familyHomes.first(where: { $0.members.contains(where: { $0.id == member.id }) })?.id {
            let record = updatedMember.toRecord(homeID: homeID)

            do {
                _ = try await privateDatabase.save(record)
                currentUser = updatedMember
            } catch {
                print("⚠️ [FamilyService] Error updating last seen: \(error)")
            }
        }
    }

    // MARK: - Home Management

    /// Registra un HomeKit home para compartir
    func registerHome(_ home: HMHome) async -> FamilyHome? {
        guard isCloudKitAvailable else { return nil }

        let homeID = home.uniqueIdentifier.uuidString

        // Check if already registered
        if let existing = familyHomes.first(where: { $0.id == homeID }) {
            print("ℹ️ [FamilyService] Home already registered: \(existing.name)")
            return existing
        }

        let familyHome = FamilyHome(id: homeID, name: home.name)
        let record = familyHome.toRecord()

        do {
            let savedRecord = try await privateDatabase.save(record)
            if var savedHome = FamilyHome(from: savedRecord) {
                // Create current user as admin for this home
                let userName = UserDefaults.standard.string(forKey: userDefaultsUserNameKey) ?? "User"
                if let member = await createCurrentUser(name: userName, forHomeID: homeID) {
                    savedHome.members = [member]
                }

                familyHomes.append(savedHome)
                UserDefaults.standard.set(homeID, forKey: userDefaultsCurrentHomeKey)
                print("✅ [FamilyService] Registered home: \(savedHome.name)")
                return savedHome
            }
        } catch {
            print("❌ [FamilyService] Error registering home: \(error)")
            errorMessage = error.localizedDescription
        }

        return nil
    }

    /// Obtiene el home actual seleccionado
    func getCurrentHome() -> FamilyHome? {
        guard let homeID = UserDefaults.standard.string(forKey: userDefaultsCurrentHomeKey) else {
            return familyHomes.first
        }
        return familyHomes.first(where: { $0.id == homeID })
    }

    // MARK: - Shared Locks Management

    /// Crea un lock compartido y lo sincroniza
    func createSharedLock(
        accessoryID: UUID,
        accessoryName: String,
        roomName: String?,
        lockedState: Bool,
        expiresAt: Date?,
        homeID: String
    ) async -> SharedLock? {
        guard isCloudKitAvailable,
              let user = currentUser,
              user.role.canCreateLocks else {
            print("❌ [FamilyService] Cannot create lock: CloudKit unavailable or insufficient permissions")
            return nil
        }

        let lock = SharedLock(
            accessoryID: accessoryID,
            accessoryName: accessoryName,
            roomName: roomName,
            lockedState: lockedState,
            expiresAt: expiresAt,
            createdByID: user.id,
            createdByName: user.name,
            homeID: homeID
        )

        let record = lock.toRecord()

        do {
            let savedRecord = try await privateDatabase.save(record)
            if let savedLock = SharedLock(from: savedRecord) {
                sharedLocks.append(savedLock)

                // Log activity
                await logActivity(
                    lockID: savedLock.id,
                    accessoryName: accessoryName,
                    action: .created,
                    homeID: homeID
                )

                print("✅ [FamilyService] Created shared lock: \(savedLock.accessoryName)")
                return savedLock
            }
        } catch {
            print("❌ [FamilyService] Error creating shared lock: \(error)")
            errorMessage = error.localizedDescription
        }

        return nil
    }

    /// Elimina un lock compartido
    func removeSharedLock(lockID: String) async -> Bool {
        guard isCloudKitAvailable,
              let user = currentUser else {
            return false
        }

        guard let lock = sharedLocks.first(where: { $0.id == lockID }) else {
            return false
        }

        // Check permissions
        let canDelete = user.role.canDeleteOthersLocks || lock.createdByID == user.id
        guard canDelete else {
            print("❌ [FamilyService] Insufficient permissions to delete lock")
            errorMessage = String(localized: "You don't have permission to remove this lock")
            return false
        }

        let recordID = CKRecord.ID(recordName: lockID)

        do {
            try await privateDatabase.deleteRecord(withID: recordID)
            sharedLocks.removeAll(where: { $0.id == lockID })

            // Log activity
            await logActivity(
                lockID: lockID,
                accessoryName: lock.accessoryName,
                action: .removed,
                homeID: lock.homeID
            )

            print("✅ [FamilyService] Removed shared lock: \(lock.accessoryName)")
            return true
        } catch {
            print("❌ [FamilyService] Error removing shared lock: \(error)")
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Obtiene locks compartidos para un home específico
    func getSharedLocks(forHomeID homeID: String) -> [SharedLock] {
        return sharedLocks.filter { $0.homeID == homeID && !$0.isExpired }
    }

    /// Verifica si un accesorio tiene un lock compartido
    func hasSharedLock(accessoryID: UUID) -> SharedLock? {
        return sharedLocks.first(where: { $0.accessoryID == accessoryID && !$0.isExpired })
    }

    // MARK: - Activity Logging

    /// Registra una actividad de lock
    private func logActivity(lockID: String, accessoryName: String, action: LockActivity.LockAction, homeID: String) async {
        guard let user = currentUser else { return }

        let activity = LockActivity(
            lockID: lockID,
            accessoryName: accessoryName,
            action: action,
            performedByID: user.id,
            performedByName: user.name,
            homeID: homeID
        )

        let record = activity.toRecord()

        do {
            let savedRecord = try await privateDatabase.save(record)
            if let savedActivity = LockActivity(from: savedRecord) {
                recentActivities.insert(savedActivity, at: 0)

                // Keep only last 50 activities in memory
                if recentActivities.count > 50 {
                    recentActivities = Array(recentActivities.prefix(50))
                }
            }
        } catch {
            print("⚠️ [FamilyService] Error logging activity: \(error)")
        }
    }

    // MARK: - Member Management

    /// Obtiene miembros de un home específico
    func fetchMembersForHome(homeID: String) async -> [FamilyMember] {
        guard isCloudKitAvailable else { return [] }

        let predicate = NSPredicate(format: "homeID == %@", homeID)
        let query = CKQuery(recordType: FamilyMember.recordType, predicate: predicate)

        do {
            let results = try await privateDatabase.records(matching: query)
            let members = results.matchResults.compactMap { result -> FamilyMember? in
                guard let record = try? result.1.get() else { return nil }
                return FamilyMember(from: record)
            }
            return members
        } catch {
            print("❌ [FamilyService] Error fetching members: \(error)")
            return []
        }
    }

    /// Cambia el rol de un miembro (solo admin)
    func updateMemberRole(memberID: String, newRole: FamilyMember.FamilyRole, homeID: String) async -> Bool {
        guard let currentUser = currentUser,
              currentUser.role.canManageMembers else {
            errorMessage = String(localized: "Only admins can change member roles")
            return false
        }

        guard var member = familyMembers.first(where: { $0.id == memberID }) else {
            return false
        }

        member.role = newRole
        let record = member.toRecord(homeID: homeID)

        do {
            _ = try await privateDatabase.save(record)

            if let index = familyMembers.firstIndex(where: { $0.id == memberID }) {
                familyMembers[index] = member
            }

            print("✅ [FamilyService] Updated member role: \(member.name) -> \(newRole.displayName)")
            return true
        } catch {
            print("❌ [FamilyService] Error updating member role: \(error)")
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Elimina un miembro del home (solo admin)
    func removeMember(memberID: String) async -> Bool {
        guard let currentUser = currentUser,
              currentUser.role.canManageMembers,
              memberID != currentUser.id else {
            errorMessage = String(localized: "Cannot remove this member")
            return false
        }

        let recordID = CKRecord.ID(recordName: memberID)

        do {
            try await privateDatabase.deleteRecord(withID: recordID)
            familyMembers.removeAll(where: { $0.id == memberID })
            print("✅ [FamilyService] Removed member")
            return true
        } catch {
            print("❌ [FamilyService] Error removing member: \(error)")
            errorMessage = error.localizedDescription
            return false
        }
    }

    // MARK: - Sync

    /// Sincroniza todos los datos con CloudKit
    func syncAll() async {
        guard isCloudKitAvailable else { return }

        isSyncing = true
        defer {
            isSyncing = false
            lastSyncDate = Date()
        }

        print("🔄 [FamilyService] Starting sync...")

        // Sync homes
        await syncHomes()

        // Sync shared locks
        await syncSharedLocks()

        // Sync members
        await syncMembers()

        // Sync activities
        await syncActivities()

        print("✅ [FamilyService] Sync completed")
    }

    private func syncHomes() async {
        let query = CKQuery(recordType: FamilyHome.recordType, predicate: NSPredicate(value: true))

        do {
            let results = try await privateDatabase.records(matching: query)
            familyHomes = results.matchResults.compactMap { result -> FamilyHome? in
                guard let record = try? result.1.get() else { return nil }
                return FamilyHome(from: record)
            }
            print("📥 [FamilyService] Synced \(familyHomes.count) homes")
        } catch {
            print("❌ [FamilyService] Error syncing homes: \(error)")
        }
    }

    private func syncSharedLocks() async {
        let query = CKQuery(recordType: SharedLock.recordType, predicate: NSPredicate(value: true))
        query.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]

        do {
            let results = try await privateDatabase.records(matching: query)
            let allLocks = results.matchResults.compactMap { result -> SharedLock? in
                guard let record = try? result.1.get() else { return nil }
                return SharedLock(from: record)
            }

            // Filter out expired locks
            sharedLocks = allLocks.filter { !$0.isExpired }

            // Clean up expired locks from CloudKit
            let expiredLocks = allLocks.filter { $0.isExpired }
            for expiredLock in expiredLocks {
                let recordID = CKRecord.ID(recordName: expiredLock.id)
                try? await privateDatabase.deleteRecord(withID: recordID)
            }

            print("📥 [FamilyService] Synced \(sharedLocks.count) shared locks, cleaned \(expiredLocks.count) expired")
        } catch {
            print("❌ [FamilyService] Error syncing shared locks: \(error)")
        }
    }

    private func syncMembers() async {
        guard let homeID = getCurrentHome()?.id else { return }

        familyMembers = await fetchMembersForHome(homeID: homeID)
        print("📥 [FamilyService] Synced \(familyMembers.count) members")
    }

    private func syncActivities() async {
        guard let homeID = getCurrentHome()?.id else { return }

        let predicate = NSPredicate(format: "homeID == %@", homeID)
        let query = CKQuery(recordType: LockActivity.recordType, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]

        do {
            let results = try await privateDatabase.records(matching: query, resultsLimit: 50)
            recentActivities = results.matchResults.compactMap { result -> LockActivity? in
                guard let record = try? result.1.get() else { return nil }
                return LockActivity(from: record)
            }
            print("📥 [FamilyService] Synced \(recentActivities.count) activities")
        } catch {
            print("❌ [FamilyService] Error syncing activities: \(error)")
        }
    }

    // MARK: - Real-time Subscriptions

    /// Configura subscripciones para actualizaciones en tiempo real
    private func setupSubscriptions() async {
        guard isCloudKitAvailable else { return }

        // Subscribe to SharedLock changes
        await createSubscription(
            recordType: SharedLock.recordType,
            subscriptionID: "shared-locks-subscription"
        )

        // Subscribe to FamilyMember changes
        await createSubscription(
            recordType: FamilyMember.recordType,
            subscriptionID: "family-members-subscription"
        )

        // Subscribe to LockActivity changes
        await createSubscription(
            recordType: LockActivity.recordType,
            subscriptionID: "lock-activities-subscription"
        )

        print("✅ [FamilyService] Subscriptions configured")
    }

    private func createSubscription(recordType: String, subscriptionID: String) async {
        let predicate = NSPredicate(value: true)
        let subscription = CKQuerySubscription(
            recordType: recordType,
            predicate: predicate,
            subscriptionID: subscriptionID,
            options: [.firesOnRecordCreation, .firesOnRecordUpdate, .firesOnRecordDeletion]
        )

        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true
        subscription.notificationInfo = notificationInfo

        do {
            _ = try await privateDatabase.save(subscription)
            subscriptions.append(subscription)
        } catch let error as CKError where error.code == .serverRejectedRequest {
            // Subscription might already exist
            print("ℹ️ [FamilyService] Subscription may already exist: \(subscriptionID)")
        } catch {
            print("⚠️ [FamilyService] Error creating subscription \(subscriptionID): \(error)")
        }
    }

    /// Procesa una notificación de CloudKit
    func handleRemoteNotification(_ userInfo: [AnyHashable: Any]) async {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo as! [String: NSObject]),
              let queryNotification = notification as? CKQueryNotification else {
            return
        }

        print("📬 [FamilyService] Received CloudKit notification for: \(queryNotification.subscriptionID ?? "unknown")")

        // Refresh data based on notification type
        await syncAll()
    }

    // MARK: - Permissions Check

    /// Verifica si el usuario actual puede crear locks
    var canCreateLocks: Bool {
        currentUser?.role.canCreateLocks ?? false
    }

    /// Verifica si el usuario actual puede eliminar locks de otros
    var canDeleteOthersLocks: Bool {
        currentUser?.role.canDeleteOthersLocks ?? false
    }

    /// Verifica si el usuario actual puede gestionar miembros
    var canManageMembers: Bool {
        currentUser?.role.canManageMembers ?? false
    }

    /// Verifica si el usuario actual es el creador de un lock
    func isLockOwner(lockID: String) -> Bool {
        guard let user = currentUser,
              let lock = sharedLocks.first(where: { $0.id == lockID }) else {
            return false
        }
        return lock.createdByID == user.id
    }
}
