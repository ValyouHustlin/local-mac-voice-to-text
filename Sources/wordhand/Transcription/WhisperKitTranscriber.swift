import Foundation
import WordhandCore
import WhisperKit

actor WhisperKitTranscriber: Transcribing {
    let modelID: String
    private let model: TranscriptionModel
    private let vocabulary: DictionaryVocabularySource
    private var pipeline: WhisperKit?
    private var warmupTask: Task<Void, Error>?
    private var cancellationToken: TranscriptionCancellationToken?

    init(
        model: TranscriptionModel,
        vocabulary: DictionaryVocabularySource = DictionaryVocabularySource()
    ) {
        self.modelID = model.id
        self.model = model
        self.vocabulary = vocabulary
    }

    /// Loads the model into memory; downloads first if not already on disk.
    /// Call once at startup so the first hotkey press isn't blocked on model
    /// download/load.
    func warmUp() async throws {
        if pipeline != nil { return }
        if let warmupTask {
            try await warmupTask.value
            return
        }
        guard let whisperKitID = model.whisperKitID else {
            throw TranscriberError.missingEngineID
        }
        let warmupStarted = ProcessInfo.processInfo.systemUptime
        FileHandle.standardError.write(Data("loading \(model.id)...\n".utf8))
        let task = Task {
            let downloadBase = WhisperModelStorage.defaultDownloadBase()
            let localModelFolder = WhisperModelStorage.localModelFolder(
                modelID: whisperKitID,
                downloadBase: downloadBase
            )
            let config: WhisperKitConfig
            if let localModelFolder {
                FileHandle.standardError.write(Data(
                    "using cached local model; network disabled\n".utf8
                ))
                config = WhisperKitConfig(
                    downloadBase: downloadBase,
                    modelFolder: localModelFolder.path,
                    tokenizerFolder: downloadBase,
                    textDecoder: PromptSafeTextDecoder(),
                    verbose: false,
                    prewarm: true,
                    load: true,
                    download: false
                )
            } else {
                config = WhisperKitConfig(
                    model: whisperKitID,
                    downloadBase: downloadBase,
                    textDecoder: PromptSafeTextDecoder(),
                    verbose: false,
                    prewarm: true,
                    load: true,
                    download: true
                )
            }
            pipeline = try await WhisperKit(config)
        }
        warmupTask = task
        do {
            try await task.value
            warmupTask = nil
            let elapsed = ProcessInfo.processInfo.systemUptime - warmupStarted
            FileHandle.standardError.write(Data(
                String(format: "✓ %@ ready in %.2fs\n", model.id, elapsed).utf8
            ))
        } catch {
            warmupTask = nil
            throw error
        }
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
        let decodingOptions: DecodingOptions?
        if let prompt = vocabulary.prompt(),
           let tokenizer = pipeline.tokenizer
        {
            // Whisper tokenizers add special tokens by default. Prompt
            // conditioning accepts only ordinary text tokens and, like
            // WhisperKit's own CLI, needs a leading space for word boundaries.
            let promptTokens = tokenizer
                .encode(text: " " + prompt.trimmingCharacters(in: .whitespaces))
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            decodingOptions = promptTokens.isEmpty
                ? nil
                : DecodingOptions(promptTokens: promptTokens)
        } else {
            decodingOptions = nil
        }

        let results = try await pipeline.transcribe(
            audioArray: audio,
            decodeOptions: decodingOptions,
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
