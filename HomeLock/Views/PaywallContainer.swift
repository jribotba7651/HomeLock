//
//  PaywallContainer.swift
//  HomeLock
//

import SwiftUI

struct PaywallContainer<Content: View>: View {
    @AppStorage("appLaunchCount") private var appLaunchCount: Int = 0
    @ObservedObject private var storeManager = StoreManager.shared

    @State private var showPaywall = false
    @State private var hasChecked = false

    let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        content()
            .fullScreenCover(isPresented: $showPaywall) {
                PaywallView(isPresented: $showPaywall)
            }
            .task {
                guard !hasChecked else { return }
                hasChecked = true
                await checkAndShowPaywall()
            }
    }

    private func checkAndShowPaywall() async {
        // Small delay to let UI settle
        try? await Task.sleep(nanoseconds: 300_000_000) // 0.3 seconds

        // Don't show paywall if user is already Pro
        guard !storeManager.isPro else {
            print("💰 [Paywall] User is Pro, skipping paywall")
            return
        }

        // Increment launch count
        appLaunchCount += 1
        print("💰 [Paywall] Launch count: \(appLaunchCount)")

        // Show paywall on first launch OR every 5 launches
        if appLaunchCount == 1 || appLaunchCount % 5 == 0 {
            print("💰 [Paywall] Showing paywall (launch #\(appLaunchCount))")
            await MainActor.run {
                showPaywall = true
            }
        } else {
            print("💰 [Paywall] Not showing paywall this time")
        }
    }
}
