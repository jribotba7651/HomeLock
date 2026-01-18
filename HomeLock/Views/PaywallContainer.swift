//
//  PaywallContainer.swift
//  HomeLock
//

import SwiftUI

struct PaywallContainer<Content: View>: View {
    @AppStorage("appLaunchCount") private var appLaunchCount: Int = 0
    @AppStorage("hasSeenPaywall") private var hasSeenPaywall: Bool = false
    @ObservedObject private var storeManager = StoreManager.shared

    @State private var showPaywall = false

    let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        content()
            .fullScreenCover(isPresented: $showPaywall) {
                PaywallView(isPresented: $showPaywall)
            }
            .onAppear {
                checkAndShowPaywall()
            }
    }

    private func checkAndShowPaywall() {
        // Don't show paywall if user is already Pro
        guard !storeManager.isPro else { return }

        // Increment launch count
        appLaunchCount += 1

        // Show paywall on first launch
        if !hasSeenPaywall {
            hasSeenPaywall = true
            // Small delay to let the app load
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                showPaywall = true
            }
            return
        }

        // Show paywall every 5 launches for free users
        if appLaunchCount % 5 == 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                showPaywall = true
            }
        }
    }
}
