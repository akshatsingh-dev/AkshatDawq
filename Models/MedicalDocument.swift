import Foundation
import GRDB

// MARK: - Imported medical documents (PDFs, lab reports, etc.)

struct MedicalDocument: Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var filename: String
    var displayName: String
    var pageCount: Int
    var chunkCount: Int
    var importedAt: Date

    static let databaseTableName = "medical_documents"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Text chunks for keyword-based RAG retrieval

struct DocumentChunk: Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var documentId: Int64
    var chunkIndex: Int
    var text: String
    var keywords: String    // space-separated terms for retrieval scoring

    static let databaseTableName = "document_chunks"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Conversation messages (Ask tab history)

enum MessageRole: String, Codable, DatabaseValueConvertible {
    case user      = "user"
    case assistant = "assistant"
}

struct ConversationMessage: Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var role: MessageRole
    var content: String
    var inferenceMode: String   // "onDevice" / "homeServer" / "hybridCloud"
    var createdAt: Date

    static let databaseTableName = "conversation_messages"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
