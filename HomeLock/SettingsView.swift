//
//  SettingsView.swift
//  HomeLock
//
//  Created by Juan C. Ribot on 1/9/26.
//

import SwiftUI
import StoreKit

struct SettingsView: View {
    @ObservedObject private var homeKit = HomeKitService.shared
    @ObservedObject private var lockManager = LockManager.shared
    @ObservedObject private var notificationManager = NotificationManager.shared
    @ObservedObject private var storeManager = StoreManager.shared

    @AppStorage("appearanceMode") private var appearanceMode: Int = 0 // 0=System, 1=Light, 2=Dark
    @Environment(\.scenePhase) private var scenePhase

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
                                PremiumFeatureRow(icon: "lock.fill", title: "Unlimited Locks", description: "Lock any number of devices at once")
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

                // MARK: - Family Section (hidden in v1)
                if FeatureFlags.familySharingEnabled {
                    Section {
                        NavigationLink {
                            FamilySettingsView()
                        } label: {
                            Label("Family Sharing", systemImage: "person.2.fill")
                        }
                    } header: {
                        Text("Family")
                    } footer: {
                        Text("Sync devices with family members via iCloud.")
                    }
                }

                // MARK: - Notifications Section
                Section {
                    // The in-app toggle did nothing; show the real iOS setting.
                    HStack {
                        Label("Lock Expiration Notifications", systemImage: "bell")
                        Spacer()
                        Text(notificationManager.isAuthorized ? String(localized: "On") : String(localized: "Off"))
                            .foregroundStyle(.secondary)
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
                    Text("Get notified when device locks expire, with a Release Lock button. Turn notifications on or off in iOS Settings.")
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

                    // Compatibilidad Lutron — ver nota en HomeKitService.shouldIgnoreLutron
                    // Bound to HomeKitService (single source of truth); writes
                    // persist and recompute outlets.
                    Toggle(isOn: $homeKit.ignoreLutronDevices) {
                        Label("Ignore Lutron devices", systemImage: "exclamationmark.triangle")
                    }
                } header: {
                    Text("HomeKit")
                } footer: {
                    Text("Remove all HomeLock triggers and automations from your HomeKit. Lutron devices are ignored by default because their HomeKit bridge is unreliable — disable this only if you've confirmed your bridge stays connected.")
                }

                // MARK: - Lock Diagnostics (DEBUG only)
                if AppEnvironment.showsDiagnostics {
                    Section {
                        NavigationLink {
                            LockDiagnosticsView()
                        } label: {
                            Label("Lock Diagnostics", systemImage: "stethoscope")
                        }
                    } header: {
                        Text("Debug")
                    } footer: {
                        Text("Not shown in App Store builds.")
                    }
                }

#if DEBUG
                // MARK: - Developer Section (DEBUG only)
                // Estos controles NO se compilan en builds de Release. Si no los
                // ves al archivar la app → está bien, no van a salir al App Store.
                Section {
                    Toggle(isOn: Binding(
                        get: { storeManager.isPro },
                        set: { storeManager.debug_setProOverride($0) }
                    )) {
                        Label("Force Pro", systemImage: "hammer.fill")
                    }
                } header: {
                    Text("Developer")
                } footer: {
                    Text("DEBUG builds only. Overrides the StoreKit entitlement so you can test Pro features without purchasing. Resets on app restart.")
                }
#endif

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
                await notificationManager.checkAuthorizationStatus()
            }
            .onChange(of: scenePhase) { _, phase in
                // Back from iOS Settings: show the current notification setting.
                if phase == .active {
                    Task { await notificationManager.checkAuthorizationStatus() }
                }
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
        homeKit.requestAuthorization()
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
        if let url = URL(string: "mailto:info@jibaroenlaluna.com?subject=HomeLock%20Support") {
            UIApplication.shared.open(url)
        }
    }

    // MARK: - Premium Functions

    private var priceText: String {
        if let product = storeManager.products.first {
            return "Upgrade to \(product.displayName)"
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