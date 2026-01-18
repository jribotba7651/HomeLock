//
//  LockEvent.swift
//  HomeLock
//
//  Created by Claude on 1/18/26.
//

import Foundation
import SwiftData
import SwiftUI

@Model
final class LockEvent {
    var id: UUID
    var accessoryUUID: UUID
    var accessoryName: String
    var eventType: String  // "locked", "unlocked", "expired", "tamper"
    var timestamp: Date
    var duration: TimeInterval?  // Solo para "locked"
    var notes: String?

    init(accessoryUUID: UUID, accessoryName: String, eventType: String, duration: TimeInterval? = nil, notes: String? = nil) {
        self.id = UUID()
        self.accessoryUUID = accessoryUUID
        self.accessoryName = accessoryName
        self.eventType = eventType
        self.timestamp = Date()
        self.duration = duration
        self.notes = notes
    }
}

enum LockEventType: String, CaseIterable {
    case locked = "locked"
    case unlocked = "unlocked"
    case expired = "expired"
    case tamper = "tamper"  // Cuando alguien intenta encender un dispositivo bloqueado

    var icon: String {
        switch self {
        case .locked: return "lock.fill"
        case .unlocked: return "lock.open.fill"
        case .expired: return "clock.badge.checkmark"
        case .tamper: return "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .locked: return .blue
        case .unlocked: return .green
        case .expired: return .orange
        case .tamper: return .red
        }
    }
}
