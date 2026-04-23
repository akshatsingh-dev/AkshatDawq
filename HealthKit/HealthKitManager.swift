import Foundation
import HealthKit

/// Requests HealthKit permissions and pulls structured biometric data into SQLite.
/// Raw HealthKit time series is never stored — only extracted scalar values per day.
@MainActor
final class HealthKitManager: ObservableObject {
    static let shared = HealthKitManager()

    private let store = HKHealthStore()

    @Published var isAuthorized = false
    @Published var lastSyncDate: Date?

    /// Progress 0.0–1.0 during importHistory, nil otherwise
    @Published var importProgress: Double? = nil

    private let readTypes: Set<HKObjectType> = {
        var types = Set<HKObjectType>()
        let quantityTypes: [HKQuantityTypeIdentifier] = [
            .heartRate,
            .heartRateVariabilitySDNN,
            .oxygenSaturation,
            .stepCount,
            .activeEnergyBurned,
            .restingHeartRate,
            .respiratoryRate
        ]
        for id in quantityTypes {
            if let t = HKQuantityType.quantityType(forIdentifier: id) { types.insert(t) }
        }
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            types.insert(sleep)
        }
        return types
    }()

    // MARK: - Auth

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        try await store.requestAuthorization(toShare: [], read: readTypes)
        isAuthorized = true
    }

    // MARK: - Daily sync

    /// Pull yesterday's biometrics and write a HealthLog to SQLite.
    /// Called by BGProcessingTask nightly or manually on app launch.
    func syncYesterday() async throws {
        let yesterday = Calendar.current.startOfDay(
            for: Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        )
        let today = Calendar.current.startOfDay(for: Date())
        let interval = DateInterval(start: yesterday, end: today)

        async let hr = fetchDailyAverage(.heartRate, unit: .count().unitDivided(by: .minute()), interval: interval)
        async let hrv = fetchDailyAverage(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli), interval: interval)
        async let o2 = fetchDailyAverage(.oxygenSaturation, unit: .percent(), interval: interval)
        async let steps = fetchDailySum(.stepCount, unit: .count(), interval: interval)
        async let calories = fetchDailySum(.activeEnergyBurned, unit: .kilocalorie(), interval: interval)
        async let sleep = fetchTotalSleep(interval: interval)

        let (hrVal, hrvVal, o2Val, stepsVal, calVal, sleepVal) = try await (hr, hrv, o2, steps, calories, sleep)

        var log = HealthLog(
            source: .healthKit,
            transcript: nil,
            rawText: nil,
            processingStatus: .processed,   // HealthKit data needs no NLP extraction
            extractedAt: Date(),
            createdAt: Date(),
            heartRateBpm: hrVal,
            sleepHours: sleepVal,
            hrvMs: hrvVal,
            bloodOxygenPct: o2Val,
            stepCount: stepsVal.map(Int.init),
            activeCalories: calVal
        )

        _ = try DatabaseManager.shared.write { db in
            try log.insert(db)
        }

        lastSyncDate = Date()
    }

    // MARK: - Full history import

    /// Imports day-by-day HealthKit data for the last `days` days.
    /// Skips days already in the database. Shows progress via `importProgress`.
    func importHistory(days: Int = 365) async throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        var dayOffsets = (1...days).map { $0 }   // oldest first
        dayOffsets.reverse()

        importProgress = 0.0
        defer { importProgress = nil }

        for (index, offset) in dayOffsets.enumerated() {
            guard let dayStart = calendar.date(byAdding: .day, value: -offset, to: today),
                  let dayEnd   = calendar.date(byAdding: .day, value: 1,       to: dayStart)
            else { continue }

            // Skip if we already have a HealthKit log for this day
            let alreadyImported = (try? DatabaseManager.shared.read { db in
                try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM health_logs
                    WHERE source = 'healthkit'
                      AND createdAt >= ? AND createdAt < ?
                """, arguments: [dayStart, dayEnd])
            } ?? 0) ?? 0

            if alreadyImported > 0 {
                importProgress = Double(index + 1) / Double(days)
                continue
            }

            let interval = DateInterval(start: dayStart, end: dayEnd)

            async let hr       = fetchDailyAverage(.heartRate, unit: .count().unitDivided(by: .minute()), interval: interval)
            async let hrv      = fetchDailyAverage(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli), interval: interval)
            async let o2       = fetchDailyAverage(.oxygenSaturation, unit: .percent(), interval: interval)
            async let steps    = fetchDailySum(.stepCount, unit: .count(), interval: interval)
            async let calories = fetchDailySum(.activeEnergyBurned, unit: .kilocalorie(), interval: interval)
            async let sleep    = fetchTotalSleep(interval: interval)

            let (hrVal, hrvVal, o2Val, stepsVal, calVal, sleepVal) = try await (hr, hrv, o2, steps, calories, sleep)

            // Only store days with at least one non-nil value
            let hasData = [hrVal, hrvVal, o2Val, stepsVal, calVal, sleepVal].contains { $0 != nil }
            if hasData {
                var log = HealthLog(
                    source: .healthKit,
                    transcript: nil,
                    rawText: nil,
                    processingStatus: .processed,
                    extractedAt: Date(),
                    createdAt: dayStart,
                    heartRateBpm: hrVal,
                    sleepHours: sleepVal,
                    hrvMs: hrvVal,
                    bloodOxygenPct: o2Val,
                    stepCount: stepsVal.map(Int.init),
                    activeCalories: calVal
                )
                _ = try? DatabaseManager.shared.write { db in try log.insert(db) }
            }

            importProgress = Double(index + 1) / Double(days)
        }

        lastSyncDate = Date()
    }

    // MARK: - Private fetch helpers

    private func fetchDailyAverage(
        _ identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        interval: DateInterval
    ) async throws -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return nil }

        return try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(
                withStart: interval.start,
                end: interval.end,
                options: .strictStartDate
            )
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .discreteAverage
            ) { _, stats, error in
                if let error { continuation.resume(throwing: error); return }
                let value = stats?.averageQuantity()?.doubleValue(for: unit)
                continuation.resume(returning: value)
            }
            store.execute(query)
        }
    }

    private func fetchDailySum(
        _ identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        interval: DateInterval
    ) async throws -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return nil }

        return try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(
                withStart: interval.start,
                end: interval.end,
                options: .strictStartDate
            )
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, stats, error in
                if let error { continuation.resume(throwing: error); return }
                let value = stats?.sumQuantity()?.doubleValue(for: unit)
                continuation.resume(returning: value)
            }
            store.execute(query)
        }
    }

    private func fetchTotalSleep(interval: DateInterval) async throws -> Double? {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return nil }

        return try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(
                withStart: interval.start,
                end: interval.end,
                options: .strictStartDate
            )
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error { continuation.resume(throwing: error); return }

                guard let categorySamples = samples as? [HKCategorySample] else {
                    continuation.resume(returning: nil)
                    return
                }

                // Sum asleep stages (asleepCore, asleepDeep, asleepREM, asleepUnspecified)
                let asleepValues: Set<Int> = [
                    HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                    HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                    HKCategoryValueSleepAnalysis.asleepREM.rawValue,
                    HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue
                ]

                let totalSeconds = categorySamples
                    .filter { asleepValues.contains($0.value) }
                    .reduce(0.0) { $0 + $1.endDate.timeIntervalSince($1.startDate) }

                continuation.resume(returning: totalSeconds / 3600.0)
            }
            store.execute(query)
        }
    }
}
