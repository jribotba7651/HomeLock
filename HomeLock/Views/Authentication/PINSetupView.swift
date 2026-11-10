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
        PINPadLayout(
            icon: "lock.shield",
            title: headerTitle,
            subtitle: headerSubtitle,
            enteredCount: currentPIN.count,
            onDigit: addDigit,
            onDelete: deleteDigit
        ) {
            if showingError {
                PINMessageCapsule(text: errorMessage)
            } else {
                progressIndicator
            }
        } footer: {
            if currentStep == .confirm {
                Button("Back", action: goBack)
                    .foregroundStyle(.orange)
            }
        }
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