//
//  SessionStore.swift
//  WalkingPadHealthBridge
//
//  Detects walking sessions from live readings and persists them locally.
//

import Foundation

final class SessionStore: ObservableObject {
    @Published var sessions: [WalkingSession] = []
    @Published var currentSession: WalkingSession?

    /// If no new steps arrive for this long, the current session is closed.
    var idleTimeoutSeconds: Double = 60.0

    private var idleTimer: Timer?
    private let saveFileName = "walkingSessions.json"

    init() {
        load()
    }

    var totalStepsThisWeek: Int {
        let start = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date.distantPast
        return sessions.filter { $0.endDate >= start }
            .reduce(0) { $0 + $1.totalSteps }
    }

    var totalStepsThisMonth: Int {
        guard let start = Calendar.current.date(byAdding: .month, value: -1, to: Date()) else { return 0 }
        return sessions.filter { $0.endDate >= start }
            .reduce(0) { $0 + $1.totalSteps }
    }

    var totalStepsAllTime: Int {
        sessions.reduce(0) { $0 + $1.totalSteps }
    }

    func deleteAll() {
        sessions.removeAll()
        currentSession = nil
        save()
    }

    func delete(session: WalkingSession) {
        sessions.removeAll { $0.id == session.id }
        save()
    }

    /// Call this from the UI whenever a new StepReading is emitted.
    func handle(reading: StepReading) {
        idleTimer?.invalidate()

        if var session = currentSession {
            // Continue existing session
            session.endDate = reading.date
            session.totalSteps += reading.deltaSteps
            if let d = reading.distanceMeters {
                session.totalDistanceMeters = (session.totalDistanceMeters ?? 0) + d
            }
            if let s = reading.speedKmh, s > 0 {
                // Very rough running average
                let count = max(1, Int(reading.totalSteps / max(1, reading.deltaSteps)))
                let old = session.averageSpeedKmh ?? s
                session.averageSpeedKmh = (old * Double(count - 1) + s) / Double(count)
            }
            currentSession = session
        } else {
            // Start a new session
            currentSession = WalkingSession(
                id: UUID(),
                startDate: reading.startDate,
                endDate: reading.date,
                totalSteps: reading.deltaSteps,
                totalDistanceMeters: reading.distanceMeters,
                averageSpeedKmh: reading.speedKmh,
                source: reading.source
            )
        }

        // Close the session if the user stops walking for idleTimeoutSeconds.
        idleTimer = Timer.scheduledTimer(withTimeInterval: idleTimeoutSeconds, repeats: false) { [weak self] _ in
            self?.closeCurrentSession()
        }
    }

    private func closeCurrentSession() {
        guard var session = currentSession else { return }
        session.endDate = Date()
        sessions.insert(session, at: 0)
        currentSession = nil
        save()
    }

    func endSessionNow() {
        closeCurrentSession()
    }

    private var saveURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(saveFileName)
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(sessions)
            try data.write(to: saveURL)
        } catch {
            print("Failed to save sessions: \(error)")
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: saveURL.path) else { return }
        do {
            let data = try Data(contentsOf: saveURL)
            sessions = try JSONDecoder().decode([WalkingSession].self, from: data)
        } catch {
            print("Failed to load sessions: \(error)")
        }
    }
}
