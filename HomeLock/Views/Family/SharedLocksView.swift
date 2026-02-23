import SwiftUI
import CloudKit

struct SharedLocksView: View {
    @ObservedObject var ckService = CloudKitService.shared
    
    var body: some View {
        if !ckService.sharedLocks.isEmpty {
            Section("Family Locks") {
                ForEach(ckService.sharedLocks) { lock in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(lock.accessoryName)
                                .font(.headline)
                            Text("Locked by \(lock.lockedByName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        Spacer()
                        
                        if let expiresAt = lock.expiresAt {
                            VStack(alignment: .trailing) {
                                Text("Ends")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                Text(expiresAt, style: .time)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                            }
                        } else {
                            Image(systemName: "lock.fill")
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}
