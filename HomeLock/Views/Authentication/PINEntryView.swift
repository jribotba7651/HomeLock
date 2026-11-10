//
//  PINEntryView.swift
//  HomeLock
//
//  Created by HomeLock on [Date]
//  Copyright © [Year] HomeLock. All rights reserved.
//

import SwiftUI
import LocalAuthentication

struct PINEntryView: View {
    @ObservedObject var authManager = AuthenticationManager.shared
    @ObservedObject var biometricManager = BiometricAuthManager.shared

    @State private var pin: String = ""
    @State private var showingError: Bool = false
    @State private var errorMessage: String = ""
    @State private var isAuthenticating: Bool = false
    @State private var remainingTime: Int = 0
    @State private var lockoutTimer: Timer?

    enum Mode {
        /// Verifica contra el PIN guardado (app lock, unlock early).
        case authenticate(onSuccess: () -> Void)
        /// Captura 6 dígitos y los entrega crudos — para flujos como cambio
        /// de PIN donde hay que recoger el nuevo PIN sin verificarlo.
        case capture(onCaptured: (String) -> Void)
    }

    let title: String
    let subtitle: String
    let mode: Mode

    init(title: String = "Enter PIN", subtitle: String = "Enter your 6-digit PIN", onSuccess: @escaping () -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.mode = .authenticate(onSuccess: onSuccess)
    }

    init(title: String, subtitle: String, onCaptured: @escaping (String) -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.mode = .capture(onCaptured: onCaptured)
    }

    private var isAuthenticateMode: Bool {
        if case .authenticate = mode { return true }
        return false
    }

    var body: some View {
        PINPadLayout(
            title: title,
            subtitle: subtitle,
            enteredCount: pin.count,
            keypadDisabled: (isAuthenticateMode && authManager.isLockedOut) || isAuthenticating,
            onDigit: addDigit,
            onDelete: deleteDigit
        ) {
            if isAuthenticateMode && authManager.isLockedOut {
                lockoutView
            } else if showingError {
                PINMessageCapsule(text: errorMessage)
            }
        } footer: {
            if isAuthenticateMode
                && biometricManager.isBiometricEnabled
                && biometricManager.isBiometricAvailable
                && !authManager.isLockedOut {
                biometricButton
            }
        }
        .onAppear {
            updateLockoutTimer()
        }
        .onChange(of: authManager.isLockedOut) { oldValue, newValue in
            if !newValue {
                lockoutTimer?.invalidate()
                remainingTime = 0
            } else {
                updateLockoutTimer()
            }
        }
    }

    // MARK: - Biometric Button

    private var biometricButton: some View {
        Button(action: authenticateWithBiometrics) {
            HStack(spacing: 12) {
                Image(systemName: biometricManager.biometricType == .faceID ? "faceid" : "touchid")
                    .font(.title3)

                Text("Use \(biometricManager.biometricTypeString)")
                    .font(.body)
                    .fontWeight(.medium)
            }
            .foregroundColor(.orange)
            .padding(.vertical, 12)
            .padding(.horizontal, 24)
            .background(Color.orange.opacity(0.1))
            .clipShape(Capsule())
        }
        .disabled(isAuthenticating)
    }

    // MARK: - Lockout View

    private var lockoutView: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "lock.circle.fill")
                    .foregroundColor(.red)
                Text("Too many failed attempts")
                    .font(.caption)
                    .foregroundColor(.red)
            }

            Text("Try again in \(formatTime(remainingTime))")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.red.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Actions

    private func addDigit(_ digit: String) {
        guard pin.count < 6 else { return }

        pin.append(digit)

        if pin.count == 6 {
            switch mode {
            case .authenticate:
                authenticateWithPIN()
            case .capture(let onCaptured):
                let captured = pin
                pin = ""
                showingError = false
                onCaptured(captured)
            }
        }
    }

    private func deleteDigit() {
        if !pin.isEmpty {
            pin.removeLast()
        }
        showingError = false
    }

    private func authenticateWithPIN() {
        guard case .authenticate(let onSuccess) = mode else { return }
        isAuthenticating = true
        showingError = false

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let result = authManager.authenticateWithPIN(pin)

            switch result {
            case .success:
                onSuccess()
            case .failure(let error):
                handleAuthenticationError(error)
            }

            pin = ""
            isAuthenticating = false
        }
    }

    private func authenticateWithBiometrics() {
        guard case .authenticate(let onSuccess) = mode else { return }
        isAuthenticating = true
        showingError = false

        Task {
            let result = await authManager.authenticateWithBiometrics()

            await MainActor.run {
                switch result {
                case .success:
                    onSuccess()
                case .failure(let error):
                    handleAuthenticationError(error)
                }

                isAuthenticating = false
            }
        }
    }

    private func handleAuthenticationError(_ error: AuthenticationError) {
        errorMessage = error.localizedDescription
        showingError = true

        if error == .pinLockout {
            updateLockoutTimer()
        }

        // Hide error after 3 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            showingError = false
        }
    }

    // MARK: - Lockout Timer

    private func updateLockoutTimer() {
        lockoutTimer?.invalidate()

        if authManager.isLockedOut {
            remainingTime = Int(authManager.remainingLockoutTime)

            lockoutTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                remainingTime = Int(authManager.remainingLockoutTime)

                if remainingTime <= 0 {
                    lockoutTimer?.invalidate()
                }
            }
        }
    }

    private func formatTime(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let remainingSeconds = seconds % 60
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }
}

// MARK: - Preview

struct PINEntryView_Previews: PreviewProvider {
    static var previews: some View {
        PINEntryView {
            print("Authentication successful")
        }
    }
}