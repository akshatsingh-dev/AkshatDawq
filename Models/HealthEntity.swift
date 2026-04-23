import Foundation
import GRDB

// MARK: - Entity types extracted by the Cactus SLM

enum EntityType: String, Codable, DatabaseValueConvertible {
    case symptom        = "symptom"
    case medication     = "medication"
    case condition      = "condition"
    case food           = "food"
    case activity       = "activity"
    case measurement    = "measurement"
    case emotion        = "emotion"
    case unknown        = "unknown"
}

/// A named medical/health entity extracted from a voice note or HealthKit event.
/// These are the nodes in the Local Clinical Knowledge Graph.
struct HealthEntity: Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var name: String               // e.g. "Lisinopril", "dry cough", "chest pressure"
    var type: EntityType
    var canonicalName: String?     // normalized form for dedup (e.g. "lisinopril")
    var createdAt: Date
    var updatedAt: Date

    static let databaseTableName = "health_entities"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Relationship between two entities (knowledge graph edges)

enum RelationshipType: String, Codable, DatabaseValueConvertible {
    case started        = "STARTED"
    case stopped        = "STOPPED"
    case experienced    = "EXPERIENCED"
    case correlatedWith = "CORRELATED_WITH"
    case preceded       = "PRECEDED"
    case followed       = "FOLLOWED"
    case contraindicated = "CONTRAINDICATED"
    case unknown        = "UNKNOWN"
}

/// A directed edge in the knowledge graph: subject → predicate → object.
/// e.g. user STARTED Lisinopril, Dry Cough FOLLOWED Lisinopril (~4hrs)
struct EntityRelationship: Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var subjectEntityId: Int64
    var predicate: RelationshipType
    var objectEntityId: Int64
    var temporalOffsetSeconds: Int?   // how long after subject event did object occur
    var confidence: Double            // 0.0–1.0 from SLM extraction
    var sourceLogId: Int64            // which voice/health log this came from
    var occurredAt: Date

    static let databaseTableName = "entity_relationships"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
