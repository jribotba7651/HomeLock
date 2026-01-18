//
//  FamilyView.swift
//  HomeLock
//
//  Created by Claude on 1/18/26.
//

import SwiftUI
import HomeKit

/// Vista principal para gestionar la familia y compartir locks
struct FamilyView: View {
    @ObservedObject var familyService: FamilyPermissionService
    @ObservedObject var lockManager: LockManager
    @ObservedObject var homeKit: HomeKitService

    @State private var showingSetupSheet = false
    @State private var showingMemberActions = false
    @State private var selectedMember: FamilyMember?
    @State private var userName: String = ""

    var body: some View {
        NavigationStack {
            Group {
                if !familyService.isCloudKitAvailable {
                    CloudKitUnavailableView()
                } else if familyService.currentUser == nil {
                    SetupRequiredView(showSetup: $showingSetupSheet)
                } else {
                    mainContent
                }
            }
            .navigationTitle(String(localized: "Family"))
            .toolbar {
                if familyService.isCloudKitAvailable && familyService.currentUser != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        if familyService.isSyncing {
                            ProgressView()
                        } else {
                            Button {
                                Task {
                                    await familyService.syncAll()
                                }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                    }
                }
            }
            .sheet(isPresented: $showingSetupSheet) {
                FamilySetupSheet(
                    familyService: familyService,
                    homeKit: homeKit,
                    userName: $userName
                )
            }
            .refreshable {
                await familyService.syncAll()
            }
        }
    }

