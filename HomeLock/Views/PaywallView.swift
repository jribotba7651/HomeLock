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
            // Background with subtle gradient
            LinearGradient(
                colors: [Color(hex: "0F172A"), Color(hex: "1E293B")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            // Decorative background blobs
            Circle()
                .fill(Color.blue.opacity(0.15))
                .frame(width: 400, height: 400)
                .blur(radius: 100)
                .offset(x: -150, y: -200)

            Circle()
                .fill(Color.purple.opacity(0.15))
                .frame(width: 400, height: 400)
                .blur(radius: 100)
                .offset(x: 150, y: 200)

            VStack(spacing: 20) {
                // Close button
                HStack {
                    Spacer()
                    Button {
                        withAnimation {
                            isPresented = false
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white.opacity(0.6))
                            .frame(width: 36, height: 36)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                            .overlay(
                                Circle().stroke(.white.opacity(0.1), lineWidth: 1)
                            )
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 10)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 32) {
                        // Header
                        VStack(spacing: 16) {
                            ZStack {
                                Circle()
                                    .fill(
                                        LinearGradient(
                                            colors: [.yellow, .orange],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .frame(width: 100, height: 100)
                                    .blur(radius: 20)
                                    .opacity(0.3)

                                Image(systemName: "crown.fill")
                                    .font(.system(size: 64))
                                    .foregroundStyle(
                                        LinearGradient(
                                            colors: [.yellow, Color(hex: "FDBA74")],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .shadow(color: .yellow.opacity(0.5), radius: 10)
                            }
                            .padding(.top, 20)

                            VStack(spacing: 8) {
                                Text("Upgrade to Pro")
                                    .font(.system(size: 34, weight: .bold, design: .rounded))
                                    .foregroundColor(.white)

                                Text("Unlock the full potential of HomeLock")
                                    .font(.system(size: 17))
                                    .foregroundColor(.white.opacity(0.6))
                                    .multilineTextAlignment(.center)
                            }
                        }

                        // Features list
                        VStack(alignment: .leading, spacing: 24) {
                            FeatureRow(
                                icon: "calendar.badge.plus",
                                iconColor: .blue,
                                title: "Unlimited Schedules",
                                description: "Automate your home without limits"
                            )

                            FeatureRow(
                                icon: "clock.arrow.circlepath",
                                iconColor: .orange,
                                title: "Full History",
                                description: "Track every lock and unlock event"
                            )

                            FeatureRow(
                                icon: "person.3.fill",
                                iconColor: .cyan,
                                title: "Multi-User Sync",
                                description: "Keep your whole family protected"
                            )

                            FeatureRow(
                                icon: "bell.badge.fill",
                                iconColor: .purple,
                                title: "Priority Notifications",
                                description: "Instant alerts when security matters"
                            )
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 30)
                        .background(
                            RoundedRectangle(cornerRadius: 24)
                                .fill(.white.opacity(0.05))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 24)
                                        .stroke(.white.opacity(0.1), lineWidth: 1)
                                )
                        )
                        .padding(.horizontal, 20)
                    }
                }

                // Purchase Section
                VStack(spacing: 20) {
                    if let product = storeManager.products.first {
                        VStack(spacing: 4) {
                            Text(product.displayPrice)
                                .font(.system(size: 28, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                            
                            Text("One-time lifetime access")
                                .font(.system(size: 14))
                                .foregroundColor(.white.opacity(0.5))
                        }
                    }

                    VStack(spacing: 12) {
                        // Upgrade button
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
                            HStack {
                                if isPurchasing {
                                    ProgressView()
                                        .tint(.white)
                                } else {
                                    Text("Get Pro Now")
                                        .font(.system(size: 18, weight: .bold))
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 60)
                            .background(
                                LinearGradient(
                                    colors: [Color.blue, Color(hex: "3B82F6")],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .foregroundColor(.white)
                            .cornerRadius(18)
                            .shadow(color: .blue.opacity(0.3), radius: 10, y: 5)
                        }
                        .disabled(isPurchasing)

                        // Secondary actions
                        HStack(spacing: 30) {
                            Button {
                                Task {
                                    await storeManager.restorePurchases()
                                    if storeManager.isPro {
                                        withAnimation {
                                            isPresented = false
                                        }
                                    }
                                }
                            } label: {
                                Text("Restore")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.white.opacity(0.6))
                            }

                            Button {
                                withAnimation {
                                    isPresented = false
                                }
                            } label: {
                                Text("Not Now")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.white.opacity(0.4))
                            }
                        }
                        .padding(.top, 8)
                    }
                    .padding(.horizontal, 24)
                }
                .padding(.bottom, 20)
                .background(
                    Rectangle()
                        .fill(.clear)
                        .background(.ultraThinMaterial.opacity(0.5))
                        .ignoresSafeArea()
                )
            }
        }
        .alert("Purchase Error", isPresented: $showError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage)
        }
    }
}

// Helper for Hex colors
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
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
