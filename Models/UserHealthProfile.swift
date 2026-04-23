import Foundation
import GRDB

/// The user's current confirmed health profile.
/// Updated nightly by drift-prevention UI — user confirms or corrects.
/// This is the ground truth the SLM narrator uses. Never inferred silently.
struct UserHealthProfile: Codable, FetchableRecord, PersistableRecord {
    var id: Int64 = 1               // singleton row
    var confirmedConditions: String // JSON-encoded [String]
    var confirmedMedications: String
    var confirmedAllergies: String
    var lastConfirmedAt: Date?
    var lastUpdatedAt: Date

    static let databaseTableName = "user_health_profile"

    var conditionsList: [String] {
        (try? JSONDecoder().decode([String].self, from: Data(confirmedConditions.utf8))) ?? []
    }

    var medicationsList: [String] {
        (try? JSONDecoder().decode([String].self, from: Data(confirmedMedications.utf8))) ?? []
    }

    var allergiesList: [String] {
        (try? JSONDecoder().decode([String].self, from: Data(confirmedAllergies.utf8))) ?? []
    }

    static func encode(_ list: [String]) -> String {
        (try? String(data: JSONEncoder().encode(list), encoding: .utf8)) ?? "[]"
    }

    static func empty() -> UserHealthProfile {
        UserHealthProfile(
            confirmedConditions: "[]",
            confirmedMedications: "[]",
            confirmedAllergies: "[]",
            lastConfirmedAt: nil,
            lastUpdatedAt: Date()
        )
    }
}
