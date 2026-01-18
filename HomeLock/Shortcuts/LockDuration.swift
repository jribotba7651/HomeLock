//
//  LockDuration.swift
//  HomeLock
//
//  Created by Claude on 1/18/26.
//

import AppIntents

/// Duración del bloqueo para Shortcuts
enum LockDuration: String, AppEnum {
    case fifteenMinutes = "15min"
    case thirtyMinutes = "30min"
    case oneHour = "1hour"
    case twoHours = "2hours"
    case fourHours = "4hours"
    case eightHours = "8hours"
    case indefinite = "indefinite"

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Lock Duration")
    }

    static var caseDisplayRepresentations: [LockDuration: DisplayRepresentation] {
        [
            .fifteenMinutes: DisplayRepresentation(title: "15 minutes"),
            .thirtyMinutes: DisplayRepresentation(title: "30 minutes"),
            .oneHour: DisplayRepresentation(title: "1 hour"),
            .twoHours: DisplayRepresentation(title: "2 hours"),
            .fourHours: DisplayRepresentation(title: "4 hours"),
            .eightHours: DisplayRepresentation(title: "8 hours"),
            .indefinite: DisplayRepresentation(title: "Indefinite")
        ]
    }

    /// Convierte a TimeInterval (nil para indefinido)
    var timeInterval: TimeInterval? {
        switch self {
        case .fifteenMinutes: return 15 * 60
        case .thirtyMinutes: return 30 * 60
        case .oneHour: return 60 * 60
        case .twoHours: return 2 * 60 * 60
        case .fourHours: return 4 * 60 * 60
        case .eightHours: return 8 * 60 * 60
        case .indefinite: return nil
        }
    }
}
