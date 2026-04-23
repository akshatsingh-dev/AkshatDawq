import Foundation
import Speech
import AVFoundation

/// On-device speech transcription via SFSpeechRecognizer.
/// requiresOnDeviceRecognition = true — audio never leaves device.
/// Falls back to file-based transcription for nightly batch.
@MainActor
final class SpeechTranscriber: ObservableObject {
    static let shared = SpeechTranscriber()

    @Published var isAvailable = false
    @Published var authStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined

    private let recognizer: SFSpeechRecognizer?

    private init() {
        recognizer = SFSpeechRecognizer(locale: .current)
        recognizer?.defaultTaskHint = .dictation
        isAvailable = recognizer?.isAvailable ?? false
    }

    // MARK: - Auth

    func requestAuthorization() async {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                Task { @MainActor in
                    self.authStatus = status
                    continuation.resume()
                }
            }
        }
    }

    // MARK: - File transcription (used by nightly batch and voice log)

    func transcribe(audioFileURL: URL) async throws -> String {
        guard let recognizer, recognizer.isAvailable else {
            throw TranscriberError.unavailable
        }

        return try await withCheckedThrowingContinuation { continuation in
            let request = SFSpeechURLRecognitionRequest(url: audioFileURL)
            request.requiresOnDeviceRecognition = true   // never send audio to Apple servers
            request.addsPunctuation = true
            request.shouldReportPartialResults = false

            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let result, result.isFinal else { return }
                continuation.resume(returning: result.bestTranscription.formattedString)
            }
        }
    }

    // MARK: - Live streaming transcription (for real-time UI feedback)

    /// Returns an AsyncStream of partial transcripts while recording.
    func liveTranscriptionStream(
        audioEngine: AVAudioEngine,
        inputNode: AVAudioInputNode
    ) -> (AsyncStream<String>, SFSpeechAudioBufferRecognitionRequest) {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = true
        request.shouldReportPartialResults = true

        let stream = AsyncStream<String> { continuation in
            let task = recognizer?.recognitionTask(with: request) { result, error in
                if let result {
                    continuation.yield(result.bestTranscription.formattedString)
                    if result.isFinal { continuation.finish() }
                }
                if error != nil { continuation.finish() }
            }

            continuation.onTermination = { _ in task?.cancel() }
        }

        return (stream, request)
    }
}

enum TranscriberError: LocalizedError {
    case unavailable
    case authDenied

    var errorDescription: String? {
        switch self {
        case .unavailable: return "On-device speech recognition unavailable on this device."
        case .authDenied: return "Microphone or speech recognition permission denied."
        }
    }
}
