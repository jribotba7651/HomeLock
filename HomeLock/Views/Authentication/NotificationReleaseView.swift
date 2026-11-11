//
//  NotificationReleaseView.swift
//  HomeLock
//
//  "Release Lock" from the Lock Expired notification: the system Face ID /
//  passcode on the notification is the authentication. The app has to come to
//  the foreground for HomeKit, but instead of the HomeLock PIN screen it shows
//  this status screen while the device is released. The app stays locked: the
//  main content is never shown without the PIN, and "Open HomeLock" goes to it.
//

import SwiftUI
import UIKit
import Combine

/// What the app's root shows. Pure so it can be unit tested.
enum AppGate: Equatable {
    case content
    case pinSetup
    case pin
    case notificationRelease

    nonisolated static func decide(isPINSetup: Bool, isAuthenticated: Bool,
                                   notificationReleaseActive: Bool) -> AppGate {
        if isAuthenticated { return .content }
        if !isPINSetup { return .pinSetup }
        // A notification release replaces the PIN screen; content stays hidden.
        return notificationReleaseActive ? .notificationRelease : .pin
    }
}

@MainActor
final class NotificationReleaseCoordinator: ObservableObject {
    static let shared = NotificationReleaseCoordinator()

    enum Phase: Equatable {
        case releasing(String)
        case released(String)
        case failed(String, String)
    }

    /// Non-nil while a notification release is being shown instead of the PIN.
    @Published private(set) var phase: Phase?

    private var cancellables = Set<AnyCancellable>()

    private init() {
        // Next time the app is opened normally, the PIN gate is back.
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in self?.phase = nil }
            .store(in: &cancellables)
    }

    func begin(_ name: String) { phase = .releasing(name) }
    func finish(_ name: String) { phase = .released(name) }
    func fail(_ name: String, message: String) { phase = .failed(name, message) }
    /// "Open HomeLock": leave the status screen; the PIN gate takes over.
    func dismiss() { phase = nil }
}

struct NotificationReleaseView: View {
    let phase: NotificationReleaseCoordinator.Phase
    let onOpenApp: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            icon
                .font(.system(size: 56))
            Text(title)
                .font(.title2)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(String(localized: "Open HomeLock"), action: onOpenApp)
                .buttonStyle(.bordered)
                .padding(.bottom, 32)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }

    @ViewBuilder private var icon: some View {
        switch phase {
        case .releasing:
            ProgressView().controlSize(.large)
        case .released:
            Image(systemName: "lock.open.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    private var title: String {
        switch phase {
        case .releasing(let name): return String(localized: "Releasing \(name)…")
        case .released(let name): return String(localized: "\(name) released")
        case .failed(let name, _): return String(localized: "Couldn't release \(name)")
        }
    }

    private var subtitle: String {
        switch phase {
        case .releasing: return String(localized: "This takes a few seconds.")
        case .released: return String(localized: "You can close HomeLock.")
        case .failed(_, let message): return message
        }
    }
}
