import SwiftUI

/// On-device GGUF models downloaded from HuggingFace via llama.cpp.
/// Stored in app's private Application Support — never uploaded, never iCloud-synced.
struct OnDeviceModel: Identifiable, Equatable {
    let id: String
    let displayName: String
    let paramCount: String
    let sizeGB: String
    let speedLabel: String
    let icon: String
    let accentColor: Color
    let isRecommended: Bool
    let isNew: Bool
    /// Direct HuggingFace GGUF download URL
    let downloadURL: String
    /// Local filename (stored in DAWQ/Models/)
    let ggufFilename: String

    static let available: [OnDeviceModel] = [
        OnDeviceModel(
            id: "gemma3-4b-q4km",
            displayName: "Gemma 3 4B",
            paramCount: "4.3B",
            sizeGB: "2.5",
            speedLabel: "Balanced · Best for medical",
            icon: "sparkles",
            accentColor: .blue,
            isRecommended: true,
            isNew: false,
            downloadURL: "https://huggingface.co/lmstudio-community/gemma-3-4b-it-GGUF/resolve/main/gemma-3-4b-it-Q4_K_M.gguf",
            ggufFilename: "gemma-3-4b-it-Q4_K_M.gguf"
        ),
        OnDeviceModel(
            id: "phi35-mini-q4km",
            displayName: "Phi-3.5 Mini",
            paramCount: "3.8B",
            sizeGB: "2.2",
            speedLabel: "Fast",
            icon: "bolt.fill",
            accentColor: .purple,
            isRecommended: false,
            isNew: false,
            downloadURL: "https://huggingface.co/bartowski/Phi-3.5-mini-instruct-GGUF/resolve/main/Phi-3.5-mini-instruct-Q4_K_M.gguf",
            ggufFilename: "Phi-3.5-mini-instruct-Q4_K_M.gguf"
        ),
        OnDeviceModel(
            id: "llama32-3b-q4km",
            displayName: "Llama 3.2 3B",
            paramCount: "3.2B",
            sizeGB: "1.8",
            speedLabel: "Fastest",
            icon: "hare.fill",
            accentColor: .orange,
            isRecommended: false,
            isNew: false,
            downloadURL: "https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf",
            ggufFilename: "Llama-3.2-3B-Instruct-Q4_K_M.gguf"
        ),
    ]

    /// Single default model for streamlined UX.
    static var primary: OnDeviceModel {
        available.first(where: \.isRecommended) ?? available[0]
    }
}
