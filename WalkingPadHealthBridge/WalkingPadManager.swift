//
//  WalkingPadManager.swift
//  WalkingPadHealthBridge
//
//  Discovers and connects to a SportsTech S / KingSmith / WalkingPad treadmill
//  over Bluetooth Low Energy, auto-detects its protocol family, and publishes
//  parsed step readings.
//

import Foundation
import CoreBluetooth
import Combine

struct StepReading: Identifiable, Equatable {
    let id = UUID()
    let startDate: Date      // start of this sample window
    let date: Date           // end of this sample window
    let totalSteps: Int      // cumulative count reported by the pad
    let deltaSteps: Int      // new steps since the previous reading
    let distanceMeters: Double?
    let speedKmh: Double?
    let source: String
}

struct DebugLogEntry: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let message: String
}

private extension Data {
    var hexString: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

enum PadProtocol: String, CustomStringConvertible {
    case ftms = "FTMS"
    case classic = "Classic WalkingPad"
    case fitShow = "FitShow"
    case kingsmith1234 = "KingSmith 0x1234"
    case unknown = "Unknown"

    var description: String { rawValue }
}

enum ConnectionState: String, CustomStringConvertible {
    case disconnected
    case scanning
    case connecting
    case connected
    case subscribing
    case streaming

    var description: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .scanning: return "Scanning"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case .subscribing: return "Subscribing"
        case .streaming: return "Streaming"
        }
    }

    var color: String {
        switch self {
        case .disconnected: return "red"
        case .scanning, .connecting, .subscribing: return "orange"
        case .connected, .streaming: return "green"
        }
    }
}

final class WalkingPadManager: NSObject, ObservableObject {
    // MARK: - Published state
    @Published var isScanning = false
    @Published var isConnected = false
    @Published var connectionState: ConnectionState = .disconnected
    @Published var detectedProtocol: PadProtocol = .unknown
    @Published var lastReading: StepReading?
    @Published var recentReadings: [StepReading] = []
    @Published var statusText = "Idle"
    @Published var errorMessage: String?
    @Published var deviceName: String?
    @Published var rssi: Int?
    @Published var debugLog: [DebugLogEntry] = []

    /// How often parsed step deltas are emitted (and thus written to Health).
    @Published var sendIntervalSeconds: Double {
        didSet {
            UserDefaults.standard.set(sendIntervalSeconds, forKey: "sendIntervalSeconds")
        }
    }

    /// Stride length used to estimate steps from distance (metres).
    @Published var strideLengthMeters: Double {
        didSet {
            UserDefaults.standard.set(strideLengthMeters, forKey: "strideLengthMeters")
        }
    }

    private let maxRecentReadings = 20
    private let maxDebugLogEntries = 300

    // MARK: - Services / characteristics we care about
    private let ftmsServiceUUID       = CBUUID(string: "1826")
    private let ftmsTreadmillDataUUID   = CBUUID(string: "2ACD")
    private let ftmsControlPointUUID    = CBUUID(string: "2AD9")

    private let classicServiceUUID      = CBUUID(string: "FE00")
    private let classicNotifyUUID       = CBUUID(string: "FE01")
    private let classicWriteUUID        = CBUUID(string: "FE02")

    private let fitShowServiceUUID      = CBUUID(string: "FFF0")
    private let fitShowNotifyUUID       = CBUUID(string: "FFF1")
    private let fitShowWriteUUID        = CBUUID(string: "FFF2")

    private let kingsmithServiceUUID    = CBUUID(string: "1234")
    private let kingsmithNotifyUUID     = CBUUID(string: "FED8")
    private let kingsmithWriteUUID      = CBUUID(string: "FED7")

    private var centralManager: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var discoveredPeripherals: [CBPeripheral] = []

    private var readCharacteristic: CBCharacteristic?
    private var writeCharacteristic: CBCharacteristic?

    private var lastRawTotalSteps: Int
    private var lastReadingDate = Date.distantPast

    // Speed-integrated session totals (speed is the only verified-correct field).
    private var integratedSteps: Double = 0
    private var integratedDistanceMeters: Double = 0
    private var lastPacketDate: Date?

    private let lastRawTotalStepsKey = "lastRawTotalSteps"
    private let sendIntervalKey = "sendIntervalSeconds"

