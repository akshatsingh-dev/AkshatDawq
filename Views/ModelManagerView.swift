import SwiftUI

/// In-app model manager. Accessible from Profile tab.
/// Shows installed models, download new ones, see storage used.
struct ModelManagerView: View {
    @StateObject private var cactus = CactusManager.shared
    @Environment(\.dismiss) private var dismiss
    
    private var verifiedActiveModel: OnDeviceModel? {
        guard let model = cactus.activeModel, cactus.hasInstalledValidModel(model) else { return nil }
        return model
    }

    var body: some View {
        NavigationStack {
            List {
                // Privacy header
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "lock.shield.fill")
                            .foregroundStyle(.green)
                            .font(.title2)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("All inference runs on-device")
                                .font(.subheadline.bold())
                            Text("Model weights are stored in your app's private container and are never uploaded or shared.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                // Active model
                if let active = verifiedActiveModel {
                    Section("Active Model") {
                        ModelListRow(model: active, cactus: cactus, isActive: true)
                    }
                }

                // Available models
                Section {
                    ForEach(OnDeviceModel.available.filter { $0.id != verifiedActiveModel?.id }) { model in
                        ModelListRow(model: model, cactus: cactus, isActive: false)
                    }
                } header: {
                    Text(verifiedActiveModel == nil ? "Choose a Model" : "Other Models")
                } footer: {
                    Text("Smaller models are faster but less accurate. Gemma 4B is recommended for most devices (A14+).")
                }

                // Storage
                Section("Storage") {
                    StorageRow()
                }
            }
            .navigationTitle("On-Device Models")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - ModelListRow

private struct ModelListRow: View {
    let model: OnDeviceModel
    @ObservedObject var cactus: CactusManager
    let isActive: Bool

    private var downloadState: CactusManager.DownloadState? { cactus.downloadStates[model.id] }
    private var isInstalled: Bool { cactus.hasInstalledValidModel(model) }

    var body: some View {
        HStack(spacing: 12) {
            // Icon
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(model.accentColor.opacity(0.12))
                    .frame(width: 38, height: 38)
                Image(systemName: model.icon)
                    .foregroundStyle(model.accentColor)
                    .font(.system(size: 16))
            }

            // Info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.displayName).font(.subheadline.bold())
                    if model.isNew {
                        Text("New")
                            .font(.caption2.bold())
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.blue.opacity(0.15), in: Capsule())
                            .foregroundStyle(.blue)
                    }
                    if model.isRecommended {
                        Text("Recommended")
                            .font(.caption2.bold())
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.green.opacity(0.15), in: Capsule())
                            .foregroundStyle(.green)
                    }
                }
                Text("\(model.paramCount) · \(model.sizeGB) GB · \(model.speedLabel)")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            // Download state / active indicator
            Group {
                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.title3)
                } else if let state = downloadState {
                    switch state {
                    case .downloading(let p):
                        VStack(spacing: 3) {
                            CircularProgress(progress: p, color: model.accentColor)
                                .frame(width: 30, height: 30)
                        }
                    case .installing:
                        ProgressView().scaleEffect(0.8)
                    case .failed:
                        Button("Retry") { Task { await cactus.download(model) } }
                            .font(.caption.bold()).foregroundStyle(.red)
                    }
                } else if isInstalled {
                    Button("Use") { Task { await cactus.selectInstalledModel(model) } }
                        .font(.caption.bold())
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(model.accentColor.opacity(0.1), in: Capsule())
                        .foregroundStyle(model.accentColor)
                } else {
                    Button("Download") { Task { await cactus.download(model) } }
                        .font(.caption.bold())
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(model.accentColor.opacity(0.1), in: Capsule())
                        .foregroundStyle(model.accentColor)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Storage row

private struct StorageRow: View {
    @State private var usedGB: Double = 0.0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Models", systemImage: "internaldrive.fill")
                    .font(.subheadline)
                Spacer()
                Text(usedGB > 0 ? String(format: "%.1f GB", usedGB) : "–")
                    .font(.subheadline).foregroundStyle(.secondary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.quaternary)
                        .frame(height: 6)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.blue)
                        .frame(width: geo.size.width * min(usedGB / 16.0, 1.0), height: 6)
                        .animation(.easeOut, value: usedGB)
                }
            }
            .frame(height: 6)

            Text("Stored in app's private container · never synced to iCloud")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .task { usedGB = await measureModelsStorage() }
    }

    private func measureModelsStorage() async -> Double {
        let modelsDir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DAWQ/Models")

        guard let enumerator = FileManager.default.enumerator(
            at: modelsDir,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0
            total += size
        }
        return Double(total) / 1_073_741_824.0
    }
}
