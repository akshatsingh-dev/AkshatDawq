import Foundation
import GRDB

/// Singleton SQLite database via GRDB. All health data stays on device.
/// Never used for network transport — data exits only as Abstracted Medical Briefs.
final class DatabaseManager: @unchecked Sendable {
    static let shared = DatabaseManager()

    let dbQueue: DatabaseQueue

    private init() {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DAWQ", isDirectory: true)

        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)

        let dbURL = appSupport.appendingPathComponent("dawq.sqlite")

        var config = Configuration()
        config.prepareDatabase { db in
            // Enable WAL for safe concurrent reads during background processing
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            // Enforce foreign key constraints
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        dbQueue = try! DatabaseQueue(path: dbURL.path, configuration: config)
        try! runMigrations()
    }

    func write<T>(_ updates: (Database) throws -> T) throws -> T {
        try dbQueue.write(updates)
    }

    func read<T>(_ value: (Database) throws -> T) throws -> T {
        try dbQueue.read(value)
    }

    // MARK: - Convenience query helpers

    func allPendingLogs() throws -> [HealthLog] {
        try dbQueue.read { db in
            try HealthLog
                .filter(Column("processingStatus") == ProcessingStatus.pending.rawValue)
                .order(Column("createdAt").asc)
                .fetchAll(db)
        }
    }

    func recentDailyDigests(days: Int = 30) throws -> [DailyDigest] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        return try dbQueue.read { db in
            try DailyDigest
                .filter(Column("date") >= cutoff)
                .order(Column("date").desc)
                .fetchAll(db)
        }
    }

    func userProfile() throws -> UserHealthProfile {
        try dbQueue.read { db in
            try UserHealthProfile.fetchOne(db) ?? UserHealthProfile.empty()
        }
    }

    // MARK: - SQL correlation queries (Layer 2 — deterministic math, no hallucination)

    /// Average fatigue score on days when a given entity was present vs. absent.
    /// Example: antihistamine present vs. absent on high-pollen days.
    func correlate(entity: String, metric: String) throws -> CorrelationResult {
        try dbQueue.read { db in
            let withEntity = try Double.fetchOne(db, sql: """
                SELECT AVG(d.\(metric))
                FROM daily_digests d
                WHERE d.keySymptoms LIKE ? OR d.keyMedications LIKE ?
            """, arguments: ["%\(entity)%", "%\(entity)%"]) ?? 0.0

            let withoutEntity = try Double.fetchOne(db, sql: """
                SELECT AVG(d.\(metric))
                FROM daily_digests d
                WHERE d.keySymptoms NOT LIKE ? AND d.keyMedications NOT LIKE ?
            """, arguments: ["%\(entity)%", "%\(entity)%"]) ?? 0.0

            let pct = withoutEntity > 0
                ? ((withEntity - withoutEntity) / withoutEntity) * 100
                : 0.0

            return CorrelationResult(
                entity: entity,
                metric: metric,
                withEntityAvg: withEntity,
                withoutEntityAvg: withoutEntity,
                percentDifference: pct
            )
        }
    }

    /// Symptom frequency count over a time window.
    func symptomFrequency(symptom: String, days: Int = 90) throws -> Int {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        return try dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM daily_digests
                WHERE date >= ? AND keySymptoms LIKE ?
            """, arguments: [cutoff, "%\(symptom)%"]) ?? 0
        }
    }

    /// Drug interaction lookup: returns true if local cheat sheet flags interaction.
    /// App code catches this before the model responds — no hallucinated pharmacology.
    func checkInteraction(drug1: String, drug2: String) throws -> Bool {
        try dbQueue.read { db in
            let count = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM drug_interactions
                WHERE (drugA LIKE ? AND drugB LIKE ?)
                   OR (drugA LIKE ? AND drugB LIKE ?)
            """, arguments: [
                "%\(drug1)%", "%\(drug2)%",
                "%\(drug2)%", "%\(drug1)%"
            ]) ?? 0
            return count > 0
        }
    }
}

// MARK: - Result type for SQL correlation

struct CorrelationResult {
    let entity: String
    let metric: String
    let withEntityAvg: Double
    let withoutEntityAvg: Double
    let percentDifference: Double   // positive = higher when entity present

    var narrative: String {
        let direction = percentDifference > 0 ? "higher" : "lower"
        let abs = abs(percentDifference)
        return String(format: "%@ is %.0f%% %@ on days when %@ is logged.",
                      metric, abs, direction, entity)
    }
}
