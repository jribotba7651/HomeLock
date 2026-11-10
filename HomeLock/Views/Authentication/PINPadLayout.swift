//
//  PINPadLayout.swift
//  HomeLock
//
//  Shared layout for every PIN screen (setup, confirm, unlock, change PIN):
//  header, centered 6-dot indicator, a message slot, exactly one keypad and
//  an optional footer. Content stays inside the safe area, and the keypad
//  shrinks on short screens (iPhone SE) so nothing overflows.
//

import SwiftUI

struct PINPadLayout<Message: View, Footer: View>: View {
    var icon: String? = nil
    let title: String
    let subtitle: String
    let enteredCount: Int
    var pinLength: Int = 6
    var keypadDisabled: Bool = false
    let onDigit: (String) -> Void
    let onDelete: () -> Void
    @ViewBuilder var message: () -> Message
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.height < 700
            let buttonSize: CGFloat = compact ? 66 : 78
            let spacing: CGFloat = compact ? 12 : 18

            VStack(spacing: 0) {
                header(compact: compact)
                    .padding(.top, compact ? 12 : 32)

                Spacer(minLength: compact ? 12 : 24)

                PINDots(count: enteredCount, length: pinLength)

                message()
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .padding(.horizontal, 24)
                    .padding(.top, 12)

                Spacer(minLength: compact ? 8 : 16)

                PINKeypad(buttonSize: buttonSize, spacing: spacing, onDigit: onDigit, onDelete: onDelete)
                    .disabled(keypadDisabled)
                    .opacity(keypadDisabled ? 0.5 : 1)

                footer()
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .padding(.top, compact ? 8 : 16)
                    .padding(.bottom, compact ? 8 : 16)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Color(UIColor.systemBackground).ignoresSafeArea())
    }

    @ViewBuilder
    private func header(compact: Bool) -> some View {
        VStack(spacing: 8) {
            if let icon, !compact {
                Image(systemName: icon)
                    .font(.system(size: 44, weight: .regular))
                    .foregroundStyle(.orange)
                    .padding(.bottom, 4)
            }
            Text(title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)
            Text(subtitle)
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
    }
}

// MARK: - Dots

struct PINDots: View {
    let count: Int
    var length: Int = 6

    var body: some View {
        HStack(spacing: 16) {
            ForEach(0..<length, id: \.self) { index in
                Circle()
                    .fill(index < count ? Color.orange : Color.secondary.opacity(0.3))
                    .frame(width: 14, height: 14)
                    .scaleEffect(index < count ? 1.15 : 1.0)
                    .animation(.easeInOut(duration: 0.15), value: count)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) of \(length) digits entered")
    }
}

// MARK: - Keypad

struct PINKeypad: View {
    var buttonSize: CGFloat = 78
    var spacing: CGFloat = 18
    let onDigit: (String) -> Void
    let onDelete: () -> Void

    private let rows: [[String]] = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"]]

    var body: some View {
        VStack(spacing: spacing) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: spacing * 1.5) {
                    ForEach(row, id: \.self) { digit in
                        NumberPadButton(number: digit, size: buttonSize) { onDigit(digit) }
                    }
                }
            }
            HStack(spacing: spacing * 1.5) {
                Color.clear.frame(width: buttonSize, height: buttonSize)
                NumberPadButton(number: "0", size: buttonSize) { onDigit("0") }
                Button(action: onDelete) {
                    Image(systemName: "delete.left")
                        .font(.title2)
                        .foregroundStyle(.primary)
                        .frame(width: buttonSize, height: buttonSize)
                        .contentShape(Circle())
                }
                .buttonStyle(NumberPadButtonStyle())
                .accessibilityLabel("Delete")
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Number Pad Button

struct NumberPadButton: View {
    let number: String
    var size: CGFloat = 78
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(number)
                .font(.system(size: size * 0.4, weight: .regular))
                .foregroundStyle(.primary)
                .frame(width: size, height: size)
                .background(Color(UIColor.secondarySystemFill))
                .clipShape(Circle())
        }
        .buttonStyle(NumberPadButtonStyle())
    }
}

struct NumberPadButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .opacity(configuration.isPressed ? 0.6 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Message capsule

struct PINMessageCapsule: View {
    let text: String
    var systemImage: String = "exclamationmark.circle.fill"

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.footnote)
            .foregroundStyle(.red)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.red.opacity(0.1), in: Capsule())
    }
}
