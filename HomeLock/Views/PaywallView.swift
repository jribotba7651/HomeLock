import SwiftUI
import StoreKit

struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var storeManager = StoreManager.shared
    @State private var isPurchasing = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 12) {
                    Image(systemName: "crown.fill")
                        .font(.system(size: 60))
                        .foregroundStyle(.yellow)
                        .padding(.top, 40)
                    
                    Text("HomeLock Pro")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                    
                    Text("Unlimited devices, ultimate security")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                
                // Features
                VStack(alignment: .leading, spacing: 20) {
                    FeatureRow(title: "Unlimited Device Locks", description: "Lock as many plugs, switches, and lights as you need.", icon: "infinity")
                    FeatureRow(title: "Family Sync", description: "Share your locks with your family via CloudKit.", icon: "person.2.fill")
                    FeatureRow(title: "Lifetime Access", description: "One-time purchase. No subscriptions, ever.", icon: "heart.fill")
                }
                .padding(.horizontal, 32)
                .padding(.top, 24)
                
                Spacer()
                
                // Purchase Section
                VStack(spacing: 16) {
                    if let product = storeManager.products.first {
                        Button {
                            Task {
                                isPurchasing = true
                                defer { isPurchasing = false }
                                try? await storeManager.purchase()
                            }
                        } label: {
                            HStack {
                                Text("Upgrade for \(product.displayPrice)")
                                    .fontWeight(.bold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(16)
                        }
                        .disabled(isPurchasing)
                    } else {
                        ProgressView("Loading products...")
                    }
                    
                    Button("Restore Purchases") {
                        Task {
                            await storeManager.restorePurchases()
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 32)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.title3)
                    }
                }
            }
        }
    }
}

struct FeatureRow: View {
    let title: String
    let description: String
    let icon: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 32)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    PaywallView()
}
