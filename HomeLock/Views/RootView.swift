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
    @State private var isReady = false

    var body: some View {
        ZStack {
            // Main content
            SplashContainer {
                AuthenticationView {
                    ContentView()
                }
            }
            .preferredColorScheme(
                appearanceMode == 0 ? nil :
                appearanceMode == 1 ? .light : .dark
            )

            // Paywall overlay - show on top of everything
            if showPaywall {
                PaywallView(isPresented: $showPaywall)
                    .zIndex(999)
            }
        }
        .onAppear {
            guard !isReady else { return }
            isReady = true

            // Increment launch count
            appLaunchCount += 1
            print("💰 [Paywall] ==================")
            print("💰 [Paywall] Launch count: \(appLaunchCount)")
            print("💰 [Paywall] isPro: \(storeManager.isPro)")

            // Check if should show
            if !storeManager.isPro && (appLaunchCount == 1 || appLaunchCount % 5 == 0) {
                print("💰 [Paywall] SHOWING PAYWALL!")
                showPaywall = true
            } else {
                print("💰 [Paywall] Not showing this time")
            }
        }
    }
}
