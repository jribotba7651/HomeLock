//
//  SecuritySettingsView.swift
//  HomeLock
//
//  Created by HomeLock on [Date]
//  Copyright © [Year] HomeLock. All rights reserved.
//

import SwiftUI
import LocalAuthentication

struct SecuritySettingsView: View {
    @ObservedObject var authManager = AuthenticationManager.shared
    @ObservedObject var biometricManager = BiometricAuthManager.shared

    @State private var showingChangePIN = false
    @State private var showingResetAlert = false
    @State private var showingBiometricSetup = false
    @State private var isEnablingBiometric = false

    @Environment(\.presentationMode) var presentationMode

    var body: some View {
        NavigationView {
            List {
                // PIN Section
                Section {
                    HStack {
                        Image(systemName: "key.fill")
                            .foregroundColor(.orange)
                            .frame(width: 24)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Change PIN")
                                .font(.body)
                            Text("Update your 6-digit PIN")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Button("Change") {
                            showingChangePIN = true
                        }
                        .foregroundColor(.orange)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("PIN Security")
                } footer: {
                    Text("Your PIN secures access to HomeLock and all connected devices.")
                }

                // Biometric Section
                if biometricManager.isBiometricAvailable {
                    Section {
                        HStack {
                            Image(systemName: biometricManager.biometricType == .faceID ? "faceid" : "touchid")
                                .foregroundColor(.orange)
                                .frame(width: 24)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Enable \(biometricManager.biometricTypeString)")
                                    .font(.body)
                                Text("Quick access with biometrics")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            Toggle("", isOn: biometricBinding)
                                .disabled(isEnablingBiometric)
                        }
                        .padding(.vertical, 4)
                    } header: {
                        Text(biometricManager.biometricTypeString)
                    } footer: {
                        Text(biometricFooterText)
                    }
                }

                // Security Info Section
                Section {
                    SecurityInfoRow(
                        icon: "shield.checkered",
                        title: "Auto-Lock",
                        subtitle: "App locks when moved to background",
                        value: "Enabled"
                    )

                    SecurityInfoRow(
                        icon: "exclamationmark.shield",
                        title: "Failed Attempts",
                        subtitle: "Maximum before lockout",
                        value: "5 attempts"
                    )

                    SecurityInfoRow(
                        icon: "clock.badge.exclamationmark",
                        title: "Lockout Duration",
                        subtitle: "Time locked after max attempts",
                        value: "5 minutes"
                    )
                } header: {
                    Text("Security Information")
                }

                // Reset Section
                Section {
                    Button(action: {
                        showingResetAlert = true
                    }) {
                        HStack {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                                .frame(width: 24)

                            Text("Reset Security")
                                .foregroundColor(.red)
                        }
                    }
                } footer: {
                    Text("This will remove all security settings and require setting up a new PIN.")
                }
            }
            .navigationTitle("Security")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        presentationMode.wrappedValue.dismiss()
                    }
                    .foregroundColor(.orange)
                }
            }
        }
        .sheet(isPresented: $showingChangePIN) {
            ChangePINView()
        }
        .alert("Reset Security?", isPresented: $showingResetAlert) {
            Button("Reset", role: .destructive) {
                authManager.resetSecurity()
                presentationMode.wrappedValue.dismiss()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will remove your PIN and disable biometric authentication. You'll need to set up security again.")
        }
    }

    // MARK: - Computed Properties

    private var biometricBinding: Binding<Bool> {
        Binding(
            get: { biometricManager.isBiometricEnabled },
            set: { newValue in
                if newValue {
                    enableBiometric()
                } else {
                    biometricManager.setBiometricEnabled(false)
                }
            }
        )
    }

    private var biometricFooterText: String {
        if biometricManager.isBiometricEnabled {
            return "You can use \(biometricManager.biometricTypeString) to quickly unlock HomeLock."
        } else {
            return "Enable \(biometricManager.biometricTypeString) for quick and secure access."
        }
    }

    // MARK: - Actions

    private func enableBiometric() {
        isEnablingBiometric = true

        Task {
            let result = await biometricManager.requestBiometricSetup()

            await MainActor.run {
                isEnablingBiometric = false

                switch result {
                case .success:
                    // Biometric is now enabled
                    break
                case .failure(let error):
                    // Handle error - show alert or message
                    print("Biometric setup failed: \(error.localizedDescription)")
                }
            }
        }
    }
}

