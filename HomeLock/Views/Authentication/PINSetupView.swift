//
//  PINSetupView.swift
//  HomeLock
//
//  Created by HomeLock on [Date]
//  Copyright © [Year] HomeLock. All rights reserved.
//

import SwiftUI

struct PINSetupView: View {
    @ObservedObject var authManager = AuthenticationManager.shared

    @State private var currentStep: SetupStep = .initial
    @State private var firstPIN: String = ""
    @State private var confirmPIN: String = ""
    @State private var showingError: Bool = false
    @State private var errorMessage: String = ""

    enum SetupStep {
        case initial
        case confirm
    }

    var body: some View {
        NavigationView {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    // Progress indicator
                    progressIndicator
                        .padding(.top, 20)

                    Spacer()

                    // Header
                    VStack(spacing: 16) {
                        Image(systemName: "lock.shield")
                            .font(.system(size: 60))
                            .foregroundColor(.orange)

                        Text(headerTitle)
                            .font(.title)
                            .fontWeight(.bold)
                            .foregroundColor(.primary)
                            .multilineTextAlignment(.center)

                        Text(headerSubtitle)
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }

                    Spacer().frame(height: 40)

                    // PIN Dots Display
                    HStack(spacing: 16) {
                        ForEach(0..<6, id: \.self) { index in
                            Circle()
                                .fill(index < currentPIN.count ? Color.orange : Color.gray.opacity(0.3))
                                .frame(width: 16, height: 16)
                                .scaleEffect(index < currentPIN.count ? 1.2 : 1.0)
                                .animation(.easeInOut(duration: 0.2), value: currentPIN.count)
                        }
                    }
                    .padding(.bottom, 40)

                    // Error Message
                    VStack {
                        if showingError {
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
                        .padding(.horizontal, 32)

                    Spacer()

                    // Back button (only on confirm step)
                    if currentStep == .confirm {
                        Button("Back") {
                            goBack()
                        }
                        .font(.body)
                        .foregroundColor(.orange)
                        .padding(.bottom, 32)
                    }
                }
            }
            .background(Color(UIColor.systemBackground))
            .navigationBarHidden(true)
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    // MARK: - Computed Properties

    private var currentPIN: String {
        currentStep == .initial ? firstPIN : confirmPIN
    }

    private var headerTitle: String {
        switch currentStep {
        case .initial:
            return "Set Your PIN"
        case .confirm:
            return "Confirm Your PIN"
        }
    }

    private var headerSubtitle: String {
        switch currentStep {
        case .initial:
            return "Create a 6-digit PIN to secure your HomeLock app"
        case .confirm:
            return "Enter your PIN again to confirm"
        }
    }

    // MARK: - Progress Indicator

    private var progressIndicator: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.orange)
                .frame(width: 8, height: 8)

            Circle()
                .fill(currentStep == .confirm ? Color.orange : Color.gray.opacity(0.3))
                .frame(width: 8, height: 8)
                .animation(.easeInOut(duration: 0.3), value: currentStep)
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
        }
    }

    // MARK: - Actions

    private func addDigit(_ digit: String) {
        switch currentStep {
        case .initial:
            guard firstPIN.count < 6 else { return }
            firstPIN.append(digit)

            if firstPIN.count == 6 {
                proceedToConfirm()
            }

        case .confirm:
            guard confirmPIN.count < 6 else { return }
            confirmPIN.append(digit)

            if confirmPIN.count == 6 {
                validateAndSetupPIN()
            }
        }

        showingError = false
    }

    private func deleteDigit() {
        switch currentStep {
        case .initial:
            if !firstPIN.isEmpty {
                firstPIN.removeLast()
            }
        case .confirm:
            if !confirmPIN.isEmpty {
                confirmPIN.removeLast()
            }
        }
        showingError = false
    }

    private func proceedToConfirm() {
        // Validate first PIN
        guard isValidPIN(firstPIN) else {
            showError("PIN must be 6 digits")
            return
        }

        // Proceed to confirmation step
        withAnimation(.easeInOut(duration: 0.3)) {
            currentStep = .confirm
        }
    }

    private func validateAndSetupPIN() {
        // Validate confirmation PIN
        guard isValidPIN(confirmPIN) else {
            showError("PIN must be 6 digits")
            return
        }

        // Setup PIN through AuthenticationManager
        let result = authManager.setupPIN(firstPIN, confirmation: confirmPIN)

        switch result {
        case .success:
            // Success is handled by AuthenticationManager
            break
        case .failure(let error):
            if error == .invalidPin && firstPIN != confirmPIN {
                showError("PINs don't match. Please try again.")
                goBack()
            } else {
                showError(error.localizedDescription)
            }
        }
    }

    private func goBack() {
        confirmPIN = ""
        withAnimation(.easeInOut(duration: 0.3)) {
            currentStep = .initial
        }
    }

    private func showError(_ message: String) {
        errorMessage = message
        showingError = true

        // Clear current PIN input
        if currentStep == .initial {
            firstPIN = ""
        } else {
            confirmPIN = ""
        }

        // Hide error after 3 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            showingError = false
        }
    }

    private func isValidPIN(_ pin: String) -> Bool {
        return pin.count == 6 && pin.allSatisfy { $0.isNumber }
    }
}

// MARK: - Preview

struct PINSetupView_Previews: PreviewProvider {
    static var previews: some View {
        PINSetupView()
    }
}