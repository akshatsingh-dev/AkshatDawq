import SwiftUI
import UniformTypeIdentifiers

struct DataView: View {
    @StateObject private var hk = HealthKitManager.shared
    @State private var documents: [MedicalDocument] = []
    @State private var showImporter = false
    @State private var isImportingHistory = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Apple Health") {
                    HStack {
                        Text("Sync status")
                        Spacer()
                        Text(syncStatusText)
                            .foregroundStyle(.secondary)
                    }

                    if let progress = hk.importProgress {
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(value: progress)
                            Text("\(Int(progress * 100))%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button {
                        Task { await importAllHistory() }
                    } label: {
                        Label("Import All History", systemImage: "arrow.down.circle")
                    }
                    .disabled(isImportingHistory || hk.importProgress != nil)
                }

                Section("Documents") {
                    if documents.isEmpty {
                        Text("No documents imported yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(documents, id: \.id) { document in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(document.displayName)
                                    .font(.body.weight(.medium))
                                Text("\(document.pageCount) pages • \(document.chunkCount) sections")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .onDelete(perform: deleteDocuments)
                    }

                    Button {
                        showImporter = true
                    } label: {
                        Label("Import PDF", systemImage: "doc.badge.plus")
                    }
                }
            }
            .navigationTitle("Data")
            .task {
                await refreshDocuments()
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.pdf],
                allowsMultipleSelection: false
            ) { result in
                Task { await handleImport(result) }
            }
            .alert(
                "Error",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var syncStatusText: String {
        if let date = hk.lastSyncDate {
            return "Last: \(date.formatted(date: .abbreviated, time: .shortened))"
        }
        return hk.isAuthorized ? "Not synced yet" : "Not authorized"
    }

    private func importAllHistory() async {
        isImportingHistory = true
        defer { isImportingHistory = false }

        do {
            if !hk.isAuthorized {
                try await hk.requestAuthorization()
            }
            try await hk.importHistory()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshDocuments() async {
        documents = (try? DocumentRAG.shared.allDocuments()) ?? []
    }

    private func handleImport(_ result: Result<[URL], Error>) async {
        do {
            let urls = try result.get()
            guard let url = urls.first else { return }
            guard url.startAccessingSecurityScopedResource() else {
                errorMessage = "Permission denied for selected file."
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }

            _ = try await DocumentRAG.shared.importDocument(from: url)
            await refreshDocuments()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteDocuments(at offsets: IndexSet) {
        for offset in offsets {
            let doc = documents[offset]
            try? DocumentRAG.shared.deleteDocument(doc)
        }
        documents.remove(atOffsets: offsets)
    }
}
