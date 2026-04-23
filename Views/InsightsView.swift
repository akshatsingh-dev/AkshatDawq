import SwiftUI

/// SQL-powered insights — deterministic math, no hallucination.
/// SLM narrates results from this view; it does not generate them.
struct InsightsView: View {
    @State private var correlations: [CorrelationResult] = []
    @State private var symptomFreqs: [(String, Int)] = []
    @State private var isLoading = false
    @State private var inferenceMode: InferenceMode = .onDevice
    @State private var narratedInsight: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    ProvenanceBadge(mode: inferenceMode)
                        .padding(.horizontal)

                    // SQL correlations
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Patterns")
                            .font(.headline)
                            .padding(.horizontal)

                        if correlations.isEmpty && !isLoading {
                            Text("Log for 2+ weeks to see patterns.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal)
                        }

                        ForEach(correlations, id: \.entity) { result in
                            CorrelationCard(result: result)
                                .padding(.horizontal)
                        }
                    }

                    // Symptom frequency
                    if !symptomFreqs.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Symptom frequency (90 days)")
                                .font(.headline)
                                .padding(.horizontal)

                            ForEach(symptomFreqs, id: \.0) { (symptom, count) in
                                HStack {
                                    Text(symptom)
                                    Spacer()
                                    Text("\(count)×")
                                        .font(.system(.body, design: .rounded).bold())
                                        .foregroundStyle(.orange)
                                }
                                .padding(.horizontal)
                            }
                        }
                    }

                    // SLM-narrated insight
                    if let insight = narratedInsight {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("DAWQ says")
                                    .font(.headline)
                                ProvenanceBadge(mode: inferenceMode)
                            }
                            .padding(.horizontal)

                            Text(insight)
                                .font(.body)
                                .padding()
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                                .padding(.horizontal)
                        }
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("Insights")
            .task { await loadInsights() }
        }
    }

    private func loadInsights() async {
        isLoading = true
        defer { isLoading = false }

        // Run SQL correlations — deterministic, no hallucination
        var results: [CorrelationResult] = []
        let commonEntities = ["fatigue", "headache", "ibuprofen", "coffee", "alcohol"]
        for entity in commonEntities {
            if let result = try? DatabaseManager.shared.correlate(entity: entity, metric: "avgFatigueScore"),
               abs(result.percentDifference) > 10 {
                results.append(result)
            }
        }
        correlations = results.sorted { abs($0.percentDifference) > abs($1.percentDifference) }

        // Symptom frequencies
        let symptoms = ["headache", "fatigue", "nausea", "chest pressure", "dizziness"]
        let freqs = try? symptoms.compactMap { symptom -> (String, Int)? in
            let count = try DatabaseManager.shared.symptomFrequency(symptom: symptom)
            return count > 0 ? (symptom, count) : nil
        }
        symptomFreqs = (freqs ?? []).sorted { $0.1 > $1.1 }

        // Ask SLM to narrate top correlation (narrates math, never generates facts)
        if let top = correlations.first,
           let result = try? await CactusManager.shared.narrateCorrelation(top) {
            narratedInsight = result.text
            inferenceMode = result.mode
        }
    }
}

struct CorrelationCard: View {
    let result: CorrelationResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(result.entity.capitalized)
                    .font(.subheadline.bold())
                Spacer()
                Text(String(format: "%+.0f%%", result.percentDifference))
                    .font(.system(.body, design: .rounded).bold())
                    .foregroundStyle(result.percentDifference > 0 ? .red : .green)
            }
            Text(result.narrative)
                .font(.caption)
                .foregroundStyle(.secondary)

            // Visual bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(.secondary.opacity(0.15))
                        .frame(height: 6)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(result.percentDifference > 0 ? Color.red : .green)
                        .frame(
                            width: geo.size.width * min(abs(result.percentDifference) / 100, 1),
                            height: 6
                        )
                }
            }
            .frame(height: 6)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
