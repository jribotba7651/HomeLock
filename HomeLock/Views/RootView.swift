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
            // Wait for StoreManager and View Hierarchy to stabilize
            // This is crucial for fullScreenCover to trigger correctly on app start
            try? await Task.sleep(nanoseconds: 1_200_000_000) // 1.2 seconds (increased from 0.8)
            
            guard !hasCheckedPaywall else { return }
            hasCheckedPaywall = true

            // Increment launch count only once
            appLaunchCount += 1
            
            print("💰 [Paywall] Checking... Launch Count: \(appLaunchCount), isPro: \(storeManager.isPro)")
            
            // Logic: 1st launch OR every 5 launches if NOT pro
            if !storeManager.isPro && (appLaunchCount == 1 || appLaunchCount % 5 == 0) {
                print("💰 [Paywall] Logic triggered: TRUE")
                withAnimation {
                    showPaywall = true
                }
            } else {
                print("💰 [Paywall] Logic triggered: FALSE")
            }
        }
    }
}
