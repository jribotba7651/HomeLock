//
//  AuthenticationView.swift
//  HomeLock
//
//  Created by HomeLock on [Date]
//  Copyright © [Year] HomeLock. All rights reserved.
//

import SwiftUI

struct AuthenticationView<Content: View>: View {
    @ObservedObject var authManager = AuthenticationManager.shared
    @ObservedObject var biometricManager = BiometricAuthManager.shared

    let content: Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            // Main content (shown when authenticated)
            if authManager.isAuthenticated {
                content
                    .transition(.opacity)
            }

            // PIN Setup (first time setup)
            if authManager.showingPINSetup {
                PINSetupView()
                    .transition(.opacity)
                    .zIndex(1)
            }

            // Authentication required (when app is locked)
            if authManager.showingAuthentication {
                PINEntryView(
                    title: "Welcome Back",
                    subtitle: "Enter your PIN to access HomeLock"
                ) {
                    // Authentication successful
                    withAnimation(.easeInOut(duration: 0.3)) {
                        authManager.showingAuthentication = false
                    }
                }
                .transition(.opacity)
                .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: authManager.isAuthenticated)
        .animation(.easeInOut(duration: 0.3), value: authManager.showingPINSetup)
        .animation(.easeInOut(duration: 0.3), value: authManager.showingAuthentication)
    }
}

// MARK: - Preview

struct AuthenticationView_Previews: PreviewProvider {
    static var previews: some View {
        AuthenticationView {
            VStack {
                Text("Protected Content")
                    .font(.title)
                Button("Logout") {
                    AuthenticationManager.shared.logout()
                }
                .padding()
                .background(Color.orange)
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}