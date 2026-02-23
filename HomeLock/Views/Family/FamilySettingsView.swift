import SwiftUI
import CloudKit
import HomeKit

struct FamilySettingsView: View {
    @StateObject private var ckService = CloudKitService.shared
    @State private var isInviting = false
    @State private var activeShare: CKShare?
    @State private var activeContainer: CKContainer?
    @State private var showingSharingController = false
    @State private var showingShareSheet = false
    @State private var errorMessage: String?
    
    var body: some View {
        List {
            Section("Family Sharing") {
                Text("Share HomeLock with your family members to synchronize device locks and see who locked which device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Button(action: inviteMember) {
                    if isInviting {
                        ProgressView()
                            .padding(.trailing, 8)
                    }
                    HStack {
                        Image(systemName: "person.badge.plus")
                        Text("Invite Family Member")
                    }
                }
                .disabled(isInviting)
                
                if let share = activeShare, let url = share.url {
                    Button(action: { showingShareSheet = true }) {
                        HStack {
                            Image(systemName: "square.and.arrow.up")
                            Text("Share Link Manually")
                        }
                    }
                    .padding(.top, 4)
                }
            }
            
            if !ckService.sharedLocks.isEmpty {
                Section("Shared Locks") {
                    ForEach(ckService.sharedLocks) { lock in
                        VStack(alignment: .leading) {
                            Text(lock.accessoryName)
                                .font(.headline)
                            HStack {
                                Text("Locked by \(lock.lockedByName)")
                                Spacer()
                                if let expiresAt = lock.expiresAt {
                                    Text("Ends \(expiresAt, style: .time)")
                                } else {
                                    Text("Indefinite")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Family Settings")
        .sheet(isPresented: $showingSharingController) {
            if let share = activeShare, let container = activeContainer {
                CloudSharingView(share: share, container: container)
            }
        }
        .sheet(isPresented: $showingShareSheet) {
            if let url = activeShare?.url {
                ShareSheet(items: [url])
            }
        }
        .alert("Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: {
            if let msg = errorMessage {
                Text(msg)
            }
        }
    }
    
    func inviteMember() {
        Task {
            isInviting = true
            defer { isInviting = false }
            
            do {
                guard let home = HomeKitService.shared.homes.first else {
                    errorMessage = "No HomeKit home found"
                    return
                }
                
                try await ckService.setupSharedZone(for: home.uniqueIdentifier)
                let share = try await ckService.createFamilyShare(for: home.uniqueIdentifier)
                
                self.activeShare = share
                self.activeContainer = CKContainer(identifier: "iCloud.com.jibaroenlaluna.HomeLock")
                self.showingSharingController = true
                
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct CloudSharingView: UIViewControllerRepresentable {
    let share: CKShare
    let container: CKContainer

    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(share: share, container: container)
        // Usamos los permisos por defecto para asegurar que aparezca el botón de "Añadir personas"
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UICloudSharingController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, UICloudSharingControllerDelegate {
        func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
            print("❌ [CloudSharingView] Failed to save share: \(error.localizedDescription)")
        }

        func itemTitle(for csc: UICloudSharingController) -> String? {
            "HomeLock Family"
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