// MARK: - Security Info Row

struct SecurityInfoRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let value: String

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(.orange)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Text(value)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Change PIN View

struct ChangePINView: View {
    @ObservedObject var authManager = AuthenticationManager.shared

    @State private var currentStep: ChangeStep = .current
    @State private var newPIN: String = ""
    @State private var banner: Banner?

    @Environment(\.presentationMode) var presentationMode

    enum ChangeStep {
        case current
        case new
        case confirm
    }

    private struct Banner: Identifiable {
        let id = UUID()
        let message: String
        let isError: Bool
    }

    var body: some View {
        NavigationView {
            VStack {
                HStack(spacing: 8) {
                    ForEach(0..<3) { index in
                        Circle()
                            .fill(index <= currentStep.rawValue ? Color.orange : Color.gray.opacity(0.3))
                            .frame(width: 8, height: 8)
                    }
                }
                .padding(.top, 20)

                if let banner {
                    HStack(spacing: 8) {
                        Image(systemName: banner.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        Text(banner.message)
                            .font(.caption)
                            .multilineTextAlignment(.leading)
                    }
                    .foregroundColor(banner.isError ? .red : .green)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background((banner.isError ? Color.red : Color.green).opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }

                Spacer()

                // Step 1 verifica contra el PIN actual vía AuthenticationManager
                // (authenticate mode, reusa lockout existente). Steps 2 y 3
                // sólo capturan dígitos (capture mode) — sin lockout ni biometry.
                pinView(for: currentStep)
                    .id(currentStep) // fuerza reset del @State interno al cambiar step

                Spacer()
            }
            .navigationTitle("Change PIN")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }

                if currentStep != .current {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Back") {
                            goBack()
                        }
                        .foregroundColor(.orange)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func pinView(for step: ChangeStep) -> some View {
        switch step {
        case .current:
            PINEntryView(title: "Current PIN", subtitle: "Enter your current PIN") {
                // authManager.authenticateWithPIN ya corrió dentro — si
                // llegamos aquí es porque fue correcto. Avanzamos a .new.
                banner = nil
                currentStep = .new
            }
        case .new:
            PINEntryView(title: "New PIN", subtitle: "Enter your new 6-digit PIN") { captured in
                newPIN = captured
                banner = nil
                currentStep = .confirm
            }
        case .confirm:
            PINEntryView(title: "Confirm New PIN", subtitle: "Re-enter your new PIN") { captured in
                commitPINChange(confirmation: captured)
            }
        }
    }

    private func commitPINChange(confirmation: String) {
        let result = authManager.changePIN(newPin: newPIN, confirmation: confirmation)
        switch result {
        case .success:
            banner = Banner(message: "PIN updated", isError: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                presentationMode.wrappedValue.dismiss()
            }
        case .failure(let error):
            banner = Banner(message: error.localizedDescription, isError: true)
            // Vuelve al step .new para que el usuario re-ingrese sin arrastrar
            // el confirm fallido.
            newPIN = ""
            currentStep = .new
        }
    }

    private func goBack() {
        switch currentStep {
        case .new:
            currentStep = .current
        case .confirm:
            currentStep = .new
        case .current:
            break
        }
        banner = nil
    }
}

extension ChangePINView.ChangeStep: CaseIterable {
    var rawValue: Int {
        switch self {
        case .current: return 0
        case .new: return 1
        case .confirm: return 2
        }
    }
}

// MARK: - Preview

struct SecuritySettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SecuritySettingsView()
    }
}