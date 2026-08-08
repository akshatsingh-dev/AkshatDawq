import Foundation
import llama
import OSLog

private let log = Logger(subsystem: "com.dawq.app", category: "CactusManager")

// MARK: - InferenceMode

enum InferenceMode {
    case onDevice
    case homeServer
    case hybridCloud
}

// MARK: - InferenceBackend protocol
//
// Abstraction over llama.cpp (current) and Cactus (future).
// Swap backends by changing `CactusManager.backend`.
// Cactus integration path: implement CactusBackend when cactus-compute/cactus
// adds GGUF support + Swift Package Manager Package.swift.

protocol InferenceBackend: AnyObject {
    /// True once a model is loaded and ready to generate.
    var isLoaded: Bool { get }
    /// Load a GGUF model from disk into memory.
    func load(at url: URL) async throws
    /// Run next-token generation and return the full response string.
    func generate(prompt: String, maxTokens: Int) async throws -> String
    /// Release model from memory (idempotent).
    func unload()
}

// MARK: - LlamaCppBackend
//
// llama.cpp inference via ggml-org/llama.cpp Swift SPM package.
// Metal GPU offload enabled (n_gpu_layers = 35).
// NOTE: Current pinned commit (ecc93d05, Dec 2024) does NOT support gemma3/gemma4
// architecture. Upgrade the llama.cpp SPM dependency to a build ≥ b4977 for Gemma
// 3/4 support — requires either a Package.swift-restored fork or switch to SwiftLlama.

final class LlamaCppBackend: InferenceBackend {

    private(set) var isLoaded = false
    private var llamaContext: OpaquePointer?
    private var llamaModel: OpaquePointer?

