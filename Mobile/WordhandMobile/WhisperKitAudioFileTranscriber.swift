import Foundation
import WhisperKit
import WordhandCore

actor WhisperKitAudioFileTranscriber: AudioFileTranscribing {
    static let modelID = "openai_whisper-large-v3-v20240930_626MB"

    let engineID = "whisperkit-large-v3-626mb"
    private let allowModelDownload: Bool
    private var pipeline: WhisperKit?

    init(allowModelDownload: Bool) {
        self.allowModelDownload = allowModelDownload
    }

    func transcribe(
        audioFileURL: URL,
        localeIdentifier: String
    ) async throws -> AudioFileTranscription {
        let pipeline = try await loadedPipeline()
        let startedAt = ProcessInfo.processInfo.systemUptime
        let results = try await pipeline.transcribe(audioPath: audioFileURL.path)
        let text = results.map(\.text).joined(separator: " ")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OnDeviceSpeechError.noFinalResult
        }
        return AudioFileTranscription(
            text: text,
            engineID: engineID,
            localeIdentifier: localeIdentifier,
            transcriptionDuration: ProcessInfo.processInfo.systemUptime - startedAt
        )
    }

    private func loadedPipeline() async throws -> WhisperKit {
        if let pipeline {
            return pipeline
        }
        let config = WhisperKitConfig(
            model: Self.modelID,
            verbose: false,
            prewarm: true,
            load: true,
            download: allowModelDownload,
            useBackgroundDownloadSession: true
        )
        let loaded = try await WhisperKit(config)
        pipeline = loaded
        return loaded
    }
}
