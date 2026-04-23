import Foundation

// MARK: - Inference routing decision engine
//
// Decides whether a query runs on-device or routes to cloud.
//
// ── Cactus SDK hook ──────────────────────────────────────────────────────────
// When the Cactus SDK is available, replace `route(...)` with:
//
//   import Cactus
//   let decision = try await CactusRouter.route(
//       query: query,
//       context: context,
//       policy: .privacyFirst,
//       models: [.onDevice(.gemma3_4b), .cloud(.cactusCloud)]
//   )
//
// Cactus handles: on-device capability scoring, cloud abstraction enforcement,
// latency vs. quality trade-off, and automatic fallback.
// ─────────────────────────────────────────────────────────────────────────────
//
// ── Honcho memory hook ────────────────────────────────────────────────────────
// Honcho (honcho.ai) stores compressed long-term user memory across sessions.
// Swift SDK not yet available — use URLSession when wiring up:
//
//   // Store message:
//   POST https://api.honcho.dev/v1/apps/{appId}/users/{userId}/sessions/{sessionId}/messages
//   Authorization: Bearer {honchoApiKey}
//   Body: { "content": abstractedMessage, "is_user": true }
//
//   // Retrieve memory for context:
//   GET  https://api.honcho.dev/v1/apps/{appId}/users/{userId}/sessions/{sessionId}/metamessages
//
// Honcho's metamessage layer produces compressed summaries of past sessions.
// These summaries are passed into the prompt context alongside RAG chunks.
// Keep raw PII out — send only the AbstractedMedicalBrief to Honcho.
// ─────────────────────────────────────────────────────────────────────────────

struct InferenceRouter {

    // MARK: - Privacy classification

    enum PrivacyLevel {
        case sensitive   // PII or precise dosing — never leaves device
        case standard    // Can be abstracted for cloud routing
    }

    // MARK: - Route decision

    /// Returns the inference mode for a given query.
    /// On-device always wins when: (a) query is sensitive, (b) model loaded, (c) forced.
    static func route(
        query: String,
        modelLoaded: Bool,
        forceOnDevice: Bool = false
    ) -> InferenceMode {
        guard !forceOnDevice else { return .onDevice }
        guard privacyLevel(of: query) == .standard else { return .onDevice }

        // Model loaded → always on-device (fast, private)
        if modelLoaded { return .onDevice }

        // No model + non-sensitive → future Cactus cloud route
        // Uncommenting below enables hybrid mode once cloud backend is ready:
        // return .hybridCloud

        return .onDevice
    }

    // MARK: - Privacy scoring

    static func privacyLevel(of query: String) -> PrivacyLevel {
        let text = query.lowercased()
        let sensitiveMarkers = [
            "mg", "mcg", "ml", "dose", "dosage",
            "my name", "i am ", "i'm ", "born", "birthday",
            "address", "insurance", "doctor", "hospital",
            "ssn", "social security"
        ]
        return sensitiveMarkers.contains(where: { text.contains($0) }) ? .sensitive : .standard
    }

    // MARK: - Prompt context builder

    /// Assembles the health context block injected into every query prompt.
    /// SQL math + profile facts — no raw transcripts, no PII.
    static func buildHealthContext(
        profile: UserHealthProfile,
        recentDigests: [DailyDigest],
        correlations: [CorrelationResult]
    ) -> String {
        var parts: [String] = []

        let conditions = profile.conditionsList
        let medications = profile.medicationsList
        let allergies = profile.allergiesList

        if !conditions.isEmpty  { parts.append("Conditions: \(conditions.joined(separator: ", "))") }
        if !medications.isEmpty { parts.append("Medications: \(medications.joined(separator: ", "))") }
        if !allergies.isEmpty   { parts.append("Allergies: \(allergies.joined(separator: ", "))") }

        if let latest = recentDigests.first {
            parts.append("Last digest (\(latest.date.formatted(date: .abbreviated, time: .omitted))): \(latest.summary.prefix(300))")
        }

        let topCorr = correlations.prefix(2).map(\.narrative)
        if !topCorr.isEmpty {
            parts.append("Patterns: \(topCorr.joined(separator: ". "))")
        }

        return parts.joined(separator: "\n")
    }
}
