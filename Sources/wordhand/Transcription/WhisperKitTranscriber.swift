import Foundation
import WordhandCore
import WhisperKit

actor WhisperKitTranscriber: Transcribing {
    let modelID: String
    private let model: TranscriptionModel
    private var pipeline: WhisperKit?
    private var cancellationToken: TranscriptionCancellationToken?

    init(model: TranscriptionModel) {
        self.modelID = model.id
        self.model = model
    }

    /// Loads the model into memory; downloads first if not already on disk.
    /// Call once at startup so the first hotkey press isn't blocked on model
    /// download/load.
    func warmUp() async throws {
        if pipeline != nil { return }
        guard let whisperKitID = model.whisperKitID else {
            throw TranscriberError.missingEngineID
        }
        FileHandle.standardError.write(Data("loading \(model.id)...\n".utf8))
        let config = WhisperKitConfig(model: whisperKitID, verbose: false, prewarm: true, load: true)
        pipeline = try await WhisperKit(config)
        FileHandle.standardError.write(Data("✓ \(model.id) ready\n".utf8))
    }

    func transcribe(_ audio: [Float]) async throws -> String {
        if pipeline == nil { try await warmUp() }
        guard let pipeline else { throw TranscriberError.notLoaded }

        let token = TranscriptionCancellationToken()
        cancellationToken = token
        defer {
            if cancellationToken === token {
                cancellationToken = nil
            }
        }
        let results = try await pipeline.transcribe(
            audioArray: audio,
            callback: { _ in token.isCancelled ? false : nil }
        )
        return results.map(\.text).joined(separator: " ")
    }

    func cancel() {
        cancellationToken?.cancel()
    }
}

enum TranscriberError: Error {
    case missingEngineID
    case notLoaded
}

private final class TranscriptionCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
        }
    }
}
