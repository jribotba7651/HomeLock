//
//  LockSchedule.swift
//  HomeLock
//
//  Created by Claude on 1/18/26.
//

import Foundation
import SwiftData

@Model
final class LockSchedule {
    var id: UUID
    var accessoryUUID: UUID
    var accessoryName: String
    var startTime: Date  // Solo hora/minutos (usar DateComponents)
    var endTime: Date
    var daysOfWeek: [Int]  // 1=Sunday, 2=Monday, ... 7=Saturday
    var isEnabled: Bool
    var createdAt: Date

    init(accessoryUUID: UUID, accessoryName: String, startTime: Date, endTime: Date, daysOfWeek: [Int]) {
        self.id = UUID()
        self.accessoryUUID = accessoryUUID
        self.accessoryName = accessoryName
        self.startTime = startTime
        self.endTime = endTime
        self.daysOfWeek = daysOfWeek
        self.isEnabled = true
        self.createdAt = Date()
    }

    var formattedDays: String {
        let dayNames = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        if daysOfWeek.count == 7 {
            return "Every day"
        } else if daysOfWeek.sorted() == [2, 3, 4, 5, 6] {
            return "Weekdays"
        } else if daysOfWeek.sorted() == [1, 7] {
            return "Weekends"
        }
        return daysOfWeek.sorted().map { dayNames[$0] }.joined(separator: ", ")
    }

    var formattedTimeRange: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return "\(formatter.string(from: startTime)) - \(formatter.string(from: endTime))"
    }
}
