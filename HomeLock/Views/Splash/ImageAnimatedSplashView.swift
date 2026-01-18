//
//  ImageAnimatedSplashView.swift
//  HomeLock
//
//  Created by HomeLock on [Date]
//  Copyright © [Year] HomeLock. All rights reserved.
//

import SwiftUI

struct ImageAnimatedSplashView: View {
    let completion: () -> Void

    var body: some View {
        ZStack {
            // Dynamic background that adapts to color scheme
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                // Simple centered lock image
                Image("lock_closed")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 150, height: 150)
                    .foregroundStyle(.primary)

                // Personal message with heart
                VStack(spacing: 4) {
                    HStack(spacing: 4) {
                        Text("Built with")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Image(systemName: "heart.fill")
                            .font(.caption)
                            .foregroundColor(.pink)

                        Text("love.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Text("Inspired by Luna.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .opacity(0.8)
            }
        }
        .onAppear {
            // Simple 1.5 second delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                completion()
            }
        }
    }
}


// MARK: - Splash Container

struct SplashContainer<Content: View>: View {
    @State private var showingSplash = true
    let content: Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            if showingSplash {
                ImageAnimatedSplashView {
                    withAnimation(.easeInOut(duration: 0.5)) {
                        showingSplash = false
                    }
                }
                .zIndex(1)
                .transition(.opacity)
            }

            if !showingSplash {
                content
                    .transition(.opacity)
            }
        }
    }
}

// MARK: - Preview

struct ImageAnimatedSplashView_Previews: PreviewProvider {
    static var previews: some View {
        ImageAnimatedSplashView {
            print("Splash completed")
        }
    }
}