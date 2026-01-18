//
//  PaywallView.swift
//  HomeLock
//

import SwiftUI
import StoreKit

struct PaywallView: View {
    @ObservedObject var storeManager = StoreManager.shared
    @Binding var isPresented: Bool
    @State private var isPurchasing = false
    @State private var showError = false
    @State private var errorMessage = ""

    var body: some View {
        ZStack {
            // Background
            Color.black.ignoresSafeArea()

            VStack(spacing: 24) {
                // Close button
                HStack {
                    Spacer()
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.gray)
                            .frame(width: 32, height: 32)
                            .background(Color.white.opacity(0.1))
                            .clipShape(Circle())
                    }
                }
                .padding(.horizontal)

                Spacer()

                // Crown icon
                Image(systemName: "crown.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.yellow)
                    .padding(.bottom, 8)

                // Title
                Text("Upgrade to Pro")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundColor(.white)

                Text("Unlock all premium features")
                    .font(.system(size: 16))
                    .foregroundColor(.gray)

                // Features list
                VStack(alignment: .leading, spacing: 20) {
                    FeatureRow(
                        icon: "calendar.badge.plus",
                        iconColor: .blue,
                        title: "Unlimited Schedules",
                        description: "Create unlimited auto-lock schedules"
                    )

                    FeatureRow(
                        icon: "clock.arrow.circlepath",
                        iconColor: .orange,
                        title: "Full History",
                        description: "Access complete lock/unlock history"
                    )

                    FeatureRow(
                        icon: "person.3.fill",
                        iconColor: .cyan,
                        title: "Multi-User Sync",
                        description: "Sync with all home members"
                    )

                    FeatureRow(
                        icon: "bell.badge.fill",
                        iconColor: .purple,
                        title: "Priority Notifications",
                        description: "Get instant tamper alerts"
                    )
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 24)

                Spacer()

                // Price and purchase button
                VStack(spacing: 16) {
                    if let product = storeManager.products.first {
                        Text(product.displayPrice)
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(.white)

                        Text("One-time purchase. No subscription.")
                            .font(.system(size: 14))
                            .foregroundColor(.gray)
                    }

                    // Upgrade button
                    Button {
                        Task {
                            isPurchasing = true
                            do {
                                try await storeManager.purchase()
                                if storeManager.isPro {
                                    isPresented = false
                                }
                            } catch {
                                errorMessage = error.localizedDescription
                                showError = true
                            }
                            isPurchasing = false
                        }
                    } label: {
                        HStack {
                            if isPurchasing {
                                ProgressView()
                                    .tint(.black)
                            } else {
                                Text("Upgrade to Pro")
                                    .font(.system(size: 18, weight: .semibold))
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(
                            LinearGradient(
                                colors: [Color.blue, Color.blue.opacity(0.8)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .foregroundColor(.white)
                        .cornerRadius(14)
                    }
                    .disabled(isPurchasing)
                    .padding(.horizontal, 24)

                    // Restore purchases
                    Button {
                        Task {
                            await storeManager.restorePurchases()
                            if storeManager.isPro {
                                isPresented = false
                            }
                        }
                    } label: {
                        Text("Restore Purchases")
                            .font(.system(size: 16))
                            .foregroundColor(.blue)
                    }

                    // Continue free
                    Button {
                        isPresented = false
                    } label: {
                        Text("Continue with Free")
                            .font(.system(size: 14))
                            .foregroundColor(.gray)
                    }
                    .padding(.top, 8)
                }
                .padding(.bottom, 40)
            }
        }
        .alert("Purchase Error", isPresented: $showError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage)
        }
    }
}

struct FeatureRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let description: String

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundColor(iconColor)
                .frame(width: 44, height: 44)
                .background(iconColor.opacity(0.15))
                .cornerRadius(10)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)

                Text(description)
                    .font(.system(size: 13))
                    .foregroundColor(.gray)
            }

            Spacer()
        }
    }
}

#Preview {
    PaywallView(isPresented: .constant(true))
}