    override init() {
        lastRawTotalSteps = UserDefaults.standard.integer(forKey: lastRawTotalStepsKey)
        let stored = UserDefaults.standard.double(forKey: sendIntervalKey)
        sendIntervalSeconds = stored > 0 ? stored : 5.0
        let storedStride = UserDefaults.standard.double(forKey: "strideLengthMeters")
        strideLengthMeters = storedStride > 0 ? storedStride : 0.7
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: DispatchQueue.global(qos: .userInitiated))
    }

    /// Callback the UI uses to forward emitted readings to HealthKit.
    var onNewReading: ((StepReading) -> Void)?

    // MARK: - Public controls
    func startScan() {
        guard centralManager.state == .poweredOn else {
            errorMessage = "Bluetooth is not powered on."
            log("startScan blocked: Bluetooth not powered on")
            return
        }
        errorMessage = nil
        isScanning = true
        connectionState = .scanning
        statusText = "Scanning…"
        discoveredPeripherals.removeAll()
        // Scan without a service filter so we can see advertised names too.
        centralManager.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        log("Scanning started")
    }

    func stopScan() {
        centralManager.stopScan()
        isScanning = false
        if connectionState == .scanning { connectionState = .disconnected }
        statusText = "Scan stopped"
        log("Scanning stopped")
    }

    func disconnect() {
        guard let peripheral else { return }
        log("Manual disconnect requested for \(peripheral.name ?? peripheral.identifier.uuidString)")
        centralManager.cancelPeripheralConnection(peripheral)
    }

    func clearDebugLog() {
        debugLog.removeAll()
    }

    private func log(_ message: String) {
        DispatchQueue.main.async {
            self.debugLog.insert(DebugLogEntry(timestamp: Date(), message: message), at: 0)
            if self.debugLog.count > self.maxDebugLogEntries {
                self.debugLog.removeLast(self.debugLog.count - self.maxDebugLogEntries)
            }
        }
    }

    // MARK: - Protocol helpers
    private func preferredProtocol(from services: [CBService]) -> PadProtocol {
        let uuids = services.map { $0.uuid.uuidString.uppercased() }
        if uuids.contains(ftmsServiceUUID.uuidString.uppercased()) { return .ftms }
        if uuids.contains(classicServiceUUID.uuidString.uppercased()) { return .classic }
        if uuids.contains(fitShowServiceUUID.uuidString.uppercased()) { return .fitShow }
        if uuids.contains(kingsmithServiceUUID.uuidString.uppercased()) { return .kingsmith1234 }
        return .unknown
    }
}

