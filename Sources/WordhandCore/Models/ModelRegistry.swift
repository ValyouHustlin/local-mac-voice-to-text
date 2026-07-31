import Foundation

public enum ModelRegistry {
    public static let shared: [TranscriptionModel] = [
        TranscriptionModel(
            id: "parakeet-unified-en-0.6b",
            displayName: "Parakeet Unified (Fast English)",
            engine: .parakeet,
            whisperKitID: nil,
            sizeMB: 586,
            languages: ["en"],
            recommended: false
        ),
        TranscriptionModel(
            id: "whisper-base.en",
            displayName: "Whisper Base (English)",
            engine: .whisperKit,
            whisperKitID: "openai_whisper-base.en",
            sizeMB: 145,
            languages: ["en"],
            recommended: false
        ),
        TranscriptionModel(
            id: "whisper-large-v3",
            displayName: "Whisper Large v3 (Accuracy)",
            engine: .whisperKit,
            whisperKitID: "openai_whisper-large-v3-v20240930_626MB",
            sizeMB: 626,
            languages: ["multi"],
            recommended: true
        ),
        TranscriptionModel(
            id: "whisper-large-v3-turbo",
            displayName: "Whisper Large v3 Turbo (Balanced)",
            engine: .whisperKit,
            whisperKitID: "openai_whisper-large-v3-v20240930_turbo_632MB",
            sizeMB: 632,
            languages: ["multi"],
            recommended: false
        ),
        TranscriptionModel(
            id: "whisper-small.en",
            displayName: "Whisper Small (English)",
            engine: .whisperKit,
            whisperKitID: "openai_whisper-small.en",
            sizeMB: 488,
            languages: ["en"],
            recommended: false
        ),
    ]

    public static func find(_ id: String) -> TranscriptionModel? {
        shared.first { $0.id == id }
    }

    public static func recommended() -> TranscriptionModel? {
        shared.first { $0.recommended } ?? shared.first
    }
}
