import SwiftUI
import GRDB

// MARK: - Ask tab — chat with your health data + uploaded documents
//
// Each response is grounded in:
//   1. SQL-derived health context (profile, digests, correlations)
//   2. Keyword-retrieved document chunks (DocumentRAG)
// The model narrates verified data — never invents medical facts.

struct AskView: View {
    @State private var messages: [ConversationMessage] = []
    @State private var inputText = ""
    @State private var isLoading = false
    @State private var showDocPicker = false
    @State private var showModelManager = false
    @State private var importError: String?
    @StateObject private var cactus = CactusManager.shared

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {

                // Messages
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if messages.isEmpty {
                                AskEmptyState()
                                    .padding(.top, 60)
                                    .frame(maxWidth: .infinity)
                            }
                            ForEach(messages, id: \.id) { msg in
                                MessageBubble(message: msg)
                                    .id(msg.id)
                            }
                            if isLoading {
                                ThinkingBubble()
                                    .id("thinking")
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 12)
                    }
                    .onChange(of: messages.count) {
                        if let last = messages.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                    .onChange(of: isLoading) {
                        if isLoading {
                            withAnimation { proxy.scrollTo("thinking", anchor: .bottom) }
                        }
                    }
                }

                Divider()

                // Input bar
                InputBar(
                    text: $inputText,
                    isLoading: isLoading,
                    onSend: { Task { await send() } },
                    onAttach: { showDocPicker = true }
                )
            }
            .navigationTitle("Ask")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showModelManager = true
                    } label: {
                        ProvenancePill()
                    }
                }
            }
            .task {
                loadHistory()
                await cactus.ensureDefaultModelReady()
            }
            .sheet(isPresented: $showModelManager) {
                ModelManagerView()
            }
            .fileImporter(
                isPresented: $showDocPicker,
                allowedContentTypes: [.pdf],
                allowsMultipleSelection: false
            ) { result in
                Task { await handleDocImport(result) }
            }
            .alert("Import error", isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importError ?? "")
            }
        }
    }

    // MARK: - Send

    private func send() async {
        let question = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        inputText = ""
        isLoading = true

        let userMsg = ConversationMessage(
            id: nil, role: .user, content: question,
            inferenceMode: "onDevice", createdAt: Date()
        )
        append(userMsg)

        do {
            let (healthCtx, docCtx) = try buildContext(for: question)
            let (answer, mode) = try await cactus.answerQuery(
                question: question,
                healthContext: healthCtx,
                documentContext: docCtx
            )
            let modeStr: String
            switch mode {
            case .onDevice:    modeStr = "onDevice"
            case .homeServer:  modeStr = "homeServer"
            case .hybridCloud: modeStr = "hybridCloud"
            }
            let assistantMsg = ConversationMessage(
                id: nil, role: .assistant, content: answer,
                inferenceMode: modeStr, createdAt: Date()
            )
            append(assistantMsg)
        } catch {
            let errMsg = ConversationMessage(
                id: nil, role: .assistant,
                content: "Could not answer: \(error.localizedDescription)",
                inferenceMode: "onDevice", createdAt: Date()
            )
            append(errMsg)
        }

        isLoading = false
    }

    private func append(_ msg: ConversationMessage) {
        var m = msg
        _ = try? DatabaseManager.shared.write { db in try m.insert(db) }
        messages.append(m)
    }

    // MARK: - Context assembly

    private func buildContext(for question: String) throws -> (health: String, docs: String) {
        let profile      = (try? DatabaseManager.shared.userProfile()) ?? .empty()
        let digests      = (try? DatabaseManager.shared.recentDailyDigests(days: 14)) ?? []
        let correlations = buildCorrelations()

        let health = InferenceRouter.buildHealthContext(
            profile: profile,
            recentDigests: digests,
            correlations: correlations
        )

        let docs = (try? DocumentRAG.shared.buildContext(for: question)) ?? ""
        return (health, docs)
    }

    private func buildCorrelations() -> [CorrelationResult] {
        let entities = ["fatigue", "headache", "coffee", "alcohol", "ibuprofen"]
        return entities.compactMap { entity in
            try? DatabaseManager.shared.correlate(entity: entity, metric: "avgFatigueScore")
        }.filter { abs($0.percentDifference) > 10 }
    }

    // MARK: - History

    private func loadHistory() {
        messages = (try? DatabaseManager.shared.read { db in
            try ConversationMessage.order(Column("createdAt").asc).fetchAll(db)
        }) ?? []
    }

    // MARK: - Document import

    private func handleDocImport(_ result: Result<[URL], Error>) async {
        switch result {
        case .failure(let err):
            importError = err.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            guard url.startAccessingSecurityScopedResource() else {
                importError = "Permission denied for this file."
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }
            do {
                let doc = try await DocumentRAG.shared.importDocument(from: url)
                let notice = ConversationMessage(
                    id: nil, role: .assistant,
                    content: "Imported \"\(doc.displayName)\" (\(doc.chunkCount) sections). You can now ask questions about it.",
                    inferenceMode: "onDevice", createdAt: Date()
                )
                append(notice)
            } catch {
                importError = error.localizedDescription
            }
        }
    }
}

// MARK: - Message bubble

struct MessageBubble: View {
    let message: ConversationMessage

    private var isUser: Bool { message.role == .user }

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
            HStack {
                if isUser { Spacer(minLength: 60) }
                Text(message.content)
                    .font(.body)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        isUser
                            ? Color.blue
                            : Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 18)
                    )
                    .foregroundStyle(isUser ? .white : .primary)
                if !isUser { Spacer(minLength: 60) }
            }
            if !isUser {
                let mode: InferenceMode = {
                    switch message.inferenceMode {
                    case "homeServer":  return .homeServer
                    case "hybridCloud": return .hybridCloud
                    default:            return .onDevice
                    }
                }()
                ProvenanceBadge(mode: mode)
                    .padding(.leading, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }
}

// MARK: - Thinking indicator

struct ThinkingBubble: View {
    @State private var dotCount = 1

    var body: some View {
        HStack {
            Text(String(repeating: ".", count: dotCount))
                .font(.title2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 18)
                )
            Spacer(minLength: 60)
        }
        .onAppear {
            Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { t in
                dotCount = dotCount % 3 + 1
            }
        }
    }
}

// MARK: - Input bar

struct InputBar: View {
    @Binding var text: String
    let isLoading: Bool
    let onSend: () -> Void
    let onAttach: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onAttach) {
                Image(systemName: "paperclip")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }

            TextField("Ask about your health…", text: $text, axis: .vertical)
                .lineLimit(1...4)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                .onSubmit { onSend() }

            Button(action: onSend) {
                Image(systemName: isLoading ? "stop.circle.fill" : "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(
                        text.trimmingCharacters(in: .whitespaces).isEmpty && !isLoading
                            ? Color.secondary
                            : Color.blue
                    )
            }
            .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty && !isLoading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(uiColor: .systemGroupedBackground))
    }
}

// MARK: - Empty state

struct AskEmptyState: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Ask anything about your health")
                .font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                SuggestionChip(text: "How did I sleep this week?")
                SuggestionChip(text: "Any patterns with my headaches?")
                SuggestionChip(text: "Attach a lab report to ask questions about it")
            }
        }
        .padding(.horizontal, 24)
    }
}

struct SuggestionChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}
