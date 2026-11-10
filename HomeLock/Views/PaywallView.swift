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
    @State private var isRestoring = false
    @State private var showError = false
    @State private var errorMessage = ""

    /// Only features that are actually gated by `StoreManager.isPro` in code:
    /// - Locks:     LockManager.canAddLock (free tier: 2 locked devices at once)
    /// - Schedules: ScheduleListView.freeScheduleLimit (free tier: 1 schedule)
    /// - History:   HistoryView.freeHistoryDays (free tier: last 7 days)
    private let features: [(icon: String, text: String)] = [
        ("lock.fill", "Lock any number of devices at once"),
        ("calendar.badge.clock", "Unlimited schedules"),
        ("clock.arrow.circlepath", "Full lock history, not just the last 7 days"),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    header
                    featureList
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 16)
            }
            .safeAreaInset(edge: .bottom) {
                purchaseSection
            }
            .background(Color(UIColor.systemBackground))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        withAnimation {
                            isPresented = false
                        }
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                    .disabled(isRestoring)
                }
            }
        }
        .alert("Purchase Error", isPresented: $showError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            Text("HomeLock Pro")
                .font(.largeTitle.bold())

            Text("More locks, more schedules, your full history.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Features

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(features, id: \.text) { feature in
                Label {
                    Text(feature.text)
                        .font(.body)
                } icon: {
                    Image(systemName: feature.icon)
                        .foregroundStyle(.tint)
                        .frame(width: 28)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Purchase

    private var purchaseSection: some View {
        VStack(spacing: 12) {
            if let product = storeManager.products.first {
                VStack(spacing: 2) {
                    Text(product.displayPrice)
                        .font(.title2.bold())
                    Text("One-time purchase")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                Task {
                    isPurchasing = true
                    do {
                        try await storeManager.purchase()
                        if storeManager.isPro {
                            withAnimation {
                                isPresented = false
                            }
                        }
                    } catch {
                        errorMessage = error.localizedDescription
                        showError = true
                    }
                    isPurchasing = false
                }
            } label: {
                Group {
                    if isPurchasing {
                        ProgressView()
                    } else {
                        Text("Unlock Pro")
                    }
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isPurchasing || isRestoring)

            Button {
                Task {
                    isRestoring = true
                    await storeManager.restorePurchases()
                    isRestoring = false
                    if storeManager.isPro {
                        withAnimation {
                            isPresented = false
                        }
                    }
                }
            } label: {
                if isRestoring {
                    ProgressView()
                } else {
                    Text("Restore Purchases")
                }
            }
            .font(.subheadline)
            .disabled(isPurchasing || isRestoring)
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.bar)
    }
}

// MARK: - Preview

#Preview {
    PaywallView(isPresented: .constant(true))
}
