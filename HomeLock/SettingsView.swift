//
//  SettingsView.swift
//  HomeLock
//
//  Created by Juan C. Ribot on 1/9/26.
//

import SwiftUI

struct SettingsView: View {
    @StateObject private var homeKit = HomeKitService()
    @ObservedObject private var lockManager = LockManager.shared
    @ObservedObject private var notificationManager = NotificationManager.shared
    @ObservedObject private var storeManager = StoreManager.shared

    @AppStorage("appearanceMode") private var appearanceMode: Int = 0 // 0=System, 1=Light, 2=Dark
    @AppStorage("notificationsEnabled") private var notificationsEnabled: Bool = true

    @State private var showingCleanupConfirmation = false
    @State private var isCleaningUp = false
    @State private var cleanupResult: Int?
    @State private var activeTriggerCount = 0
    @State private var isPurchasing = false
    @State private var isRestoring = false
    @State private var showPurchaseError = false
    @State private var purchaseErrorMessage = ""

    private var currentLanguage: String {
        let locale = Locale.current
        return locale.localizedString(forLanguageCode: locale.language.languageCode?.identifier ?? "en") ?? "English"
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    var body: some View {
        NavigationView {
            List {
                // MARK: - Premium Section
                Section {
                    if storeManager.isPro {
                        // Pro user status
                        HStack {
                            Image(systemName: "crown.fill")
                                .foregroundStyle(.yellow)
                                .font(.title2)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("HomeLock Pro")
                                    .font(.headline)
                                Text("All features unlocked")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                                .font(.title2)
                        }
                        .padding(.vertical, 8)
                    } else {
                        // Upgrade prompt
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Image(systemName: "crown.fill")
                                    .foregroundStyle(.yellow)
                                    .font(.title2)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Upgrade to Pro")
                                        .font(.headline)
                                    Text("Unlock all premium features")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            // Features list
                            VStack(alignment: .leading, spacing: 8) {
                                PremiumFeatureRow(icon: "calendar.badge.clock", title: "Unlimited Schedules", description: "Create unlimited auto-lock schedules")
                                PremiumFeatureRow(icon: "clock.arrow.circlepath", title: "Full History", description: "Access complete lock/unlock history")
                                PremiumFeatureRow(icon: "person.2.fill", title: "Multi-User Sync", description: "Sync with all home members")
                                PremiumFeatureRow(icon: "bell.badge.fill", title: "Priority Notifications", description: "Get instant tamper alerts")
                            }
                            .padding(.vertical, 4)

                            // Purchase button
                            Button {
                                Task {
                                    await purchasePro()
                                }
                            } label: {
                                HStack {
                                    if isPurchasing {
                                        ProgressView()
                                            .tint(.white)
                                    } else {
                                        Text(priceText)
                                            .fontWeight(.semibold)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.blue)
                                .foregroundStyle(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .disabled(isPurchasing || storeManager.products.isEmpty)

                            // Restore button
                            Button {
                                Task {
                                    await restorePurchases()
                                }
                            } label: {
                                HStack {
                                    if isRestoring {
                                        ProgressView()
                                            .scaleEffect(0.8)
                                    }
                                    Text("Restore Purchases")
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .disabled(isRestoring)
                            .font(.subheadline)
                        }
                        .padding(.vertical, 8)
                    }
                } header: {
                    Text("Premium")
                } footer: {
                    if !storeManager.isPro {
                        Text("One-time purchase. No subscription required.")
                    }
                }

                // MARK: - Appearance Section
                Section {
                    HStack {
                        Label("Appearance", systemImage: "paintpalette")
                        Spacer()
                        Picker("", selection: $appearanceMode) {
                            Text("System").tag(0)
                            Text("Light").tag(1)
                            Text("Dark").tag(2)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 180)
                    }
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("Choose your preferred color scheme.")
                }

                // MARK: - Language Section
                Section {
                    HStack {
                        Label("Language", systemImage: "globe")
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(currentLanguage)
                                .foregroundStyle(.secondary)
                            Button("Change Language") {
                                openSystemSettings()
                            }
                            .font(.caption)
                        }
                    }
                } header: {
                    Text("Language")
                } footer: {
                    Text("Language settings are managed in iOS Settings.")
                }

                // MARK: - Security Section
                Section {
                    NavigationLink {
                        SecuritySettingsView()
                    } label: {
                        Label("Security Settings", systemImage: "lock.shield")
                    }
                } header: {
                    Text("Security")
                } footer: {
                    Text("Configure PIN and biometric authentication.")
                }

                // MARK: - Notifications Section
                Section {
                    HStack {
                        Label("Lock Expiration Notifications", systemImage: "bell")
                        Spacer()
                        Toggle("", isOn: $notificationsEnabled)
                    }

                    Button {
                        openNotificationSettings()
                    } label: {
                        Label("Open Notification Settings", systemImage: "bell.badge.circle")
                    }
                    .foregroundStyle(.blue)
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("Get notified when device locks expire.")
                }

                // MARK: - HomeKit Section
                Section {
                    HStack {
                        Label("Active HomeLock Triggers", systemImage: "homekit")
                        Spacer()
                        Text("\(activeTriggerCount)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    Button(role: .destructive) {
                        showingCleanupConfirmation = true
                    } label: {
                        if isCleaningUp {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Removing...")
                            }
                        } else {
                            Label("Remove All HomeLock Automations", systemImage: "trash")
                        }
                    }
                    .disabled(isCleaningUp)
                } header: {
                    Text("HomeKit")
                } footer: {
                    Text("Remove all HomeLock triggers and automations from your HomeKit.")
                }

                // MARK: - About Section
                Section {
                    HStack {
                        Label("Version", systemImage: "info.circle")
                        Spacer()
                        Text(appVersion)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    HStack {
                        Label("Made by", systemImage: "heart")
                        Spacer()
                        Text("Jíbaro en la Luna LLC")
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        openSupport()
                    } label: {
                        Label("Support & Feedback", systemImage: "questionmark.circle")
                    }
                    .foregroundStyle(.blue)
                } header: {
                    Text("About")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .task {
                await loadActiveTriggerCount()
            }
            .confirmationDialog(
                "Remove all HomeLock automations?",
                isPresented: $showingCleanupConfirmation,
                titleVisibility: .visible
            ) {
                Button("Remove all", role: .destructive) {
                    Task {
                        await performCleanup()
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This will remove all HomeLock triggers and automations from your HomeKit. Your other automations will not be affected.")
            }
            .alert(
                "Cleanup complete",
                isPresented: Binding(
                    get: { cleanupResult != nil },
                    set: { if !$0 { cleanupResult = nil } }
                )
            ) {
                Button("OK") {
                    cleanupResult = nil
                    Task {
                        await loadActiveTriggerCount()
                    }
                }
            } message: {
                if let count = cleanupResult {
                    Text("Removed \(count) HomeLock automation(s).")
                }
            }
            .alert(
                "Purchase Error",
                isPresented: $showPurchaseError
            ) {
                Button("OK") { }
            } message: {
                Text(purchaseErrorMessage)
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private func loadActiveTriggerCount() async {
        await homeKit.requestAuthorization()
        activeTriggerCount = homeKit.countHomeLockAutomations()
    }

    private func performCleanup() async {
        isCleaningUp = true
        defer { isCleaningUp = false }

        // Clear local locks
        for accessoryID in lockManager.locks.keys {
            await lockManager.removeLock(for: accessoryID)
        }

        // Remove HomeKit automations
        let removed = await homeKit.removeAllHomeLockAutomations()
        cleanupResult = removed
        activeTriggerCount = 0
    }

    private func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    private func openNotificationSettings() {
        if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    private func openSupport() {
        // Open support URL or email
        if let url = URL(string: "mailto:support@jibaroenaluna.com?subject=HomeLock%20Support") {
            UIApplication.shared.open(url)
        }
    }

    // MARK: - Premium Functions

    private var priceText: String {
        if let product = storeManager.products.first {
            return "Upgrade for \(product.displayPrice)"
        }
        return "Upgrade to Pro"
    }

    private func purchasePro() async {
        isPurchasing = true
        defer { isPurchasing = false }

        do {
            try await storeManager.purchase()
        } catch {
            purchaseErrorMessage = error.localizedDescription
            showPurchaseError = true
        }
    }

    private func restorePurchases() async {
        isRestoring = true
        defer { isRestoring = false }

        await storeManager.restorePurchases()
    }
}

// MARK: - Premium Feature Row

struct PremiumFeatureRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.blue)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    SettingsView()
}