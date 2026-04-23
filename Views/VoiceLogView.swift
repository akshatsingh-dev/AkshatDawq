import SwiftUI
import AVFoundation
import Speech

/// Voice logging UI — records audio, transcribes via SFSpeechRecognizer on-device,
/// writes HealthLog to SQLite. Raw audio is NEVER persisted.
/// Transcript is cleared after nightly entity extraction.
@MainActor
struct VoiceLogView: View {
    @State private var isRecording = false
    @State private var transcript = ""
    @State private var partialTranscript = ""   // live text while recording
    @State private var recordingError: String?
    @State private var savedConfirmation = false

    // AVAudio
    @State private var audioEngine = AVAudioEngine()
    @State private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @State private var audioFile: AVAudioFile?
    @State private var tempAudioURL: URL?
    @State private var recognitionTask: Task<Void, Never>?

    @StateObject private var transcriber = SpeechTranscriber.shared
    @StateObject private var cactus = CactusManager.shared

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                ProvenanceBadge(mode: .onDevice)

                // Model not loaded warning
                if !cactus.isModelLoaded {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("No model loaded — entity extraction will be skipped. Download a model in Profile.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal)
                }

                // Mic button
                Button {
                    Task { await toggleRecording() }
                } label: {
                    ZStack {
                        // Pulse ring when recording
                        if isRecording {
                            Circle()
                                .stroke(.red.opacity(0.3), lineWidth: 2)
                                .frame(width: 96, height: 96)
                                .scaleEffect(isRecording ? 1.2 : 1.0)
                                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isRecording)
                        }
                        Circle()
                            .fill(isRecording ? .red : .primary)
                            .frame(width: 80, height: 80)
                        Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.white)
                    }
                }
                .scaleEffect(isRecording ? 1.05 : 1.0)
                .animation(.easeInOut(duration: 0.2), value: isRecording)

                Text(isRecording ? "Tap to stop" : "Tap to record")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                // Live partial transcript
                if isRecording && !partialTranscript.isEmpty {
                    Text(partialTranscript)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .italic()
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .transition(.opacity)
                }

                // Final transcript + save
                if !transcript.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Transcript")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Clear") {
                                withAnimation { transcript = "" }
                            }
                            .font(.caption)
                            .foregroundStyle(.red)
                        }

                        Text(transcript)
                            .font(.body)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .padding(.horizontal)

                    Button {
                        Task { await saveLog() }
                    } label: {
                        Label("Save to Health Log", systemImage: "checkmark.circle.fill")
                            .font(.body.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(.primary, in: RoundedRectangle(cornerRadius: 14))
                            .foregroundStyle(Color(uiColor: .systemBackground))
                    }
                    .padding(.horizontal)
                }

                if let error = recordingError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                        .multilineTextAlignment(.center)
                }

                if savedConfirmation {
                    Label("Saved. DAWQ extracts insights tonight.", systemImage: "moon.stars.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }

                Spacer()
            }
            .navigationTitle("Log")
            .navigationBarTitleDisplayMode(.large)
            .task {
                await transcriber.requestAuthorization()
            }
        }
    }

    // MARK: - Recording with live transcription

    private func toggleRecording() async {
        if isRecording {
            stopRecording()
        } else {
            await startRecording()
        }
    }

    private func startRecording() async {
        if transcriber.authStatus != .authorized {
            await transcriber.requestAuthorization()
            guard transcriber.authStatus == .authorized else {
                recordingError = "Speech recognition permission required."
                return
            }
        }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            recordingError = "Audio session error: \(error.localizedDescription)"
            return
        }

        // Set up temp file for audio (deleted after transcription)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        tempAudioURL = url

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        // Prepare recognition request
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = true
        request.shouldReportPartialResults = true
        recognitionRequest = request

        // Tap microphone — feed both recognition and file
        do {
            let fileFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!
            audioFile = try AVAudioFile(forWriting: url, settings: fileFormat.settings)
        } catch {
            recordingError = "Could not create audio file: \(error.localizedDescription)"
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [self] buffer, _ in
            request.append(buffer)
        }

        do {
            try audioEngine.start()
        } catch {
            recordingError = "Audio engine error: \(error.localizedDescription)"
            return
        }

        isRecording = true
        partialTranscript = ""
        recordingError = nil

        // Consume live partial results
        let recognizer = SFSpeechRecognizer(locale: .current)
        recognitionTask = Task {
            guard let recognizer else { return }
            for await result in recognizer.recognitionResults(for: request) {
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    partialTranscript = result.bestTranscription.formattedString
                }
                if result.isFinal { break }
            }
        }
    }

    private func stopRecording() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()

        isRecording = false
        audioFile = nil

        // Use the final partial transcript as the confirmed transcript
        if !partialTranscript.isEmpty {
            transcript = partialTranscript
            partialTranscript = ""
        }

        // Clean up temp audio — never persist raw audio
        if let url = tempAudioURL {
            try? FileManager.default.removeItem(at: url)
            tempAudioURL = nil
        }
    }

    // MARK: - Save

    private func saveLog() async {
        guard !transcript.isEmpty else { return }

        var log = HealthLog(
            source: .voice,
            transcript: transcript,
            rawText: nil,
            processingStatus: .pending,
            extractedAt: nil,
            createdAt: Date()
        )

        do {
            _ = try DatabaseManager.shared.write { try log.insert($0) }
            transcript = ""
            withAnimation { savedConfirmation = true }
            try? await Task.sleep(for: .seconds(3))
            withAnimation { savedConfirmation = false }
        } catch {
            recordingError = "Save failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - SFSpeechRecognizer AsyncSequence extension

extension SFSpeechRecognizer {
    func recognitionResults(for request: SFSpeechAudioBufferRecognitionRequest) -> AsyncStream<SFSpeechRecognitionResult> {
        AsyncStream { continuation in
            let task = recognitionTask(with: request) { result, error in
                if let result { continuation.yield(result) }
                if error != nil || result?.isFinal == true { continuation.finish() }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
