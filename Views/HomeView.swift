import SwiftUI
import GRDB

struct HomeView: View {
    @State private var recentDigests: [DailyDigest] = []
    @State private var userProfile: UserHealthProfile?
    @State private var latestLog: HealthLog?
    @State private var showModelManager = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {

                    // Metrics row
                    MetricsRow(log: latestLog)
                        .padding(.horizontal)

                    // Ask entry point
                    AskPromptCard()
                        .padding(.horizontal)

                    // Drift warning (only when profile is fresh/empty)
                    if let profile = userProfile, profile.lastConfirmedAt == nil {
                        DriftBanner()
                            .padding(.horizontal)
                    }

                    // Recent digests
                    if !recentDigests.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Recent")
                                .font(.headline)
                                .padding(.horizontal)

                            ForEach(recentDigests.prefix(5), id: \.id) { digest in
                                DigestRow(digest: digest)
                                    .padding(.horizontal)
                            }
                        }
                    } else {
                        EmptyHealthState()
                            .padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("DAWQ")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showModelManager = true
                    } label: {
                        ProvenancePill()
                    }
                }
            }
            .task { await loadData() }
            .refreshable { await loadData() }
            .sheet(isPresented: $showModelManager) {
                ModelManagerView()
            }
        }
    }

    private func loadData() async {
        recentDigests = (try? DatabaseManager.shared.recentDailyDigests(days: 30)) ?? []
        userProfile   = try? DatabaseManager.shared.userProfile()
        latestLog     = try? DatabaseManager.shared.read { db in
            try HealthLog
                .filter(Column("source") == LogSource.healthKit.rawValue)
                .order(Column("createdAt").desc)
                .fetchOne(db)
        }
    }
}

// MARK: - Metrics row

struct MetricsRow: View {
    let log: HealthLog?

    var body: some View {
        HStack(spacing: 12) {
            MetricTile(icon: "heart.fill",          color: .red,    label: "Heart Rate",
                       value: log?.heartRateBpm.map { "\(Int($0)) bpm" } ?? "–")
            MetricTile(icon: "moon.fill",            color: .indigo, label: "Sleep",
                       value: log?.sleepHours.map   { String(format: "%.1fh", $0) } ?? "–")
            MetricTile(icon: "waveform.path.ecg",   color: .green,  label: "HRV",
                       value: log?.hrvMs.map        { "\(Int($0))ms" } ?? "–")
        }
    }
}

struct MetricTile: View {
    let icon: String
    let color: Color
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.caption)
            Text(value)
                .font(.system(.title3, design: .rounded).bold())
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Ask entry card

struct AskPromptCard: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.title3)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Ask about your health")
                    .font(.subheadline.weight(.semibold))
                Text("Use the Ask tab to chat with your data")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "arrow.right")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Digest row

struct DigestRow: View {
    let digest: DailyDigest

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(digest.date, style: .date)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(digest.summary)
                .font(.subheadline)
                .lineLimit(2)
            if !digest.keySymptomsList.isEmpty {
                HStack(spacing: 6) {
                    ForEach(digest.keySymptomsList.prefix(3), id: \.self) { tag in
                        Text(tag)
                            .font(.caption2)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.orange.opacity(0.12), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Empty state

struct EmptyHealthState: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("No data yet")
                .font(.headline)
            Text("Connect Apple Health or import a document to get started.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Drift banner

struct DriftBanner: View {
    var body: some View {
        Label("Confirm your health profile in the You tab", systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Provenance pill (toolbar)

struct ProvenancePill: View {
    @StateObject private var cactus = CactusManager.shared

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(cactus.isModelLoaded ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Text(cactus.isModelLoaded ? "On-device" : "No model")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
    }
}

// MARK: - Provenance badge (used in Ask/Insights responses)

struct ProvenanceBadge: View {
    let mode: InferenceMode

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: iconName).foregroundStyle(iconColor).font(.caption2)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
    }

    private var iconName: String {
        switch mode {
        case .onDevice:    return "lock.fill"
        case .homeServer:  return "server.rack"
        case .hybridCloud: return "cloud.fill"
        }
    }
    private var iconColor: Color {
        switch mode {
        case .onDevice:    return .green
        case .homeServer:  return .blue
        case .hybridCloud: return .orange
        }
    }
    private var label: String {
        switch mode {
        case .onDevice:    return "On-device"
        case .homeServer:  return "Home server"
        case .hybridCloud: return "Cloud-assisted"
        }
    }
}
