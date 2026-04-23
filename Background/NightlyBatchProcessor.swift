import Foundation
import BackgroundTasks
import GRDB

/// Nightly BGProcessingTask — runs while phone charges.
/// This is the "thinking while user sleeps" layer that makes DAWQ feel intelligent.
///
/// Pipeline:
///   1. Fetch all pending HealthLogs
///   2. Run Cactus entity extraction → write to SQLite knowledge graph
///   3. Clear raw transcripts from processed logs (privacy guarantee)
///   4. Generate DailyDigest for undigested days
///   5. Roll up old digests: daily → weekly → monthly → yearly (recursive summarization)
///   6. Surface drift-prevention profile confirmation (scheduled notification)
///
/// Register in AppDelegate:
///   BGTaskScheduler.shared.register(forTaskWithIdentifier: NightlyBatchProcessor.taskIdentifier, using: nil) { task in
///       NightlyBatchProcessor.shared.handleBGTask(task as! BGProcessingTask)
///   }

final class NightlyBatchProcessor {
    static let shared = NightlyBatchProcessor()
    static let taskIdentifier = "com.dawq.nightly-batch"

    private let db = DatabaseManager.shared

    // MARK: - BGTask entry point

    func handleBGTask(_ task: BGProcessingTask) {
        // Schedule next run before doing any work
        scheduleNextRun()

        let processingTask = Task {
            do {
                try await runFullPipeline()
                task.setTaskCompleted(success: true)
            } catch {
                task.setTaskCompleted(success: false)
            }
        }

        task.expirationHandler = {
            processingTask.cancel()
        }
    }

    // MARK: - Schedule

    func scheduleNextRun() {
        let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = true       // charging only — battery strategy
        // Fire sometime in the 2am–4am window
        request.earliestBeginDate = Calendar.current.date(
            bySettingHour: 2, minute: 0, second: 0, of: Date()
        )

        try? BGTaskScheduler.shared.submit(request)
    }

    // MARK: - Full pipeline

    func runFullPipeline() async throws {
        try await step1_extractEntities()
        try await step2_generateDailyDigests()
        try await step3_recursiveRollup()
        try await step4_surfaceDriftConfirmation()
    }

    // MARK: - Step 1: Entity extraction

    private func step1_extractEntities() async throws {
        let pendingLogs = try db.allPendingLogs()
        guard !pendingLogs.isEmpty else { return }

        for var log in pendingLogs {
            guard let text = log.transcript ?? log.rawText else {
                // HealthKit-only log — no extraction needed, just mark processed
                log.processingStatus = .processed
                log.extractedAt = Date()
                _ = try db.write { try log.update($0) }
                continue
            }

            do {
                let extracted = try await CactusManager.shared.extractEntities(from: text)

                // Persist entities and relationships to knowledge graph
                try db.write { db in
                    for (name, type) in extracted.entities {
                        let canonical = name.lowercased()
                        // Upsert: avoid duplicates in graph
                        let existing = try HealthEntity
                            .filter(Column("canonicalName") == canonical)
                            .fetchOne(db)

                        if existing == nil {
                            var entity = HealthEntity(
                                name: name,
                                type: type,
                                canonicalName: canonical,
                                createdAt: Date(),
                                updatedAt: Date()
                            )
                            try entity.insert(db)
                        }
                    }

                    for rel in extracted.relationships {
                        let subjectCanon = rel.subject.lowercased()
                        let objectCanon = rel.object.lowercased()

                        if let subject = try HealthEntity.filter(Column("canonicalName") == subjectCanon).fetchOne(db),
                           let object = try HealthEntity.filter(Column("canonicalName") == objectCanon).fetchOne(db),
                           let subjectId = subject.id,
                           let objectId = object.id,
                           let logId = log.id {
                            var relationship = EntityRelationship(
                                subjectEntityId: subjectId,
                                predicate: rel.predicate,
                                objectEntityId: objectId,
                                temporalOffsetSeconds: rel.offsetSeconds,
                                confidence: 0.85,
                                sourceLogId: logId,
                                occurredAt: log.createdAt
                            )
                            try relationship.insert(db)
                        }
                    }
                }

                // Clear raw text — privacy guarantee
                log.clearRawContent()
                log.processingStatus = .processed
                log.extractedAt = Date()
                _ = try db.write { try log.update($0) }

            } catch {
                var failedLog = log
                failedLog.processingStatus = .failed
                _ = try db.write { try failedLog.update($0) }
            }
        }
    }

