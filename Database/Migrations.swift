import Foundation
import GRDB

extension DatabaseManager {

    func runMigrations() throws {
        var migrator = DatabaseMigrator()

        // v1 — core schema
        migrator.registerMigration("v1_core_schema") { db in
            // Health logs (raw input — transcript cleared after extraction)
            try db.create(table: "health_logs") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("source", .text).notNull()
                t.column("transcript", .text)
                t.column("rawText", .text)
                t.column("processingStatus", .text).notNull().defaults(to: "pending")
                t.column("extractedAt", .datetime)
                t.column("createdAt", .datetime).notNull()
                // HealthKit structured fields (kept permanently)
                t.column("heartRateBpm", .double)
                t.column("sleepHours", .double)
                t.column("hrvMs", .double)
                t.column("bloodOxygenPct", .double)
                t.column("stepCount", .integer)
                t.column("activeCalories", .double)
            }

            // Knowledge graph nodes
            try db.create(table: "health_entities") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("type", .text).notNull()
                t.column("canonicalName", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(
                indexOn: "health_entities",
                columns: ["canonicalName"]
            )

            // Knowledge graph edges
            try db.create(table: "entity_relationships") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("subjectEntityId", .integer).notNull()
                    .references("health_entities", onDelete: .cascade)
                t.column("predicate", .text).notNull()
                t.column("objectEntityId", .integer).notNull()
                    .references("health_entities", onDelete: .cascade)
                t.column("temporalOffsetSeconds", .integer)
                t.column("confidence", .double).notNull().defaults(to: 1.0)
                t.column("sourceLogId", .integer).notNull()
                t.column("occurredAt", .datetime).notNull()
            }
            try db.create(
                indexOn: "entity_relationships",
                columns: ["subjectEntityId", "predicate", "objectEntityId"]
            )
            try db.create(
                indexOn: "entity_relationships",
                columns: ["occurredAt"]
            )

            // Recursive summary hierarchy
            try db.create(table: "daily_digests") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("date", .datetime).notNull().unique()
                t.column("summary", .text).notNull()
                t.column("keySymptoms", .text).notNull().defaults(to: "[]")
                t.column("keyMedications", .text).notNull().defaults(to: "[]")
                t.column("avgFatigueScore", .double)
                t.column("avgMoodScore", .double)
                t.column("avgSleepHours", .double)
                t.column("avgHeartRateBpm", .double)
                t.column("avgHrvMs", .double)
                t.column("rolledUpToWeek", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(indexOn: "daily_digests", columns: ["date"])

            try db.create(table: "period_summaries") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("period", .text).notNull()   // weekly/monthly/yearly
                t.column("periodStart", .datetime).notNull()
                t.column("periodEnd", .datetime).notNull()
                t.column("summary", .text).notNull()
                t.column("dominantSymptoms", .text).notNull().defaults(to: "[]")
                t.column("dominantMedications", .text).notNull().defaults(to: "[]")
                t.column("notableCorrelations", .text).notNull().defaults(to: "[]")
                t.column("rolledUp", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
            }

            // User health profile (singleton, drift-prevention ground truth)
            try db.create(table: "user_health_profile") { t in
                t.primaryKey("id", .integer)
                t.column("confirmedConditions", .text).notNull().defaults(to: "[]")
                t.column("confirmedMedications", .text).notNull().defaults(to: "[]")
                t.column("confirmedAllergies", .text).notNull().defaults(to: "[]")
                t.column("lastConfirmedAt", .datetime)
                t.column("lastUpdatedAt", .datetime).notNull()
            }

            // Local Cheat Sheet: top ~1000 medications + side effects
            // App code does lookups — never the model. No hallucinated pharmacology.
            try db.create(table: "medications") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull().unique()
                t.column("genericName", .text)
                t.column("drugClass", .text)
                t.column("commonSideEffects", .text).notNull().defaults(to: "[]") // JSON
                t.column("seriousSideEffects", .text).notNull().defaults(to: "[]")
            }
            try db.create(indexOn: "medications", columns: ["name"])
            try db.create(indexOn: "medications", columns: ["genericName"])

            try db.create(table: "drug_interactions") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("drugA", .text).notNull()
                t.column("drugB", .text).notNull()
                t.column("severity", .text).notNull()   // mild/moderate/severe/contraindicated
                t.column("description", .text).notNull()
            }
            try db.create(
                indexOn: "drug_interactions",
                columns: ["drugA", "drugB"]
            )
        }

        // v2 — documents, RAG chunks, conversation history
        migrator.registerMigration("v2_documents_and_chat") { db in
            // Imported medical documents (PDFs, lab reports, etc.)
            try db.create(table: "medical_documents") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("filename", .text).notNull()
                t.column("displayName", .text).notNull()
                t.column("pageCount", .integer).notNull().defaults(to: 0)
                t.column("chunkCount", .integer).notNull().defaults(to: 0)
                t.column("importedAt", .datetime).notNull()
            }

            // Text chunks for RAG retrieval (keyword-indexed)
            try db.create(table: "document_chunks") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("documentId", .integer).notNull()
                    .references("medical_documents", onDelete: .cascade)
                t.column("chunkIndex", .integer).notNull()
                t.column("text", .text).notNull()
                t.column("keywords", .text).notNull().defaults(to: "")
            }
            try db.create(indexOn: "document_chunks", columns: ["documentId"])

            // Conversation messages for Ask tab
            try db.create(table: "conversation_messages") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("role", .text).notNull()            // user / assistant
                t.column("content", .text).notNull()
                t.column("inferenceMode", .text).notNull().defaults(to: "onDevice")
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(indexOn: "conversation_messages", columns: ["createdAt"])
        }

        try migrator.migrate(dbQueue)
    }
}