    private var mainContent: some View {
        List {
            // Current user section
            if let user = familyService.currentUser {
                Section {
                    HStack {
                        Image(systemName: "person.circle.fill")
                            .font(.title)
                            .foregroundStyle(.blue)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(user.name)
                                .font(.headline)
                            Text(user.role.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                } header: {
                    Text(String(localized: "Your Account"))
                }
            }

            // Shared locks section
            Section {
                NavigationLink {
                    SharedLocksView(familyService: familyService, lockManager: lockManager)
                } label: {
                    HStack {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.orange)
                        Text(String(localized: "Shared Locks"))
                        Spacer()
                        Text("\(familyService.sharedLocks.filter { !$0.isExpired }.count)")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(String(localized: "Locks"))
            }

            // Family members section
            Section {
                ForEach(familyService.familyMembers) { member in
                    FamilyMemberRow(
                        member: member,
                        isCurrentUser: member.id == familyService.currentUser?.id,
                        canManage: familyService.canManageMembers,
                        onTap: {
                            if familyService.canManageMembers && member.id != familyService.currentUser?.id {
                                selectedMember = member
                                showingMemberActions = true
                            }
                        }
                    )
                }

                if familyService.familyMembers.isEmpty {
                    Text(String(localized: "No other family members yet"))
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
            } header: {
                Text(String(localized: "Family Members"))
            } footer: {
                Text(String(localized: "Family members sharing this HomeKit home can see and manage shared locks."))
            }

            // Recent activity section
            Section {
                if familyService.recentActivities.isEmpty {
                    Text(String(localized: "No recent activity"))
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                } else {
                    ForEach(familyService.recentActivities.prefix(5)) { activity in
                        ActivityRow(activity: activity)
                    }

                    if familyService.recentActivities.count > 5 {
                        NavigationLink {
                            ActivityHistoryView(activities: familyService.recentActivities)
                        } label: {
                            Text(String(localized: "See all activity"))
                        }
                    }
                }
            } header: {
                Text(String(localized: "Recent Activity"))
            }

            // Sync info
            Section {
                if let lastSync = familyService.lastSyncDate {
                    HStack {
                        Text(String(localized: "Last synced"))
                        Spacer()
                        Text(lastSync, style: .relative)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Text(String(localized: "Sync status"))
                    Spacer()
                    HStack(spacing: 4) {
                        Circle()
                            .fill(familyService.isCloudKitAvailable ? .green : .red)
                            .frame(width: 8, height: 8)
                        Text(familyService.isCloudKitAvailable ? String(localized: "Connected") : String(localized: "Offline"))
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(String(localized: "Sync"))
            }
        }
        .confirmationDialog(
            String(localized: "Member Options"),
            isPresented: $showingMemberActions,
            titleVisibility: .visible
        ) {
            if let member = selectedMember {
                Button(String(localized: "Make Admin")) {
                    Task {
                        if let homeID = familyService.getCurrentHome()?.id {
                            _ = await familyService.updateMemberRole(memberID: member.id, newRole: .admin, homeID: homeID)
                        }
                    }
                }

                Button(String(localized: "Make Member")) {
                    Task {
                        if let homeID = familyService.getCurrentHome()?.id {
                            _ = await familyService.updateMemberRole(memberID: member.id, newRole: .member, homeID: homeID)
                        }
                    }
                }

                Button(String(localized: "Make Viewer")) {
                    Task {
                        if let homeID = familyService.getCurrentHome()?.id {
                            _ = await familyService.updateMemberRole(memberID: member.id, newRole: .viewer, homeID: homeID)
                        }
                    }
                }

                Button(String(localized: "Remove from Family"), role: .destructive) {
                    Task {
                        _ = await familyService.removeMember(memberID: member.id)
                    }
                }

                Button(String(localized: "Cancel"), role: .cancel) {
                    selectedMember = nil
                }
            }
        }
    }
}

// MARK: - Supporting Views

struct SetupRequiredView: View {
    @Binding var showSetup: Bool

    var body: some View {
        ContentUnavailableView {
            Label(String(localized: "Setup Required"), systemImage: "person.2.fill")
        } description: {
            Text(String(localized: "Set up family sharing to let everyone in your home see and manage device locks."))
        } actions: {
            Button(String(localized: "Get Started")) {
                showSetup = true
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

struct FamilySetupSheet: View {
    @ObservedObject var familyService: FamilyPermissionService
    @ObservedObject var homeKit: HomeKitService
    @Binding var userName: String

    @Environment(\.dismiss) private var dismiss
    @State private var selectedHome: HMHome?
    @State private var isCreating = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "Your Name"), text: $userName)
                        .textContentType(.name)
                        .autocorrectionDisabled()
                } header: {
                    Text(String(localized: "Your Display Name"))
                } footer: {
                    Text(String(localized: "This name will be shown to other family members."))
                }

                Section {
                    ForEach(homeKit.homes, id: \.uniqueIdentifier) { home in
                        Button {
                            selectedHome = home
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(home.name)
                                        .foregroundStyle(.primary)
                                    Text("\(home.accessories.count) devices")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                if selectedHome?.uniqueIdentifier == home.uniqueIdentifier {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                    }

                    if homeKit.homes.isEmpty {
                        Text(String(localized: "No HomeKit homes found"))
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(String(localized: "Select Home"))
                } footer: {
                    Text(String(localized: "Choose the home to share with family members."))
                }
            }
            .navigationTitle(String(localized: "Family Setup"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Create")) {
                        createFamily()
                    }
                    .disabled(userName.isEmpty || selectedHome == nil || isCreating)
                }
            }
        }
    }

    private func createFamily() {
        guard let home = selectedHome else { return }

        isCreating = true

        Task {
            // Save user name
            UserDefaults.standard.set(userName, forKey: "HomeLock_UserDisplayName")

            // Register home
            if let familyHome = await familyService.registerHome(home) {
                print("✅ Family home created: \(familyHome.name)")
            }

            await MainActor.run {
                isCreating = false
                dismiss()
            }
        }
    }
}

struct FamilyMemberRow: View {
    let member: FamilyMember
    let isCurrentUser: Bool
    let canManage: Bool
    let onTap: () -> Void

    var body: some View {
        Button {
            onTap()
        } label: {
            HStack {
                Image(systemName: isCurrentUser ? "person.circle.fill" : "person.circle")
                    .font(.title2)
                    .foregroundStyle(isCurrentUser ? .blue : .secondary)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(member.name)
                            .font(.body)
                            .foregroundStyle(.primary)

                        if isCurrentUser {
                            Text(String(localized: "(You)"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text(member.role.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if member.role == .admin {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                }

                if canManage && !isCurrentUser {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!canManage || isCurrentUser)
    }
}

struct ActivityRow: View {
    let activity: LockActivity

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: activity.action.systemImage)
                .font(.body)
                .foregroundStyle(colorForAction(activity.action))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(activity.accessoryName)
                        .font(.subheadline)
                        .fontWeight(.medium)

                    Text("·")
                        .foregroundStyle(.secondary)

                    Text(activity.action.displayName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 4) {
                    Text(activity.performedByName)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(activity.timestamp, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func colorForAction(_ action: LockActivity.LockAction) -> Color {
        switch action {
        case .created: return .orange
        case .removed: return .green
        case .expired: return .gray
        case .modified: return .blue
        }
    }
}

struct ActivityHistoryView: View {
    let activities: [LockActivity]

    var body: some View {
        List {
            ForEach(activities) { activity in
                ActivityRow(activity: activity)
            }
        }
        .navigationTitle(String(localized: "Activity History"))
    }
}

// MARK: - Preview

#Preview {
    FamilyView(
        familyService: FamilyPermissionService.shared,
        lockManager: LockManager.shared,
        homeKit: HomeKitService()
    )
}
