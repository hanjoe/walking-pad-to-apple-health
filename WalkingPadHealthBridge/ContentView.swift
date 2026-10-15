//
//  ContentView.swift
//  WalkingPadHealthBridge
//

import SwiftUI

struct ContentView: View {
    @StateObject private var padManager = WalkingPadManager()
    @StateObject private var healthManager = HealthKitManager()
    @StateObject private var sessionStore = SessionStore()
    @State private var showConfig = false
    @State private var showDebugLog = false
    @State private var showHistory = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    connectionCard
                    liveReadingCard
                    sendingCard
                    recentActivityCard
                    debugPreviewCard
                    errorsCard

                    HStack(spacing: 16) {
                        Button(padManager.isScanning ? "Stop Scan" : "Scan / Connect") {
                            if padManager.isScanning {
                                padManager.stopScan()
                            } else {
                                healthManager.requestAuthorization()
                                padManager.startScan()
                            }
                        }
                        .buttonStyle(.borderedProminent)

                        if padManager.isConnected {
                            Button("Disconnect") {
                                padManager.disconnect()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.top, 8)
                }
                .padding()
            }
            .navigationTitle("WalkingPad → Health")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 16) {
                        Button {
                            showHistory.toggle()
                        } label: {
                            Image(systemName: "chart.bar")
                        }

                        Button {
                            showDebugLog.toggle()
                        } label: {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                        }

                        Button {
                            showConfig.toggle()
                        } label: {
                            Image(systemName: "gearshape")
                        }
                    }
                }
            }
            .sheet(isPresented: $showConfig) {
                ConfigSheet(padManager: padManager)
            }
            .sheet(isPresented: $showDebugLog) {
                DebugLogSheet(padManager: padManager)
            }
            .sheet(isPresented: $showHistory) {
                HistorySheet(sessionStore: sessionStore)
            }
            .onAppear {
                healthManager.currentAuthorizationStatus()
                padManager.onNewReading = { reading in
                    healthManager.saveReading(
                        deltaSteps: reading.deltaSteps,
                        startDate: reading.startDate,
                        endDate: reading.date,
                        distanceMeters: reading.distanceMeters,
                        speedKmh: reading.speedKmh,
                        source: reading.source
                    )
                    sessionStore.handle(reading: reading)
                }
            }
        }
    }

    // MARK: - Connection card
    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                statusDot
                Text(padManager.connectionState.description)
                    .font(.headline)
                Spacer()
                if let rssi = padManager.rssi {
                    HStack(spacing: 4) {
                        Image(systemName: rssiImage(rssi))
                        Text("\(rssi) dBm")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
            }

            if let name = padManager.deviceName {
                Label("Device: \(name)", systemImage: "iphone.radiowaves.left.and.right")
                    .font(.subheadline)
            }

            if padManager.detectedProtocol != .unknown {
                Label("Protocol: \(padManager.detectedProtocol.description)", systemImage: "network")
                    .font(.subheadline)
                    .foregroundStyle(.blue)
            }

            Text(padManager.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var statusDot: some View {
        Circle()
            .fill(connectionColor)
            .frame(width: 12, height: 12)
    }

    private var connectionColor: Color {
        switch padManager.connectionState {
        case .disconnected: return .red
        case .scanning, .connecting, .subscribing: return .orange
        case .connected, .streaming: return .green
        }
    }

    private func rssiImage(_ rssi: Int) -> String {
        if rssi > -55 { return "wifi" }
        if rssi > -70 { return "wifi" }
        if rssi > -85 { return "wifi.exclamationmark" }
        return "wifi.slash"
    }

    // MARK: - Live reading card
    private var liveReadingCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Live reading")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let reading = padManager.lastReading {
                HStack(alignment: .lastTextBaseline) {
                    Text("\(reading.totalSteps)")
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                    VStack(alignment: .leading, spacing: 0) {
                        Text("steps")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        Text("session total from pad")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text("+\(reading.deltaSteps)")
                            .font(.title2)
                            .foregroundStyle(.green)
                        Text("in last \(Int(padManager.sendIntervalSeconds))s")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    if let speed = reading.speedKmh, speed > 0 {
                        Label(String(format: "%.1f km/h", speed), systemImage: "speedometer")
                            .font(.subheadline)
                    }
                    Spacer()
                    if let distance = reading.distanceMeters, distance >= 0, distance < 50_000 {
                        Label(String(format: "%.0f m", distance), systemImage: "ruler")
                            .font(.subheadline)
                    }
                }
                .padding(.top, 4)

                Text("Source: \(reading.source) · \(reading.date, style: .time)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No data yet. Start walking and tap Scan / Connect.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Sending card
    private var sendingCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Sending to Health")
                    .font(.headline)
                Spacer()
                Toggle("", isOn: $healthManager.sendingEnabled)
                    .labelsHidden()
            }

            if healthManager.sendingEnabled {
                HStack {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(.red)
                    Text("Sending +\(healthManager.lastSentDelta) steps every \(Int(padManager.sendIntervalSeconds))s")
                        .font(.subheadline)
                }

                HStack(spacing: 16) {
                    StatBox(title: "Total today", value: "\(healthManager.totalSentToday)")
                    StatBox(title: "Sends", value: "\(healthManager.sendCount)")
                    if let last = healthManager.lastSentTime {
                        StatBox(title: "Last send", value: last, style: .time)
                    }
                }
            } else {
                Label("Saving paused — readings still shown", systemImage: "pause.circle")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }

            HStack {
                Text("Health access: \(healthManager.authorizationStatus.description)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if healthManager.authorizationStatus != .sharingAuthorized {
                    Button("Grant") {
                        healthManager.requestAuthorization()
                    }
                    .font(.caption)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Recent activity
    private var recentActivityCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent sends")
                    .font(.headline)
                Spacer()
                Text("last \(padManager.recentReadings.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if padManager.recentReadings.isEmpty {
                Text("No readings yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(padManager.recentReadings) { reading in
                    HStack {
                        Text("+\(reading.deltaSteps)")
                            .font(.system(.body, design: .rounded).monospacedDigit())
                            .foregroundStyle(.green)
                            .frame(width: 50, alignment: .leading)
                        Text("\(reading.totalSteps) total")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let speed = reading.speedKmh {
                            Text(String(format: "%.1f", speed))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Text(reading.date, style: .time)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Debug preview
    private var debugPreviewCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("BLE debug")
                    .font(.headline)
                Spacer()
                Text("\(padManager.debugLog.count) events")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let latest = padManager.debugLog.first {
                HStack(spacing: 4) {
                    Text(latest.timestamp, style: .time)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(latest.message)
                        .font(.caption)
                        .lineLimit(1)
                }
            } else {
                Text("No BLE events yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("View full log") {
                showDebugLog = true
            }
            .font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Errors
    private var errorsCard: some View {
        Group {
            if let error = padManager.errorMessage ?? healthManager.errorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.leading)
                    Spacer()
                    Button("Clear") {
                        padManager.errorMessage = nil
                        healthManager.errorMessage = nil
                    }
                    .font(.caption)
                }
                .padding()
                .background(Color.red.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}

// MARK: - Config sheet
struct ConfigSheet: View {
    @ObservedObject var padManager: WalkingPadManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Health send interval") {
                    HStack {
                        Slider(
                            value: $padManager.sendIntervalSeconds,
                            in: 1...60,
                            step: 1
                        )
                        Text("\(Int(padManager.sendIntervalSeconds))s")
                            .frame(minWidth: 40)
                            .font(.system(.body, design: .rounded).monospacedDigit())
                    }
                    Text("A new step sample is written to Apple Health at most once every \(Int(padManager.sendIntervalSeconds)) seconds while the pad is moving.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Connection") {
                    HStack {
                        Text("State")
                        Spacer()
                        Text(padManager.connectionState.description)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Device")
                        Spacer()
                        Text(padManager.deviceName ?? "—")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Protocol")
                        Spacer()
                        Text(padManager.detectedProtocol.description)
                            .foregroundStyle(.secondary)
                    }
                    if let rssi = padManager.rssi {
                        HStack {
                            Text("RSSI")
                            Spacer()
                            Text("\(rssi) dBm")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Button(padManager.isConnected ? "Disconnect" : "Scan / Connect") {
                        if padManager.isConnected {
                            padManager.disconnect()
                        } else {
                            padManager.startScan()
                        }
                    }
                }
            }
            .navigationTitle("Configuration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Debug log sheet
struct DebugLogSheet: View {
    @ObservedObject var padManager: WalkingPadManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if padManager.debugLog.isEmpty {
                    Section {
                        Text("No BLE events captured yet.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(padManager.debugLog) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.timestamp, style: .time)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(entry.message)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("BLE Debug Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear") {
                        padManager.clearDebugLog()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - History sheet
struct HistorySheet: View {
    @ObservedObject var sessionStore: SessionStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    totalsCard
                    if !sessionStore.sessions.isEmpty || sessionStore.currentSession != nil {
                        chartCard
                    }
                    sessionsList
                }
                .padding()
            }
            .navigationTitle("WalkingPad History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Delete All") {
                        sessionStore.deleteAll()
                    }
                    .foregroundStyle(.red)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var totalsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                StatBox(title: "7 days", value: "\(sessionStore.totalStepsThisWeek)")
                StatBox(title: "30 days", value: "\(sessionStore.totalStepsThisMonth)")
                StatBox(title: "All time", value: "\(sessionStore.totalStepsAllTime)")
            }

            if let current = sessionStore.currentSession {
                HStack {
                    Image(systemName: "figure.walk.motion")
                        .foregroundStyle(.green)
                    Text("Current session: \(current.totalSteps) steps · \(current.formattedDuration)")
                        .font(.subheadline)
                    Spacer()
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Steps per session")
                .font(.headline)

            let sessions = chartSessions
            if sessions.isEmpty {
                Text("No finished sessions yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(sessions) { session in
                        VStack(spacing: 2) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(barColor(for: session))
                                .frame(height: barHeight(for: session, max: maxSteps(in: sessions)))
                            Text(sessionShortDate(session.startDate))
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(-45))
                                .frame(width: 28)
                        }
                    }
                }
                .frame(height: 160)
                .padding(.top, 24)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var sessionsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Sessions")
                    .font(.headline)
                Spacer()
                Text("\(sessionStore.sessions.count) saved")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if sessionStore.sessions.isEmpty {
                Text("No saved sessions yet. Start walking to create one.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sessionStore.sessions) { session in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("\(session.totalSteps) steps")
                                .font(.headline)
                            Spacer()
                            Text(session.formattedDuration)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Text("\(session.startDate, style: .date) · \(session.startDate, style: .time) - \(session.endDate, style: .time)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let speed = session.averageSpeedKmh {
                            Text("Avg speed: \(String(format: "%.1f", speed)) km/h")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            sessionStore.delete(session: session)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // Show up to 20 most recent finished sessions on the chart.
    private var chartSessions: [WalkingSession] {
        Array(sessionStore.sessions.prefix(20).reversed())
    }

    private func maxSteps(in sessions: [WalkingSession]) -> Double {
        Swift.max(1.0, Double(sessions.map(\.totalSteps).max() ?? 1))
    }

    private func barHeight(for session: WalkingSession, max maxValue: Double) -> CGFloat {
        let ratio = Double(session.totalSteps) / maxValue
        return Swift.max(CGFloat(ratio * 130), 4)
    }

    private func barColor(for session: WalkingSession) -> Color {
        let durationMinutes = session.duration / 60
        if durationMinutes < 5 { return .blue }
        if durationMinutes < 15 { return .green }
        return .orange
    }

    private func sessionShortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd/MM"
        return formatter.string(from: date)
    }
}

// MARK: - Helpers
struct StatBox: View {
    enum ValueStyle {
        case string
        case time
    }

    let title: String
    let value: String
    var style: ValueStyle = .string

    init(title: String, value: String, style: ValueStyle = .string) {
        self.title = title
        self.value = value
        self.style = style
    }

    init(title: String, value: Date, style: ValueStyle = .time) {
        self.title = title
        self.value = value.formatted(date: .omitted, time: .shortened)
        self.style = .string
    }

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(.headline, design: .rounded))
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color(.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

#Preview {
    ContentView()
}
