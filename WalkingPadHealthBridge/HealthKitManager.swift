//
//  HealthKitManager.swift
//  WalkingPadHealthBridge
//
//  Authorizes Apple Health and writes step-count samples, avoiding duplicates
//  by querying the store first.
//

import Foundation
import HealthKit
import Combine

final class HealthKitManager: ObservableObject {
    private let healthStore = HKHealthStore()

    @Published var authorizationStatus: HKAuthorizationStatus = .notDetermined
    @Published var errorMessage: String?

    /// When false, readings are still shown but not written to Apple Health.
    @Published var sendingEnabled: Bool {
        didSet { UserDefaults.standard.set(sendingEnabled, forKey: "sendingEnabled") }
    }

    @Published var lastSentDelta: Int = 0
    @Published var totalSentToday: Int = 0
    @Published var sendCount: Int = 0
    @Published var lastSentTime: Date?

    private var cancellables = Set<AnyCancellable>()
    private let sendingEnabledKey = "sendingEnabled"
    private var currentDay: Date = Calendar.current.startOfDay(for: Date())

    init() {
        sendingEnabled = UserDefaults.standard.object(forKey: "sendingEnabled") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "sendingEnabled")
    }

    /// Requests the permissions needed to write step counts.
    func requestAuthorization() {
        guard HKHealthStore.isHealthDataAvailable() else {
            errorMessage = "HealthKit is not available on this device."
            return
        }

        let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount)!
        healthStore.requestAuthorization(toShare: [stepType], read: []) { [weak self] success, error in
            DispatchQueue.main.async {
                if let error {
                    self?.errorMessage = "Health authorization error: \(error.localizedDescription)"
                } else if !success {
                    self?.errorMessage = "Health authorization was declined."
                } else {
                    self?.authorizationStatus = self?.healthStore.authorizationStatus(for: stepType) ?? .sharingAuthorized
                }
            }
        }
    }

    func currentAuthorizationStatus() {
        let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount)!
        authorizationStatus = healthStore.authorizationStatus(for: stepType)
    }

    /// Deletes every step-count sample this app has written to Apple Health.
    /// Use to clean up after bad data (e.g. a misparsed counter).
    func deleteAllStepSamplesFromThisApp() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount)!
        let predicate = HKQuery.predicateForObjects(from: HKSource.default())
        let query = HKSampleQuery(
            sampleType: stepType,
            predicate: predicate,
            limit: HKObjectQueryNoLimit,
            sortDescriptors: nil
        ) { [weak self] _, samples, error in
            if let error {
                DispatchQueue.main.async {
                    self?.errorMessage = "HealthKit query error: \(error.localizedDescription)"
                }
                return
            }
            guard let objects = samples, !objects.isEmpty else {
                DispatchQueue.main.async {
                    self?.errorMessage = "No samples from this app found in Health."
                }
                return
            }
            self?.healthStore.delete(objects) { success, deleteError in
                DispatchQueue.main.async {
                    if success {
                        self?.totalSentToday = 0
                        self?.sendCount = 0
                        self?.lastSentDelta = 0
                        self?.lastSentTime = nil
                        self?.errorMessage = "Deleted \(objects.count) samples from Apple Health."
                    } else if let deleteError {
                        self?.errorMessage = "HealthKit delete error: \(deleteError.localizedDescription)"
                    }
                }
            }
        }
        healthStore.execute(query)
    }

    /// Public entrypoint called by the UI when a new reading should be saved.
    func saveReading(deltaSteps: Int,
                     startDate: Date,
                     endDate: Date,
                     distanceMeters: Double?,
                     speedKmh: Double?,
                     source: String) {
        guard HKHealthStore.isHealthDataAvailable() else {
            errorMessage = "HealthKit is not available on this device."
            return
        }
        guard sendingEnabled else { return }

        // Roll over the daily total at midnight.
        let today = Calendar.current.startOfDay(for: Date())
        if today != currentDay {
            currentDay = today
            totalSentToday = 0
        }

        let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount)!
        let quantity = HKQuantity(unit: .count(), doubleValue: Double(deltaSteps))

        let predicate = HKQuery.predicateForSamples(
            withStart: startDate,
            end: endDate,
            options: .strictStartDate
        )

        let query = HKSampleQuery(
            sampleType: stepType,
            predicate: predicate,
            limit: 1,
            sortDescriptors: nil
        ) { [weak self] _, samples, error in
            if let error {
                DispatchQueue.main.async {
                    self?.errorMessage = "HealthKit query error: \(error.localizedDescription)"
                }
                return
            }
            guard samples?.isEmpty ?? true else {
                // Already have a sample in this window; skip.
                return
            }

            let sample = HKQuantitySample(
                type: stepType,
                quantity: quantity,
                start: startDate,
                end: endDate,
                metadata: [
                    HKMetadataKeyWasUserEntered: false,
                    "source_device": source,
                    "distance_meters": distanceMeters ?? 0,
                    "speed_kmh": speedKmh ?? 0
                ]
            )

            self?.healthStore.save(sample) { success, error in
                DispatchQueue.main.async {
                    if success {
                        self?.lastSentDelta = deltaSteps
                        self?.totalSentToday += deltaSteps
                        self?.sendCount += 1
                        self?.lastSentTime = Date()
                    } else if let error {
                        self?.errorMessage = "HealthKit save error: \(error.localizedDescription)"
                    }
                }
            }
        }
        healthStore.execute(query)
    }
}

extension HKAuthorizationStatus: @retroactive CustomStringConvertible {
    public var description: String {
        switch self {
        case .notDetermined: return "Not determined"
        case .sharingDenied: return "Denied"
        case .sharingAuthorized: return "Authorized"
        @unknown default: return "Unknown"
        }
    }
}