    // MARK: - Step 2: Generate daily digests for undigested days

    private func step2_generateDailyDigests() async throws {
        // Find days that have processed logs but no digest yet
        let processedLogs = try db.read { db in
            try HealthLog
                .filter(Column("processingStatus") == ProcessingStatus.processed.rawValue)
                .fetchAll(db)
        }

        let dayGroups = Dictionary(grouping: processedLogs) { log -> Date in
            Calendar.current.startOfDay(for: log.createdAt)
        }

        for (day, logs) in dayGroups {
            // Skip if digest already exists
            let existing = try db.read { db in
                try DailyDigest.filter(Column("date") == day).fetchOne(db)
            }
            guard existing == nil else { continue }

            let summary = try await CactusManager.shared.generateDailyDigest(
                logs: logs,
                date: day
            )

            // Aggregate HealthKit metrics
            let avgHR = logs.compactMap { $0.heartRateBpm }.average()
            let avgSleep = logs.compactMap { $0.sleepHours }.average()
            let avgHRV = logs.compactMap { $0.hrvMs }.average()

            var digest = DailyDigest(
                date: day,
                summary: summary,
                keySymptoms: "[]",
                keyMedications: "[]",
                avgFatigueScore: nil,
                avgMoodScore: nil,
                avgSleepHours: avgSleep,
                avgHeartRateBpm: avgHR,
                avgHrvMs: avgHRV,
                rolledUpToWeek: false,
                createdAt: Date()
            )

            _ = try db.write { try digest.insert($0) }
        }
    }

    // MARK: - Step 3: Recursive rollup (day → week → month → year)

    private func step3_recursiveRollup() async throws {
        try await rollupDailyToWeekly()
        try await rollupWeeklyToMonthly()
        try await rollupMonthlyToYearly()
    }

    private func rollupDailyToWeekly() async throws {
        let calendar = Calendar.current
        let weekAgo = calendar.date(byAdding: .weekOfYear, value: -1, to: Date())!

        let oldDigests = try db.read { db in
            try DailyDigest
                .filter(Column("date") < weekAgo)
                .filter(Column("rolledUpToWeek") == false)
                .fetchAll(db)
        }
        guard !oldDigests.isEmpty else { return }

        let weekGroups = Dictionary(grouping: oldDigests) { digest -> Date in
            calendar.dateInterval(of: .weekOfYear, for: digest.date)?.start ?? digest.date
        }

        for (weekStart, digests) in weekGroups {
            let summaries = digests.map { $0.summary }.joined(separator: "\n\n")
            let weekEnd = calendar.date(byAdding: .weekOfYear, value: 1, to: weekStart)!

            // TODO: Run Cactus SLM to produce weekly summary from daily summaries
            let weeklySummary = "Weekly summary for week of \(weekStart): \(summaries.prefix(500))..."

            var period = PeriodSummary(
                period: .weekly,
                periodStart: weekStart,
                periodEnd: weekEnd,
                summary: weeklySummary,
                dominantSymptoms: "[]",
                dominantMedications: "[]",
                notableCorrelations: "[]",
                rolledUp: false,
                createdAt: Date()
            )

            _ = try db.write { db in
                try period.insert(db)
                // Mark daily digests as rolled up
                for var digest in digests {
                    digest.rolledUpToWeek = true
                    try digest.update(db)
                }
            }
        }
    }

    private func rollupWeeklyToMonthly() async throws {
        // Mirror of rollupDailyToWeekly but for weekly → monthly
        // TODO: Implement analogously
    }

    private func rollupMonthlyToYearly() async throws {
        // Mirror for monthly → yearly. Yearly entries persist forever.
        // TODO: Implement analogously
    }

    // MARK: - Step 4: Drift prevention notification

    private func step4_surfaceDriftConfirmation() async throws {
        let profile = try db.userProfile()

        // Only surface if profile hasn't been confirmed in 7 days
        if let lastConfirmed = profile.lastConfirmedAt,
           Date().timeIntervalSince(lastConfirmed) < 7 * 24 * 3600 {
            return
        }

        // Schedule local notification asking user to confirm health profile
        // Full drift-prevention UI is in ProfileView
        // TODO: Wire UNUserNotificationCenter notification here
    }
}

// MARK: - Helpers

private extension Array where Element == Double {
    func average() -> Double? {
        guard !isEmpty else { return nil }
        return reduce(0, +) / Double(count)
    }
}