// MARK: - CBCentralManagerDelegate
extension WalkingPadManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        DispatchQueue.main.async {
            switch central.state {
            case .poweredOn:
                self.statusText = "Bluetooth ready"
                self.log("Bluetooth state: poweredOn")
                self.startScan()
            case .poweredOff:
                self.statusText = "Bluetooth off"
                self.isConnected = false
                self.log("Bluetooth state: poweredOff")
            case .unauthorized:
                self.statusText = "Bluetooth permission denied"
                self.errorMessage = "Enable Bluetooth in Settings → Privacy & Security."
                self.log("Bluetooth state: unauthorized")
            case .unsupported:
                self.statusText = "Bluetooth LE unsupported"
                self.log("Bluetooth state: unsupported")
            default:
                self.statusText = "Bluetooth state: \(central.state.rawValue)"
                self.log("Bluetooth state: \(central.state.rawValue)")
            }
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = (peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "Unknown"
        let advertisedServices = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let serviceList = advertisedServices.map { $0.uuidString }.joined(separator: ",")
        log("didDiscover name=\(name) rssi=\(RSSI) services=[\(serviceList)]")

        // Heuristic: WalkingPad / SportsTech / KingSmith names often contain these tokens.
        let knownTokens = ["WALKINGPAD", "SPORTSTECH", "KINGSMITH", "KS-"]
        let looksLikePad = knownTokens.contains { name.uppercased().contains($0) }

        // Also accept if it advertises one of the known services.
        let advertisesKnownService = advertisedServices.contains { uuid in
            [ftmsServiceUUID, classicServiceUUID, fitShowServiceUUID, kingsmithServiceUUID]
                .contains(uuid)
        }

        guard looksLikePad || advertisesKnownService else { return }
        guard !discoveredPeripherals.contains(where: { $0.identifier == peripheral.identifier }) else { return }

        discoveredPeripherals.append(peripheral)
        DispatchQueue.main.async {
            self.deviceName = name
            self.rssi = RSSI.intValue
            self.connectionState = .connecting
            self.statusText = "Found \(name) (RSSI \(RSSI))"
            self.stopScan()
            self.peripheral = peripheral
            peripheral.delegate = self
            self.centralManager.connect(peripheral, options: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("didConnect \(peripheral.name ?? peripheral.identifier.uuidString)")
        DispatchQueue.main.async {
            self.isConnected = true
            self.connectionState = .connected
            self.deviceName = peripheral.name ?? self.deviceName
            self.statusText = "Connected to \(peripheral.name ?? "pad") — discovering services…"
        }
        peripheral.discoverServices([
            ftmsServiceUUID,
            classicServiceUUID,
            fitShowServiceUUID,
            kingsmithServiceUUID
        ])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("didFailToConnect \(peripheral.name ?? peripheral.identifier.uuidString) error=\(error?.localizedDescription ?? "unknown")")
        DispatchQueue.main.async {
            self.isConnected = false
            self.connectionState = .disconnected
            self.errorMessage = "Failed to connect: \(error?.localizedDescription ?? "unknown")"
            self.statusText = "Connection failed"
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log("didDisconnect \(peripheral.name ?? peripheral.identifier.uuidString) error=\(error?.localizedDescription ?? "none")")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isConnected = false
            self.connectionState = .disconnected
            self.readCharacteristic = nil
            self.writeCharacteristic = nil
            self.detectedProtocol = .unknown
            self.statusText = error != nil ? "Disconnected: \(error!.localizedDescription)" : "Disconnected"
            self.lastPacketDate = nil
            // Auto-reconnect after a short delay if this was an accidental drop.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, !self.isConnected else { return }
                self.startScan()
            }
        }
    }
}

// MARK: - CBPeripheralDelegate
extension WalkingPadManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            DispatchQueue.main.async {
                self.errorMessage = "Service discovery error: \(error.localizedDescription)"
            }
            return
        }
        guard let services = peripheral.services, !services.isEmpty else {
            DispatchQueue.main.async {
                self.errorMessage = "No known walking-pad services found."
            }
            return
        }

        detectedProtocol = preferredProtocol(from: services)
        let serviceUUIDs = services.map { $0.uuid.uuidString }.joined(separator: ",")
        log("didDiscoverServices [\(serviceUUIDs)] protocol=\(detectedProtocol.description)")
        DispatchQueue.main.async {
            self.statusText = "Protocol detected: \(self.detectedProtocol)"
        }

        for service in services {
            var chars: [CBUUID] = []
            switch service.uuid {
            case ftmsServiceUUID:
                chars = [ftmsTreadmillDataUUID, ftmsControlPointUUID]
            case classicServiceUUID:
                chars = [classicNotifyUUID, classicWriteUUID]
            case fitShowServiceUUID:
                chars = [fitShowNotifyUUID, fitShowWriteUUID]
            case kingsmithServiceUUID:
                chars = [kingsmithNotifyUUID, kingsmithWriteUUID]
            default:
                continue
            }
            peripheral.discoverCharacteristics(chars, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            DispatchQueue.main.async {
                self.errorMessage = "Characteristic error: \(error.localizedDescription)"
            }
            return
        }
        guard let characteristics = service.characteristics else { return }

        let characteristicUUIDs = characteristics.map { $0.uuid.uuidString }.joined(separator: ",")
        log("didDiscoverCharacteristics service=\(service.uuid.uuidString) chars=[\(characteristicUUIDs)]")

        for characteristic in characteristics {
            switch service.uuid {
            case classicServiceUUID where characteristic.uuid == classicNotifyUUID,
                 fitShowServiceUUID where characteristic.uuid == fitShowNotifyUUID,
                 kingsmithServiceUUID where characteristic.uuid == kingsmithNotifyUUID,
                 ftmsServiceUUID where characteristic.uuid == ftmsTreadmillDataUUID:
                readCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            case classicServiceUUID where characteristic.uuid == classicWriteUUID,
                 fitShowServiceUUID where characteristic.uuid == fitShowWriteUUID,
                 kingsmithServiceUUID where characteristic.uuid == kingsmithWriteUUID,
                 ftmsServiceUUID where characteristic.uuid == ftmsControlPointUUID:
                writeCharacteristic = characteristic
            default:
                break
            }
        }

        if detectedProtocol == .classic && readCharacteristic != nil && writeCharacteristic != nil {
            // Classic protocol does not push data on its own; poll once a second.
            DispatchQueue.main.async {
                self.connectionState = .streaming
                self.statusText = "Subscribed — polling Classic pad for stats"
            }
            startClassicPolling(for: peripheral)
        } else if readCharacteristic != nil {
            DispatchQueue.main.async {
                self.connectionState = .streaming
                self.statusText = "Subscribed — waiting for notifications"
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            DispatchQueue.main.async {
                self.errorMessage = "Notification error: \(error.localizedDescription)"
            }
            return
        }
        guard let data = characteristic.value else { return }
        log("didUpdateValue char=\(characteristic.uuid.uuidString) bytes=\(data.hexString)")

        // Dispatch by characteristic UUID, not just by detected protocol —
        // dual-protocol pads (FTMS + FitShow) can push on either.
        switch characteristic.uuid {
        case ftmsTreadmillDataUUID:
            parseFTMS(data)
        case classicNotifyUUID:
            parseClassic(data)
        case fitShowNotifyUUID:
            parseFitShow(data)
        case kingsmithNotifyUUID:
            parseFitShow(data) // same text-ish sidecar family; logged for now
        default:
            log("Unhandled characteristic \(characteristic.uuid.uuidString) — no parser")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            DispatchQueue.main.async {
                self.errorMessage = "Notify state error: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Parsers
private extension WalkingPadManager {
    func startClassicPolling(for peripheral: CBPeripheral) {
        guard detectedProtocol == .classic, self.writeCharacteristic != nil else { return }

        func tick() {
            guard self.isConnected,
                  self.detectedProtocol == .classic,
                  let write = self.writeCharacteristic else { return }
            // Ask stats: F7 A2 00 00 A2 FD
            let cmd: [UInt8] = [0xF7, 0xA2, 0x00, 0x00, 0xA2, 0xFD]
            peripheral.writeValue(Data(cmd), for: write, type: .withResponse)
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1.0) { tick() }
        }
        tick()
    }

    func parseClassic(_ data: Data) {
        // Expected: F8 A2 <state> <speed> <mode> <time 3B> <distance 3B> <steps 3B> ... FD
        let bytes = [UInt8](data)
        guard bytes.count >= 14,
              bytes[0] == 0xF8,
              bytes[1] == 0xA2 else {
            log("parseClassic ignored packet bytes=\(data.hexString)")
            return
        }

        let state = bytes[2]
        let speed = Double(bytes[3]) / 10.0
        // let mode = bytes[4]
        // let time = uInt24(bytes[5], bytes[6], bytes[7])
        let distance = Double(uInt24(bytes[8], bytes[9], bytes[10])) * 10.0 // meters
        let totalSteps = uInt24(bytes[11], bytes[12], bytes[13])

        // Belt state > 0 usually means moving. If you prefer to count steps even when
        // stopped, remove the state guard — the pad sometimes keeps counting.
        guard state != 0 else { return }

        log("parseClassic state=\(state) speed=\(String(format: "%.1f", speed)) totalSteps=\(totalSteps)")
        emit(steps: totalSteps, distanceMeters: distance, speedKmh: speed, source: "Classic")
    }

    func parseFTMS(_ data: Data) {
        // FitShow FS-BT-C1 style Treadmill Data on 2ACD.
        // Vendor layout: [0..1] flags, [2..3] speed /100 km/h, [4..6] distance m,
        // then standard fields per flag bits 3..15, then a vendor trailer whose
        // final 2 bytes are the cumulative step count (LE).
        let bytes = [UInt8](data)
        guard bytes.count >= 7 else {
            log("parseFTMS ignored short packet bytes=\(data.hexString)")
            return
        }

        let flags = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)

        // Walk the standard fields (bits 3...15) to find where the trailer starts.
        var offset = 7 // flags(2) + speed(2) + distance(3)
        let fieldSizes: [(UInt16, Int)] = [
            (0x0008, 4), // inclination + ramp angle
            (0x0010, 2), // positive elevation gain
            (0x0020, 2), // negative elevation gain
            (0x0040, 2), // reserved
            (0x0080, 1), // instantaneous pace
            (0x0100, 1), // average pace
            (0x0200, 2), // total energy
            (0x0400, 2), // energy per hour
            (0x0800, 1), // energy per minute
            (0x1000, 1), // heart rate
            (0x2000, 1), // metabolic equivalent
            (0x4000, 2), // elapsed time
            (0x8000, 2), // remaining time
        ]
        for (bit, size) in fieldSizes where flags & bit != 0 {
            offset += size
        }

        let trailerLen = bytes.count - offset
        guard trailerLen >= 2 else {
            // Unexpected packet shape: the final 2 bytes are NOT the step field.
            log("parseFTMS malformed shape: expected ≥\(offset + 2) bytes, got \(bytes.count), flags=0x\(String(flags, radix: 16)) — skipping steps raw=[\(data.hexString)]")
            return
        }

        let rawSpeed = UInt16(bytes[2]) | (UInt16(bytes[3]) << 8)
        let speedKmh = Double(rawSpeed) / 100.0

        let rawDistance = (UInt32(bytes[4]) << 16) | (UInt32(bytes[5]) << 8) | UInt32(bytes[6])
        let distanceMeters = Double(rawDistance)

        let lo = bytes[bytes.count - 2]
        let hi = bytes[bytes.count - 1]
        let trailerValue = Int(UInt16(lo) | (UInt16(hi) << 8))

        // Log every uint16 candidate in the trailer so a real step field can be
        // identified from captured traffic later, if one exists.
        var candidates: [String] = []
        var i = offset
        while i + 2 <= bytes.count {
            let v = UInt16(bytes[i]) | (UInt16(bytes[i + 1]) << 8)
            candidates.append("u16@\(i)=\(v)")
            i += 1
        }
        log("parseFTMS flags=0x\(String(flags, radix: 16)) speed=\(String(format: "%.2f", speedKmh)) km/h distance=\(String(format: "%.0f", distanceMeters)) m trailer=\(trailerValue) (≈session s) candidates=[\(candidates.joined(separator: ", "))]")

        // The raw distance field cannot be trusted (its byte position varies
        // between packet shapes), so derive distance and steps by integrating
        // the verified-correct speed over time.
        let now = Date()
        if let last = lastPacketDate {
            let dt = min(now.timeIntervalSince(last), 5.0)
            let speedMps = speedKmh / 3.6
            integratedDistanceMeters += speedMps * dt
            integratedSteps += speedMps * dt / strideLengthMeters
        }
        lastPacketDate = now

        log("parseFTMS flags=0x\(String(flags, radix: 16)) speed=\(String(format: "%.2f", speedKmh)) km/h rawDistanceField=\(String(format: "%.0f", distanceMeters)) integratedDist=\(String(format: "%.0f", integratedDistanceMeters)) m integratedSteps=\(Int(integratedSteps)) trailer=\(trailerValue)")

        emit(steps: Int(integratedSteps), distanceMeters: integratedDistanceMeters, speedKmh: speedKmh, source: "FTMS")
    }

    /// FitShow family (FFF1 notify). Stub for now: log raw bytes for analysis.
    func parseFitShow(_ data: Data) {
        let bytes = [UInt8](data)
        log("parseFitShow raw(\(bytes.count)) [\(data.hexString)]")
        // FitShow telemetry typically needs a handshake write to FFF2 first.
        // Until we implement that, we only log so the traffic can be analyzed.
    }

    func uInt24(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8) -> Int {
        return (Int(b0) << 16) | (Int(b1) << 8) | Int(b2)
    }

    func emit(steps: Int, distanceMeters: Double?, speedKmh: Double?, source: String) {
        // Pad may reset its counter between sessions; if it went backwards, re-baseline.
        if steps < lastRawTotalSteps {
            lastRawTotalSteps = steps
        }

        let delta = steps - lastRawTotalSteps
        guard delta > 0 else { return }

        let now = Date()
        // Throttle emissions to the configured send interval.
        guard now.timeIntervalSince(lastReadingDate) >= sendIntervalSeconds else { return }

        // Only commit the new baseline when we actually emit a sample.
        lastRawTotalSteps = steps
        UserDefaults.standard.set(steps, forKey: lastRawTotalStepsKey)

        let startDate = lastReadingDate == Date.distantPast ? now : lastReadingDate
        lastReadingDate = now

        let reading = StepReading(
            startDate: startDate,
            date: now,
            totalSteps: steps,
            deltaSteps: delta,
            distanceMeters: distanceMeters,
            speedKmh: speedKmh,
            source: source
        )
        DispatchQueue.main.async {
            self.lastReading = reading
            self.recentReadings.insert(reading, at: 0)
            if self.recentReadings.count > self.maxRecentReadings {
                self.recentReadings.removeLast()
            }
            self.statusText = "\(source): +\(delta) steps (total \(steps)) @ \(String(format: "%.1f", speedKmh ?? 0)) km/h"
            self.onNewReading?(reading)
        }
    }
}

