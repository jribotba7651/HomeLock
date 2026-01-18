//
//  PaywallView.swift
//  HomeLock
//
//  Created by Juan C. Ribot on 1/18/26.
//

import SwiftUI
import StoreKit

/// Paywall view for upgrading to HomeLock Pro
struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = StoreManager.shared

    @State private var isPurchasing = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 32) {
                    // MARK: - Header
                    headerSection

                    // MARK: - Features
                    featuresSection

                    Spacer(minLength: 20)

                    // MARK: - Purchase Section
                    purchaseSection
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .alert(String(localized: "Error"), isPresented: .constant(store.errorMessage != nil)) {
                Button("OK") {
                    store.errorMessage = nil
                }
            } message: {
                Text(store.errorMessage ?? "")
            }
        }
    }

    // MARK: - Header Section

    private var headerSection: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 70))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.orange, .red],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: .orange.opacity(0.3), radius: 10, y: 5)

            Text(String(localized: "Upgrade to Pro"))
                .font(.largeTitle)
                .fontWeight(.bold)

            Text(String(localized: "Unlock unlimited device control"))
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 40)
    }

    // MARK: - Features Section

    private var featuresSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            FeatureRow(
                icon: "infinity",
                title: String(localized: "Unlimited Devices"),
                description: String(localized: "Lock as many devices as you need")
            )

            FeatureRow(
                icon: "wand.and.stars",
                title: String(localized: "Siri & Shortcuts"),
                description: String(localized: "Control locks with your voice (coming soon)")
            )

            FeatureRow(
                icon: "person.3.fill",
                title: String(localized: "Family Sync"),
                description: String(localized: "Share lock settings across devices (coming soon)")
            )

            FeatureRow(
                icon: "heart.fill",
                title: String(localized: "Support Development"),
                description: String(localized: "Help us build more features")
            )
        }
        .padding(24)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Purchase Section

    private var purchaseSection: some View {
        VStack(spacing: 16) {
            if let product = store.products.first {
                // Price display
                VStack(spacing: 4) {
                    Text(product.displayPrice)
                        .font(.system(size: 44, weight: .bold, design: .rounded))

                    Text(String(localized: "One-Time Purchase"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                // Purchase button
                Button {
                    Task {
                        isPurchasing = true
                        defer { isPurchasing = false }

                        do {
                            let success = try await store.purchase()
                            if success {
                                dismiss()
                            }
                        } catch {
                            print("Purchase error: \(error)")
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        if isPurchasing || store.isLoading {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: "lock.open.fill")
                        }
                        Text(String(localized: "Upgrade to Pro"))
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        LinearGradient(
                            colors: [.orange, .red],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .disabled(isPurchasing || store.isLoading)

            } else if store.isLoading {
                ProgressView()
                    .padding(.vertical, 40)
            } else {
                // Products failed to load
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)

                    Text(String(localized: "Unable to load products"))
                        .foregroundStyle(.secondary)

                    Button(String(localized: "Try Again")) {
                        Task {
                            await store.loadProducts()
                        }
                    }
                }
                .padding(.vertical, 20)
            }

            // Restore button
            Button {
                Task {
                    await store.restore()
                    if store.isPro {
                        dismiss()
                    }
                }
            } label: {
                Text(String(localized: "Restore Purchase"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .disabled(store.isLoading)

            // Free tier info
            Text(String(localized: "Free plan includes 2 devices"))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 8)
        }
        .padding(.bottom, 32)
    }
}

// MARK: - Feature Row

private struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.orange)
                .frame(width: 32, height: 32)

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

// MARK: - Limit Reached View

/// Compact banner shown when device limit is reached
struct DeviceLimitBanner: View {
    @Binding var showPaywall: Bool

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)

                Text(String(localized: "Free plan limit reached"))
                    .font(.subheadline)
                    .fontWeight(.medium)

                Spacer()
            }

            Text(String(localized: "Upgrade to Pro to lock unlimited devices"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                showPaywall = true
            } label: {
                Text(String(localized: "Upgrade to Pro"))
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(.orange)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding()
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Preview

#Preview("Paywall") {
    PaywallView()
}

#Preview("Limit Banner") {
    DeviceLimitBanner(showPaywall: .constant(false))
        .padding()
}
