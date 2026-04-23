import Foundation
import PDFKit
import GRDB

// MARK: - Document import + keyword-based RAG retrieval
//
// No separate embedding model needed — keyword overlap scoring is fast and effective
// for structured medical documents (lab reports, discharge summaries, prescriptions).
// Chunk size: 512 chars with 64-char overlap to avoid splitting mid-sentence.

final class DocumentRAG {
    static let shared = DocumentRAG()
    private let db = DatabaseManager.shared

    private static let chunkSize  = 512
    private static let chunkOverlap = 64

    // MARK: - Import

    func importDocument(from url: URL) async throws -> MedicalDocument {
        let filename = url.lastPathComponent
        let displayName = url.deletingPathExtension().lastPathComponent
        let rawText = extractText(from: url)
        guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DocumentError.unreadable
        }

        let pageCount = PDFDocument(url: url)?.pageCount ?? 1
        let chunks = makeChunks(rawText)

        var doc = MedicalDocument(
            id: nil,
            filename: filename,
            displayName: displayName,
            pageCount: pageCount,
            chunkCount: chunks.count,
            importedAt: Date()
        )

        try db.write { db in
            try doc.insert(db)
            guard let docId = doc.id else { return }
            for (i, chunkText) in chunks.enumerated() {
                var chunk = DocumentChunk(
                    id: nil,
                    documentId: docId,
                    chunkIndex: i,
                    text: chunkText,
                    keywords: extractKeywords(from: chunkText)
                )
                try chunk.insert(db)
            }
        }

        return doc
    }

    func deleteDocument(_ doc: MedicalDocument) throws {
        guard let id = doc.id else { return }
        try db.write { db in
            // Cascade would handle this, but be explicit
            try db.execute(sql: "DELETE FROM document_chunks WHERE documentId = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM medical_documents WHERE id = ?", arguments: [id])
        }
    }

    func allDocuments() throws -> [MedicalDocument] {
        try db.read { db in
            try MedicalDocument.order(Column("importedAt").desc).fetchAll(db)
        }
    }

    // MARK: - Retrieval

    /// Keyword overlap scoring — no embedding model needed.
    /// Returns top-k chunks most relevant to the query.
    func retrieveChunks(for query: String, topK: Int = 4) throws -> [DocumentChunk] {
        let queryTokens = tokenize(query)
        guard !queryTokens.isEmpty else { return [] }

        let allChunks = try db.read { db in
            try DocumentChunk.fetchAll(db)
        }

        let scored: [(DocumentChunk, Int)] = allChunks.compactMap { chunk in
            let chunkTokens = Set(chunk.keywords.split(separator: " ").map(String.init))
            let overlap = queryTokens.filter { chunkTokens.contains($0) }.count
            return overlap > 0 ? (chunk, overlap) : nil
        }

        return scored
            .sorted { $0.1 > $1.1 }
            .prefix(topK)
            .map(\.0)
    }

    /// Build a context string for LLM prompt from the most relevant chunks.
    func buildContext(for query: String) throws -> String {
        let chunks = try retrieveChunks(for: query)
        guard !chunks.isEmpty else { return "" }
        return chunks.map(\.text).joined(separator: "\n---\n")
    }

    // MARK: - PDF text extraction

    private func extractText(from url: URL) -> String {
        guard let pdf = PDFDocument(url: url) else { return "" }
        return (0..<pdf.pageCount)
            .compactMap { pdf.page(at: $0)?.string }
            .joined(separator: "\n")
    }

    // MARK: - Chunking

    private func makeChunks(_ text: String) -> [String] {
        let chars = Array(text)
        var chunks: [String] = []
        var start = 0
        while start < chars.count {
            let end = min(start + Self.chunkSize, chars.count)
            chunks.append(String(chars[start..<end]))
            if end == chars.count { break }
            start += Self.chunkSize - Self.chunkOverlap
        }
        return chunks
    }

    // MARK: - Keyword extraction

    private static let stopWords: Set<String> = [
        "the", "a", "an", "is", "in", "on", "at", "to", "for", "of", "and", "or",
        "with", "this", "that", "was", "are", "be", "been", "have", "has", "had",
        "do", "does", "did", "not", "from", "by", "as", "it", "its", "which", "were",
        "their", "there", "they", "than", "but", "also", "will", "would", "could",
        "should", "may", "can", "you", "your", "our", "we", "he", "she", "his", "her"
    ]

    private func tokenize(_ text: String) -> Set<String> {
        Set(
            text.lowercased()
                .components(separatedBy: .alphanumerics.inverted)
                .filter { $0.count > 3 && !Self.stopWords.contains($0) }
        )
    }

    private func extractKeywords(from text: String) -> String {
        tokenize(text).prefix(60).joined(separator: " ")
    }
}

// MARK: - Errors

enum DocumentError: LocalizedError {
    case unreadable
    case importFailed

    var errorDescription: String? {
        switch self {
        case .unreadable:   return "Could not extract text from this file."
        case .importFailed: return "Document import failed."
        }
    }
}
