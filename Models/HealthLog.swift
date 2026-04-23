import Foundation
import GRDB

// MARK: - Raw input logs (processed and discarded after extraction)

enum LogSource: String, Codable, DatabaseValueConvertible {
    case voice      = "voice"
    case healthKit  = "healthkit"
    case ocr        = "ocr"       // blood test PDF
    case manual     = "manual"
}

enum ProcessingStatus: String, Codable, DatabaseValueConvertible {
    case pending    = "pending"
    case processed  = "processed"
    case failed     = "failed"
}

/// Raw input that the nightly BGProcessingTask will run entity extraction on.
/// transcript/rawText is discarded after extraction — we never persist raw audio.
struct HealthLog: Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var source: LogSource
    var transcript: String?         // voice note text (cleared after extraction)
    var rawText: String?            // OCR / manual input (cleared after extraction)
    var processingStatus: ProcessingStatus
    var extractedAt: Date?
    var createdAt: Date

    // HealthKit snapshot fields (structured data, kept permanently)
    var heartRateBpm: Double?
    var sleepHours: Double?
    var hrvMs: Double?
    var bloodOxygenPct: Double?
    var stepCount: Int?
    var activeCalories: Double?

    static let databaseTableName = "health_logs"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// Wipe raw text after extraction to enforce privacy guarantee.
    mutating func clearRawContent() {
        transcript = nil
        rawText = nil
    }
}

// MARK: - Daily digest (the compressed meaning that survives)

/// 24-hour summary produced by nightly batch. Raw logs discarded after this is written.
struct DailyDigest: Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var date: Date                  // midnight of the day this covers
    var summary: String             // ~200–400 word narrative produced by Cactus SLM
    var keySymptoms: String         // JSON-encoded [String] for quick filtering
    var keyMedications: String      // JSON-encoded [String]
    var avgFatigueScore: Double?    // 1–10 scale from voice logs
    var avgMoodScore: Double?
    var avgSleepHours: Double?
    var avgHeartRateBpm: Double?
    var avgHrvMs: Double?
    var rolledUpToWeek: Bool        // true once included in weekly summary
    var createdAt: Date

    static let databaseTableName = "daily_digests"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    var keySymptomsList: [String] {
        (try? JSONDecoder().decode([String].self, from: Data(keySymptoms.utf8))) ?? []
    }

    var keyMedicationsList: [String] {
        (try? JSONDecoder().decode([String].self, from: Data(keyMedications.utf8))) ?? []
    }
}

// MARK: - Recursive summary hierarchy

enum SummaryPeriod: String, Codable, DatabaseValueConvertible {
    case weekly     = "weekly"
    case monthly    = "monthly"
    case yearly     = "yearly"
}

/// Week / month / year rolled-up summaries. Lower-level entries discarded after roll-up.
struct PeriodSummary: Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var period: SummaryPeriod
    var periodStart: Date
    var periodEnd: Date
    var summary: String
    var dominantSymptoms: String    // JSON-encoded [String]
    var dominantMedications: String // JSON-encoded [String]
    var notableCorrelations: String // JSON-encoded [String] from SQL layer
    var rolledUp: Bool
    var createdAt: Date

    static let databaseTableName = "period_summaries"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
