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

    let title: String
    let subtitle: String
    let onSuccess: () -> Void

    init(title: String = "Enter PIN", subtitle: String = "Enter your 6-digit PIN", onSuccess: @escaping () -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.onSuccess = onSuccess
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                Spacer()

                // Title and Subtitle
                VStack(spacing: 8) {
                    Text(title)
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)

                    Text(subtitle)
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 32)

                Spacer().frame(height: 40)

                // PIN Dots Display
                HStack(spacing: 16) {
                    ForEach(0..<6, id: \.self) { index in
                        Circle()
                            .fill(index < pin.count ? Color.orange : Color.gray.opacity(0.3))
                            .frame(width: 16, height: 16)
                            .scaleEffect(index < pin.count ? 1.2 : 1.0)
                            .animation(.easeInOut(duration: 0.2), value: pin.count)
                    }
                }
                .padding(.bottom, 40)

                // Error Message or Lockout Timer
                VStack {
                    if authManager.isLockedOut {
                        lockoutView
                    } else if showingError {
                        errorView
                    } else {
                        Text("")
                            .font(.caption)
                            .frame(height: 20)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 20)

                Spacer()

                // Number Pad
                numberPad
                    .disabled(authManager.isLockedOut || isAuthenticating)
                    .opacity(authManager.isLockedOut ? 0.5 : 1.0)

                Spacer()

                // Biometric Authentication Button
                if biometricManager.isBiometricEnabled && biometricManager.isBiometricAvailable && !authManager.isLockedOut {
                    biometricButton
                        .padding(.horizontal, 32)
                        .padding(.bottom, 32)
                }
            }
        }
        .background(Color(UIColor.systemBackground))
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

    // MARK: - Number Pad

    private var numberPad: some View {
        VStack(spacing: 16) {
            // Rows 1-3
            ForEach(0..<3) { row in
                HStack(spacing: 16) {
                    ForEach(1..<4) { col in
                        let number = row * 3 + col
                        NumberPadButton(number: "\(number)") {
                            addDigit("\(number)")
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }

            // Bottom row
            HStack(spacing: 16) {
                // Empty space
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 80, height: 80)

                // Zero
                NumberPadButton(number: "0") {
                    addDigit("0")
                }

                // Delete button
                Button(action: deleteDigit) {
                    Image(systemName: "delete.left")
                        .font(.title2)
                        .foregroundColor(.orange)
                        .frame(width: 80, height: 80)
                        .background(Color.gray.opacity(0.1))
                        .clipShape(Circle())
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 32)
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

    // MARK: - Error View

    private var errorView: some View {
        HStack {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundColor(.red)
            Text(errorMessage)
                .font(.caption)
                .foregroundColor(.red)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.1))
        .clipShape(Capsule())
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
            authenticateWithPIN()
        }
    }

    private func deleteDigit() {
        if !pin.isEmpty {
            pin.removeLast()
        }
        showingError = false
    }

    private func authenticateWithPIN() {
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

// MARK: - Number Pad Button

struct NumberPadButton: View {
    let number: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(number)
                .font(.title)
                .fontWeight(.medium)
                .foregroundColor(.primary)
                .frame(width: 80, height: 80)
                .background(Color.gray.opacity(0.1))
                .clipShape(Circle())
        }
        .buttonStyle(NumberPadButtonStyle())
    }
}

struct NumberPadButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
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