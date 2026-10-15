//
//  WalkingSession.swift
//  WalkingPadHealthBridge
//
//  Local walking-pad session model stored separately from Apple Health.
//

import Foundation

struct WalkingSession: Identifiable, Codable, Equatable {
    let id: UUID
    var startDate: Date
    var endDate: Date
    var totalSteps: Int
    var totalDistanceMeters: Double?
    var averageSpeedKmh: Double?
    var source: String

    var duration: TimeInterval {
        endDate.timeIntervalSince(startDate)
    }

    var formattedDuration: String {
        let total = Int(duration)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
