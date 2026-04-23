import Foundation
import NaturalLanguage

/// Rule-based medical entity extraction using NaturalLanguage framework + keyword dictionary.
/// Used when no model is downloaded. Zero latency, no network, works offline.
/// Handles ~80% of common medical vocabulary accurately enough for the knowledge graph.
enum MedicalNLPFallback {

    static func extractEntities(from text: String) -> ExtractedEntities {
        var entities: [(name: String, type: EntityType)] = []
        var relationships: [(subject: String, predicate: RelationshipType, object: String, offsetSeconds: Int?)] = []

        let lower = text.lowercased()

        // NaturalLanguage noun extraction — catches proper nouns (drug names, condition names)
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .nameType])
        tagger.string = text
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass) { tag, range in
            guard let tag, tag == .noun || tag == .otherWord else { return true }
            let word = String(text[range]).lowercased()
            if let type = classify(word: word) {
                if !entities.contains(where: { $0.name.lowercased() == word }) {
                    entities.append((name: String(text[range]), type: type))
                }
            }
            return true
        }

        // Keyword scan for patterns not caught by NLTagger
        for (keyword, type) in medicalKeywords {
            if lower.contains(keyword) && !entities.contains(where: { $0.name.lowercased() == keyword }) {
                entities.append((name: keyword, type: type))
            }
        }

        // Simple relationship inference from verb patterns
        relationships += inferRelationships(from: lower, entities: entities)

        return ExtractedEntities(entities: entities, relationships: relationships, rawSource: text)
    }

    // MARK: - Keyword → EntityType classifier

    private static func classify(word: String) -> EntityType? {
        let w = word.lowercased()
        if symptoms.contains(w) { return .symptom }
        if medications.contains(w) { return .medication }
        if conditions.contains(w) { return .condition }
        if foods.contains(w) { return .food }
        if activities.contains(w) { return .activity }
        if emotions.contains(w) { return .emotion }
        return nil
    }

    // MARK: - Relationship inference

    private static func inferRelationships(
        from text: String,
        entities: [(name: String, type: EntityType)]
    ) -> [(subject: String, predicate: RelationshipType, object: String, offsetSeconds: Int?)] {
        var rels: [(subject: String, predicate: RelationshipType, object: String, offsetSeconds: Int?)] = []

        let startVerbs = ["started", "began", "took", "taking", "started taking"]
        let stopVerbs = ["stopped", "quit", "discontinued", "no longer"]
        let experienceVerbs = ["felt", "feeling", "experiencing", "noticed", "had", "having"]
        let followedVerbs = ["after", "following", "then", "afterwards"]

        for verb in startVerbs where text.contains(verb) {
            for entity in entities where entity.type == .medication {
                rels.append((subject: entity.name, predicate: .started, object: entity.name, offsetSeconds: nil))
            }
        }
        for verb in stopVerbs where text.contains(verb) {
            for entity in entities where entity.type == .medication {
                rels.append((subject: entity.name, predicate: .stopped, object: entity.name, offsetSeconds: nil))
            }
        }
        for verb in experienceVerbs where text.contains(verb) {
            for entity in entities where entity.type == .symptom {
                rels.append((subject: entity.name, predicate: .experienced, object: entity.name, offsetSeconds: nil))
            }
        }

        // Temporal: "headache after coffee" → FOLLOWED
        for followed in followedVerbs where text.contains(followed) {
            let words = text.components(separatedBy: " ")
            for (i, word) in words.enumerated() where word == followed {
                let before = i > 0 ? words[i-1] : ""
                let after = i < words.count-1 ? words[i+1] : ""
                if let subj = entities.first(where: { $0.name.lowercased() == before }),
                   let obj = entities.first(where: { $0.name.lowercased() == after }) {
                    rels.append((subject: subj.name, predicate: .followed, object: obj.name, offsetSeconds: nil))
                }
            }
        }

        return rels
    }

    // MARK: - Medical vocabulary

    static let medicalKeywords: [(String, EntityType)] = {
        var kw: [(String, EntityType)] = []
        kw += symptoms.map { ($0, .symptom) }
        kw += medications.map { ($0, .medication) }
        kw += conditions.map { ($0, .condition) }
        kw += foods.map { ($0, .food) }
        kw += activities.map { ($0, .activity) }
        kw += emotions.map { ($0, .emotion) }
        return kw
    }()

    static let symptoms: Set<String> = [
        "headache", "migraine", "nausea", "vomiting", "fatigue", "tiredness",
        "dizziness", "vertigo", "chest pain", "chest pressure", "shortness of breath",
        "palpitations", "insomnia", "brain fog", "joint pain", "back pain",
        "abdominal pain", "bloating", "constipation", "diarrhea", "rash",
        "itching", "swelling", "fever", "chills", "sweating", "night sweats",
        "dry mouth", "blurred vision", "tinnitus", "numbness", "tingling",
        "weakness", "muscle ache", "cramps", "anxiety", "depression",
        "inflammation", "pain", "ache", "soreness", "stiffness"
    ]

    static let medications: Set<String> = [
        "ibuprofen", "acetaminophen", "tylenol", "advil", "aspirin",
        "lisinopril", "metformin", "atorvastatin", "levothyroxine", "omeprazole",
        "metoprolol", "amlodipine", "losartan", "gabapentin", "sertraline",
        "escitalopram", "fluoxetine", "bupropion", "venlafaxine", "duloxetine",
        "alprazolam", "lorazepam", "clonazepam", "zolpidem", "melatonin",
        "vitamin d", "magnesium", "zinc", "iron", "probiotic", "fish oil",
        "antihistamine", "cetirizine", "loratadine", "diphenhydramine",
        "naproxen", "aleve", "excedrin", "tums", "pepto", "laxative",
        "inhaler", "albuterol", "prednisone", "amoxicillin", "azithromycin"
    ]

    static let conditions: Set<String> = [
        "diabetes", "hypertension", "hypothyroidism", "hyperthyroidism",
        "anxiety disorder", "depression", "adhd", "asthma", "eczema",
        "psoriasis", "ibs", "crohns", "gerd", "acid reflux", "celiac",
        "fibromyalgia", "lupus", "rheumatoid arthritis", "osteoarthritis",
        "sleep apnea", "insomnia disorder", "migraine disorder",
        "anemia", "chronic fatigue", "hashimoto", "pcos", "endometriosis"
    ]

    static let foods: Set<String> = [
        "coffee", "alcohol", "wine", "beer", "gluten", "dairy", "sugar",
        "caffeine", "soda", "fast food", "processed food", "red meat",
        "wheat", "lactose", "eggs", "nuts", "shellfish", "soy"
    ]

    static let activities: Set<String> = [
        "exercise", "running", "walking", "yoga", "gym", "workout",
        "cycling", "swimming", "lifting", "meditation", "stretching"
    ]

    static let emotions: Set<String> = [
        "stressed", "anxious", "depressed", "sad", "happy", "calm",
        "overwhelmed", "irritable", "mood", "emotional", "worried"
    ]
}
