//
//  LockDiagnosticsView.swift
//  HomeLock
//
//  TestFlight / DEBUG only. Picks how timed locks end on the hub and shows
//  what HomeKit actually saved for every HomeLock trigger, so lock behavior
//  can be checked on a real device and home hub.
//

import SwiftUI
import HomeKit
import UIKit

enum AppEnvironment {
    /// True for DEBUG builds and TestFlight installs (sandbox receipt). False on the App Store.
    static var showsDiagnostics: Bool {
        #if DEBUG
        return true
        #else
        return Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
        #endif
    }
}

struct LockDiagnosticsView: View {
    @ObservedObject private var homeKit = HomeKitService.shared
    @AppStorage(HomeKitService.lockEndModeKey) private var modeRaw = HomeKitService.LockEndMode.appOnly.rawValue
    @State private var report = ""
    @State private var copied = false

    var body: some View {
        List {
            Section {
                Picker("Lock end mode", selection: $modeRaw) {
                    ForEach(HomeKitService.LockEndMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("How timed locks end")
            } footer: {
                Text("Applies to locks created after you change it. \"Until I unlock\" locks never get an end condition.")
            }

            Section {
                Text(report.isEmpty ? "No HomeLock triggers." : report)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                Button(copied ? "Copied" : "Copy report") {
                    UIPasteboard.general.string = report
                    copied = true
                }
                Button("Refresh") {
                    Task { await refresh() }
                }
            } header: {
                Text("HomeLock triggers saved in HomeKit")
            }
        }
        .navigationTitle("Lock Diagnostics")
        .task { await refresh() }
    }

    private func refresh() async {
        copied = false
        var lines: [String] = []
        let iso = ISO8601DateFormatter()
        iso.timeZone = .current
        lines.append("HomeLock \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] ?? "?"))")
        lines.append("Now: \(iso.string(from: Date())) \(TimeZone.current.identifier)")
        lines.append("Mode: \(HomeKitService.lockEndMode.rawValue)")
        for home in homeKit.homes {
            let triggers = home.triggers.filter { $0.name.hasPrefix("HomeLock_") }
            lines.append("")
            lines.append("Home \"\(home.name)\": \(triggers.count) HomeLock trigger(s), hub state: \(hubState(home))")
            for trigger in triggers {
                lines.append("• \(trigger.name)")
                lines.append("  enabled: \(trigger.isEnabled)")
                if let eventTrigger = trigger as? HMEventTrigger {
                    lines.append("  predicate: \(eventTrigger.predicate?.predicateFormat ?? "none")")
                    for event in eventTrigger.events {
                        if let charEvent = event as? HMCharacteristicEvent<NSCopying> {
                            let c = charEvent.characteristic
                            let device = c.service?.accessory?.name ?? "?"
                            try? await c.readValue()
                            lines.append("  event: \(device) power -> \(String(describing: charEvent.triggerValue)) (now: \(String(describing: c.value)))")
                        } else {
                            lines.append("  event: \(type(of: event))")
                        }
                    }
                }
                for actionSet in trigger.actionSets {
                    let targets = actionSet.actions.compactMap { ($0 as? HMCharacteristicWriteAction<NSCopying>)?.targetValue }
                    lines.append("  action set: \(actionSet.name) writes \(targets)")
                }
            }
        }
        report = lines.joined(separator: "\n")
    }

    private func hubState(_ home: HMHome) -> String {
        switch home.homeHubState {
        case .connected: return "connected"
        case .disconnected: return "disconnected"
        case .notAvailable: return "not available"
        @unknown default: return "unknown"
        }
    }
}