    func load(at url: URL) async throws {
        log.info("LlamaCppBackend.load: start path=\(url.path)")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { continuation.resume(); return }

                log.info("LlamaCppBackend.load: calling llama_load_model_from_file…")
                var modelParams = llama_model_default_params()
                modelParams.n_gpu_layers = 35 // Metal GPU offload

                guard let model = llama_load_model_from_file(url.path, modelParams) else {
                    log.error("LlamaCppBackend.load: llama_load_model_from_file returned nil — unsupported arch or OOM")
                    continuation.resume(throwing: InferenceError.modelLoadFailed)
                    return
                }
                log.info("LlamaCppBackend.load: model pointer OK, creating context…")

                var ctxParams = llama_context_default_params()
                ctxParams.n_ctx = 2048
                ctxParams.n_batch = 512

                guard let ctx = llama_new_context_with_model(model, ctxParams) else {
                    log.error("LlamaCppBackend.load: llama_new_context_with_model returned nil — OOM or bad params")
                    llama_free_model(model)
                    continuation.resume(throwing: InferenceError.modelLoadFailed)
                    return
                }
                log.info("LlamaCppBackend.load: context OK")

                Task { @MainActor in
                    self.llamaModel = model
                    self.llamaContext = ctx
                    self.isLoaded = true
                    log.info("LlamaCppBackend.load: isLoaded=true ✓")
                }
                continuation.resume()
            }
        }
    }

    func generate(prompt: String, maxTokens: Int) async throws -> String {
        guard let ctx = llamaContext, let model = llamaModel else {
            throw InferenceError.modelNotLoaded
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let nPrompt = prompt.utf8.count + 32
                var tokens = [llama_token](repeating: 0, count: nPrompt)
                let promptCStr = prompt.cString(using: .utf8)!
                let nTokenized = llama_tokenize(model, promptCStr, Int32(prompt.utf8.count), &tokens, Int32(nPrompt), true, true)

                guard nTokenized > 0 else {
                    continuation.resume(throwing: InferenceError.tokenizationFailed)
                    return
                }

                tokens = Array(tokens.prefix(Int(nTokenized)))

                var batch = llama_batch_init(Int32(tokens.count), 0, 1)
                for (i, token) in tokens.enumerated() {
                    batch.token[i] = token
                    batch.pos[i] = Int32(i)
                    batch.n_seq_id[i] = 1
                    batch.seq_id[i]![0] = 0
                    batch.logits[i] = i == tokens.count - 1 ? 1 : 0
                }
                batch.n_tokens = Int32(tokens.count)

                guard llama_decode(ctx, batch) == 0 else {
                    llama_batch_free(batch)
                    continuation.resume(throwing: InferenceError.decodeFailed)
                    return
                }
                llama_batch_free(batch)

                var output = ""
                let nVocab = llama_n_vocab(model)
                var nPos = Int32(tokens.count)
                let sampler = LlamaCppBackend.buildSampler()

                for _ in 0..<maxTokens {
                    let logits = llama_get_logits_ith(ctx, -1)!
                    var candidates = (0..<nVocab).map { id in
                        llama_token_data(id: id, logit: logits[Int(id)], p: 0)
                    }
                    var candidateArray = llama_token_data_array(
                        data: &candidates,
                        size: candidates.count,
                        selected: -1,
                        sorted: false
                    )

                    llama_sampler_apply(sampler, &candidateArray)
                    let nextToken = candidateArray.data![Int(candidateArray.selected)].id

                    if llama_token_is_eog(model, nextToken) { break }

                    var buf = [CChar](repeating: 0, count: 256)
                    let nChars = llama_token_to_piece(model, nextToken, &buf, 256, 0, true)
                    if nChars > 0 {
                        output += String(bytes: buf.prefix(Int(nChars)).map { UInt8(bitPattern: $0) }, encoding: .utf8) ?? ""
                    }

                    var nextBatch = llama_batch_init(1, 0, 1)
                    nextBatch.token[0] = nextToken
                    nextBatch.pos[0] = nPos
                    nextBatch.n_seq_id[0] = 1
                    nextBatch.seq_id[0]![0] = 0
                    nextBatch.logits[0] = 1
                    nextBatch.n_tokens = 1
                    nPos += 1

                    if llama_decode(ctx, nextBatch) != 0 {
                        llama_batch_free(nextBatch)
                        break
                    }
                    llama_batch_free(nextBatch)
                }

                llama_sampler_free(sampler)
                llama_kv_cache_clear(ctx)
                continuation.resume(returning: output.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    func unload() {
        if let ctx = llamaContext { llama_free(ctx) }
        if let model = llamaModel { llama_free_model(model) }
        llamaContext = nil
        llamaModel = nil
        isLoaded = false
    }

    private static func buildSampler() -> UnsafeMutablePointer<llama_sampler> {
        let sparams = llama_sampler_chain_default_params()
        let chain = llama_sampler_chain_init(sparams)!
        llama_sampler_chain_add(chain, llama_sampler_init_temp(0.1))
        llama_sampler_chain_add(chain, llama_sampler_init_greedy())
        return chain
    }

    deinit { unload() }
}

// MARK: - CactusBackend (stub)
//
// TODO: Implement when cactus-compute/cactus ships:
//   1. GGUF model loading (currently only .cact format)
//   2. Swift Package Manager Package.swift
// Swap CactusManager.backend = CactusBackend() to activate.

final class CactusBackend: InferenceBackend {
    var isLoaded: Bool { false }

    func load(at url: URL) async throws {
        throw InferenceError.backendUnavailable
    }

    func generate(prompt: String, maxTokens: Int) async throws -> String {
        throw InferenceError.backendUnavailable
    }

    func unload() {}
}

// MARK: - Extracted entities

struct ExtractedEntities {
    let entities: [(name: String, type: EntityType)]
    let relationships: [(subject: String, predicate: RelationshipType, object: String, offsetSeconds: Int?)]
    let rawSource: String
}

// MARK: - Abstracted Medical Brief

struct AbstractedMedicalBrief {
    let question: String
    let contextSummary: String
}

// MARK: - CactusManager
//
// Coordinates model lifecycle, download, and all inference calls.
// Delegates raw llama.cpp/Cactus calls to `backend` (InferenceBackend).
// To swap backends at runtime: manager.switchBackend(CactusBackend())

@MainActor
final class CactusManager: ObservableObject {
    static let shared = CactusManager()

    @Published var isModelLoaded = false
    @Published var currentMode: InferenceMode = .onDevice

    enum DownloadState: Equatable {
        case downloading(Double)
        case installing
        case failed
    }

    @Published var downloadStates: [String: DownloadState] = [:]
    @Published var activeModel: OnDeviceModel?

    // Active inference backend. Default: llama.cpp.
    // Replace with CactusBackend() once Cactus supports GGUF + SPM.
    private var backend: any InferenceBackend = LlamaCppBackend()

    private static let activeModelKey = "activeModelID"

    private let modelsDirectory: URL = {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DAWQ/Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    // MARK: - Backend swap

    /// Hot-swap the inference backend. Unloads the current backend first.
    func switchBackend(_ newBackend: any InferenceBackend) {
        backend.unload()
        backend = newBackend
        isModelLoaded = false
        log.info("CactusManager: backend switched to \(type(of: newBackend))")
    }

    // MARK: - Model lifecycle

    func download(_ model: OnDeviceModel) async {
        downloadStates[model.id] = .downloading(0.0)
        log.info("download: model='\(model.displayName)' url=\(model.downloadURL)")

        let destURL = modelsDirectory.appendingPathComponent(model.ggufFilename)
        log.info("download: dest=\(destURL.path)")

        if FileManager.default.fileExists(atPath: destURL.path) {
            let attrs = try? FileManager.default.attributesOfItem(atPath: destURL.path)
            let sizeBytes = attrs?[.size] as? Int ?? 0
            log.info("download: file on disk, size=\(sizeBytes) bytes (\(sizeBytes / 1_048_576) MB)")
            if isValidGGUF(at: destURL) {
                log.info("download: existing file is valid GGUF — loading…")
                downloadStates[model.id] = .installing
                do {
                    try await backend.load(at: destURL)
                    isModelLoaded = backend.isLoaded
                    if isModelLoaded {
                        UserDefaults.standard.set(model.id, forKey: Self.activeModelKey)
                        activeModel = model
                    }
                } catch {
                    log.error("download: load failed on existing file \(error) — deleting")
                    try? FileManager.default.removeItem(at: destURL)
                    downloadStates[model.id] = .failed
                    return
                }
                downloadStates.removeValue(forKey: model.id)
                return
            } else {
                log.warning("download: existing file failed GGUF magic check — deleting, re-download")
                try? FileManager.default.removeItem(at: destURL)
                UserDefaults.standard.removeObject(forKey: Self.activeModelKey)
            }
        } else {
            log.info("download: no file on disk — starting network download")
        }

        guard let url = URL(string: model.downloadURL) else {
            downloadStates[model.id] = .failed
            return
        }

        do {
            try await streamDownload(from: url, to: destURL, modelID: model.id)
            let attrs = try? FileManager.default.attributesOfItem(atPath: destURL.path)
            let sizeBytes = attrs?[.size] as? Int ?? 0
            log.info("download: stream complete, size=\(sizeBytes) bytes (\(sizeBytes / 1_048_576) MB)")

            let valid = isValidGGUF(at: destURL)
            log.info("download: post-download GGUF magic valid=\(valid)")
            guard valid else {
                log.error("download: downloaded file is not valid GGUF — aborting")
                try? FileManager.default.removeItem(at: destURL)
                downloadStates[model.id] = .failed
                return
            }

            downloadStates[model.id] = .installing
            log.info("download: loading downloaded model…")
            try await backend.load(at: destURL)
            isModelLoaded = backend.isLoaded
            if isModelLoaded {
                UserDefaults.standard.set(model.id, forKey: Self.activeModelKey)
                activeModel = model
                log.info("download: complete ✓ isModelLoaded=true")
            }
            downloadStates.removeValue(forKey: model.id)
        } catch {
            log.error("download: failed \(error)")
            downloadStates[model.id] = .failed
        }
    }

    /// GGUF files start with 4 magic bytes: 0x47 0x47 0x55 0x46 ("GGUF")
    private func isValidGGUF(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let magic = handle.readData(ofLength: 4)
        return magic == Data([0x47, 0x47, 0x55, 0x46])
    }

    func hasInstalledValidModel(_ model: OnDeviceModel) -> Bool {
        let ggufPath = modelsDirectory.appendingPathComponent(model.ggufFilename)
        return FileManager.default.fileExists(atPath: ggufPath.path) && isValidGGUF(at: ggufPath)
    }

    func selectInstalledModel(_ model: OnDeviceModel) async {
        guard hasInstalledValidModel(model) else { return }
        let ggufPath = modelsDirectory.appendingPathComponent(model.ggufFilename)
        do {
            try await backend.load(at: ggufPath)
            isModelLoaded = backend.isLoaded
            if isModelLoaded {
                activeModel = model
                UserDefaults.standard.set(model.id, forKey: Self.activeModelKey)
            }
        } catch {
            log.error("selectInstalledModel: load failed \(error)")
            isModelLoaded = false
            activeModel = nil
        }
    }

    func restoreActiveModel() async {
        guard let id = UserDefaults.standard.string(forKey: Self.activeModelKey),
              let model = OnDeviceModel.available.first(where: { $0.id == id }) else {
            log.info("restoreActiveModel: no saved model ID in UserDefaults")
            return
        }
        let ggufPath = modelsDirectory.appendingPathComponent(model.ggufFilename)
        log.info("restoreActiveModel: checking \(ggufPath.path)")

        let exists = FileManager.default.fileExists(atPath: ggufPath.path)
        log.info("restoreActiveModel: file exists=\(exists)")
        guard exists else {
            log.warning("restoreActiveModel: file missing — clearing stale key")
            UserDefaults.standard.removeObject(forKey: Self.activeModelKey)
            return
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: ggufPath.path)
        let sizeBytes = attrs?[.size] as? Int ?? 0
        log.info("restoreActiveModel: file size=\(sizeBytes) bytes (\(sizeBytes / 1_048_576) MB)")

        let valid = isValidGGUF(at: ggufPath)
        log.info("restoreActiveModel: GGUF magic valid=\(valid)")
        guard valid else {
            log.warning("restoreActiveModel: invalid GGUF — clearing stale key")
            UserDefaults.standard.removeObject(forKey: Self.activeModelKey)
            return
        }

        do {
            log.info("restoreActiveModel: loading '\(model.displayName)'")
            try await backend.load(at: ggufPath)
            isModelLoaded = backend.isLoaded
            if isModelLoaded {
                activeModel = model
                log.info("restoreActiveModel: loaded ✓")
            } else {
                activeModel = nil
                log.error("restoreActiveModel: load returned but isLoaded=false")
            }
        } catch {
            activeModel = nil
            isModelLoaded = false
            log.error("restoreActiveModel: load threw \(error) — clearing stale key")
            UserDefaults.standard.removeObject(forKey: Self.activeModelKey)
        }
    }

    func ensureDefaultModelReady() async {
        log.info("ensureDefaultModelReady: start, isModelLoaded=\(self.isModelLoaded)")

        await restoreActiveModel()

        if isModelLoaded {
            log.info("ensureDefaultModelReady: model already loaded after restore ✓")
            return
        }

        let model = OnDeviceModel.primary
        let ggufPath = modelsDirectory.appendingPathComponent(model.ggufFilename)
        log.info("ensureDefaultModelReady: primary model='\(model.displayName)' path=\(ggufPath.path)")

        let exists = FileManager.default.fileExists(atPath: ggufPath.path)
        log.info("ensureDefaultModelReady: file exists=\(exists)")

        if exists {
            let attrs = try? FileManager.default.attributesOfItem(atPath: ggufPath.path)
            let sizeBytes = attrs?[.size] as? Int ?? 0
            log.info("ensureDefaultModelReady: file size=\(sizeBytes) bytes (\(sizeBytes / 1_048_576) MB)")

            let valid = isValidGGUF(at: ggufPath)
            log.info("ensureDefaultModelReady: GGUF magic valid=\(valid)")

            if valid {
                do {
                    log.info("ensureDefaultModelReady: loading from disk…")
                    try await backend.load(at: ggufPath)
                    isModelLoaded = backend.isLoaded
                    if isModelLoaded {
                        activeModel = model
                        UserDefaults.standard.set(model.id, forKey: Self.activeModelKey)
                        log.info("ensureDefaultModelReady: loaded from disk ✓")
                        return
                    } else {
                        log.error("ensureDefaultModelReady: load completed but isLoaded=false")
                    }
                } catch {
                    // File has valid GGUF magic but backend rejected it (unsupported arch,
                    // wrong quant, OOM). Delete it so we download a compatible model.
                    log.error("ensureDefaultModelReady: load failed '\(error)' — deleting incompatible file")
                    try? FileManager.default.removeItem(at: ggufPath)
                    UserDefaults.standard.removeObject(forKey: Self.activeModelKey)
                }
            } else {
                log.warning("ensureDefaultModelReady: invalid GGUF on disk — deleting")
                try? FileManager.default.removeItem(at: ggufPath)
            }
        }

        log.info("ensureDefaultModelReady: downloading '\(model.displayName)'")
        await download(model)
        log.info("ensureDefaultModelReady: after download, isModelLoaded=\(self.isModelLoaded)")
    }

    // MARK: - Transcription

    func transcribe(audioFileURL: URL) async throws -> String {
        return try await SpeechTranscriber.shared.transcribe(audioFileURL: audioFileURL)
    }

    // MARK: - Entity extraction

    func extractEntities(from text: String) async throws -> ExtractedEntities {
        if isModelLoaded {
            let prompt = buildExtractionPrompt(text: text)
            let raw = try await backend.generate(prompt: prompt, maxTokens: 512)
            return parseExtractionResponse(raw, source: text)
        } else {
            return MedicalNLPFallback.extractEntities(from: text)
        }
    }

    // MARK: - Narrator

    func narrateCorrelation(_ correlation: CorrelationResult, interaction: String? = nil) async throws -> (text: String, mode: InferenceMode) {
        if isModelLoaded {
            let prompt = """
            Rephrase this SQL health result as one clear sentence. No medical advice. No new facts.

            Data: \(correlation.narrative)
            """
            let response = try await backend.generate(prompt: prompt, maxTokens: 128)
            return (response, currentMode)
        } else {
            return (correlation.narrative, .onDevice)
        }
    }

    // MARK: - Abstracted brief

    func generateAbstractedBrief(
        userQuestion: String,
        profile: UserHealthProfile,
        correlations: [CorrelationResult]
    ) async throws -> AbstractedMedicalBrief {
        let summary = correlations.prefix(3).map(\.narrative).joined(separator: " ")
        let prompt = """
        De-identify this health query. Remove names, dates, doses. Keep patterns only.
        Question: \(userQuestion)
        Context: \(summary)
        Output starts with "User pattern:".
        """
        let abstract = isModelLoaded
            ? (try await backend.generate(prompt: prompt, maxTokens: 256))
            : "User pattern: \(userQuestion.prefix(100))"
        return AbstractedMedicalBrief(question: abstract, contextSummary: summary)
    }

    // MARK: - Daily digest

    func generateDailyDigest(logs: [HealthLog], date: Date) async throws -> String {
        let lines = logs.compactMap { log -> String? in
            var parts: [String] = []
            if let t = log.transcript { parts.append("Voice: \(t)") }
            if let hr = log.heartRateBpm { parts.append("HR: \(Int(hr))bpm") }
            if let s = log.sleepHours { parts.append("Sleep: \(String(format:"%.1f",s))h") }
            if let hrv = log.hrvMs { parts.append("HRV: \(Int(hrv))ms") }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        }.joined(separator: "\n")

        if isModelLoaded {
            let prompt = """
            Summarize these health log entries in 2-3 factual sentences. Note symptoms, meds, patterns. No medical advice.

            \(lines)
            """
            return try await backend.generate(prompt: prompt, maxTokens: 256)
        } else {
            return "Health data logged: \(logs.count) entries."
        }
    }

    // MARK: - Health Q&A (RAG-grounded)

    func answerQuery(
        question: String,
        healthContext: String,
        documentContext: String
    ) async throws -> (answer: String, mode: InferenceMode) {
        let contextBlocks = [
            healthContext.isEmpty ? nil : "Health data:\n\(healthContext)",
            documentContext.isEmpty ? nil : "Uploaded documents:\n\(documentContext)"
        ].compactMap { $0 }.joined(separator: "\n\n")

        let prompt: String
        if contextBlocks.isEmpty {
            prompt = """
            You are DAWQ, a private personal health assistant.
            The user has not connected data yet. Still answer as a normal helpful health companion:
            - Give practical wellness guidance in plain language
            - Ask 1-2 brief follow-up questions to personalize next
            - Never claim access to personal records you do not have
            - No diagnosis, no prescriptions, no emergency guarantees

            User question: \(question)
            Answer:
            """
        } else {
            prompt = """
            You are DAWQ, a private personal health assistant.
            Use verified context first, then explain clearly and briefly.
            If context is insufficient, say what is missing and suggest what to log/import next.
            No diagnosis or prescriptions.

            \(contextBlocks)

            User question: \(question)
            Answer:
            """
        }

        if isModelLoaded {
            let answer = try await backend.generate(prompt: prompt, maxTokens: 512)
            return (answer, currentMode)
        } else {
            let fallback = contextBlocks.isEmpty
                ? "I can help with general wellness questions, but your on-device model is still preparing. Tap the model button to download it."
                : "I found some context, but your on-device model is still preparing. Tap the model button to finish setup."
            return (fallback, .onDevice)
        }
    }

    // MARK: - Streaming download

    private func streamDownload(from url: URL, to dest: URL, modelID: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let task = URLSession.shared.downloadTask(with: url) { tempURL, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let http = response as? HTTPURLResponse,
                   !(200...299).contains(http.statusCode) {
                    if let message = http.value(forHTTPHeaderField: "x-error-message") {
                        log.error("download HTTP \(http.statusCode): \(message)")
                    } else {
                        log.error("download HTTP \(http.statusCode)")
                    }
                    continuation.resume(throwing: InferenceError.downloadFailed)
                    return
                }
                guard let tempURL else {
                    continuation.resume(throwing: InferenceError.downloadFailed)
                    return
                }
                do {
                    if FileManager.default.fileExists(atPath: dest.path) {
                        try FileManager.default.removeItem(at: dest)
                    }
                    try FileManager.default.moveItem(at: tempURL, to: dest)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }

            let observation = task.progress.observe(\.fractionCompleted) { progress, _ in
                Task { @MainActor [weak self] in
                    self?.downloadStates[modelID] = .downloading(progress.fractionCompleted)
                }
            }

            task.resume()
            let _ = observation
        }
    }

    // MARK: - Extraction prompt + parser

    private func buildExtractionPrompt(text: String) -> String {
        """
        Extract medical entities from the text below. Return ONLY a JSON array.
        Each item: {"name": string, "type": string, "relationships": [{"predicate": string, "object": string}]}
        Types: symptom, medication, condition, food, activity, measurement, emotion
        Predicates: STARTED, STOPPED, EXPERIENCED, CORRELATED_WITH, PRECEDED, FOLLOWED

        Text: "\(text)"

        JSON:
        """
    }

    private func parseExtractionResponse(_ response: String, source: String) -> ExtractedEntities {
        guard let start = response.firstIndex(of: "["),
              let end = response.lastIndex(of: "]"),
              start <= end else {
            return ExtractedEntities(entities: [], relationships: [], rawSource: source)
        }

        let json = String(response[start...end])
        guard let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return ExtractedEntities(entities: [], relationships: [], rawSource: source)
        }

        var entities: [(name: String, type: EntityType)] = []
        var relationships: [(subject: String, predicate: RelationshipType, object: String, offsetSeconds: Int?)] = []

        for item in array {
            guard let name = item["name"] as? String,
                  let typeStr = item["type"] as? String else { continue }
            entities.append((name: name, type: EntityType(rawValue: typeStr) ?? .unknown))

            for rel in (item["relationships"] as? [[String: String]]) ?? [] {
                guard let pred = rel["predicate"], let obj = rel["object"] else { continue }
                relationships.append((subject: name, predicate: RelationshipType(rawValue: pred) ?? .unknown, object: obj, offsetSeconds: nil))
            }
        }

        return ExtractedEntities(entities: entities, relationships: relationships, rawSource: source)
    }
}

// MARK: - Errors

enum InferenceError: Error {
    case modelNotLoaded
    case modelLoadFailed
    case tokenizationFailed
    case decodeFailed
    case downloadFailed
    case cloudRouteBlocked
    case backendUnavailable
}
