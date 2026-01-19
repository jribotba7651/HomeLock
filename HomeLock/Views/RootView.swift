//
//  RootView.swift
//  HomeLock
//

import SwiftUI

struct RootView: View {
    @AppStorage("appearanceMode") var appearanceMode: Int = 0
    @AppStorage("appLaunchCount") var appLaunchCount: Int = 0

    @ObservedObject private var storeManager = StoreManager.shared
    @State private var showPaywall = false
    @State private var hasCheckedPaywall = false

    var body: some View {
        SplashContainer {
            AuthenticationView {
                ContentView()
            }
        }
        .preferredColorScheme(
            appearanceMode == 0 ? nil :
            appearanceMode == 1 ? .light : .dark
        )
        .fullScreenCover(isPresented: $showPaywall) {
            PaywallView(isPresented: $showPaywall)
        }
        .task {
            guard !hasCheckedPaywall else { return }
            hasCheckedPaywall = true

            // Increment launch count
            appLaunchCount += 1
            print("💰 [Paywall] Launch count: \(appLaunchCount)")

            // Small delay to let splash show first
            try? await Task.sleep(nanoseconds: 1_500_000_000)

            // Don't show if Pro
            guard !storeManager.isPro else {
                print("💰 [Paywall] User is Pro, skipping")
                return
            }

            // Show on first launch or every 5 launches
            if appLaunchCount == 1 || appLaunchCount % 5 == 0 {
                print("💰 [Paywall] Showing paywall now!")
                showPaywall = true
            }
        }
    }
}
