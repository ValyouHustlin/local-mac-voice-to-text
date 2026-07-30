import Foundation
import WordhandCore
import WhisperKit

actor WhisperKitTranscriber: Transcribing, StreamingTranscribing {
    let modelID: String
    private let model: TranscriptionModel
    private let vocabulary: DictionaryVocabularySource
    private var pipeline: WhisperKit?
    private var warmupTask: Task<Void, Error>?
    private var cachedPromptTokenization: (prompt: String?, tokens: [Int]?)?
    private var cancellationToken: TranscriptionCancellationToken?
    private var streamingSessionID: UUID?
    private var streamingConfiguration = StreamingTranscriptionConfiguration()
    private var streamingAudio: [Float] = []
    private var streamingStartSample = 0
    private var streamingLastDecodeSample = 0
    private var streamingCommittedText: [String] = []
    private var streamingInferenceDuration: TimeInterval = 0
    private var streamingStabilizer = StreamingTranscriptStabilizer()
    private var streamingDecodeTask: Task<Void, Never>?
    private var streamingFailure: Error?
    private var streamingIsFinishing = false

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
        let results = try await pipeline.transcribe(
            audioArray: audio,
            decodeOptions: decodingOptions(for: pipeline),
            callback: { _ in token.isCancelled ? false : nil }
        )
        return results.map(\.text).joined(separator: " ")
    }

    func beginStreaming(
        configuration: StreamingTranscriptionConfiguration
    ) async {
        await resetStreamingState(cancelTask: true)
        streamingSessionID = UUID()
        streamingConfiguration = configuration
        streamingStabilizer = StreamingTranscriptStabilizer(
            correctionHorizonSegments: configuration.correctionHorizonSegments
        )
    }

    func appendStreamingAudio(_ samples: [Float]) async {
        guard streamingSessionID != nil, !samples.isEmpty else { return }
        streamingAudio.append(contentsOf: samples)
        scheduleStreamingDecodeIfNeeded()
    }

    func finishStreaming(
        finalAudio: [Float]
    ) async throws -> StreamingTranscriptionResult {
        let finalizationStarted = ProcessInfo.processInfo.systemUptime
        streamingIsFinishing = true
        defer { clearStreamingState() }
        if let task = streamingDecodeTask {
            // A rolling decode only improves perceived progress while speech is
            // continuing. Once the user stops, it is stale work: cancel it so
            // the authoritative full-buffer decode can begin immediately.
            task.cancel()
            await task.value
        }
        streamingDecodeTask = nil
        streamingAudio = finalAudio

        // Rolling windows reduce perceived latency while the user speaks, but
        // their segment timestamps are local to each window. Joining committed
        // windows to a decoded remainder can therefore skip speech at a
        // boundary or leak decoder control tokens. Treat the complete captured
        // buffer as the only authoritative final transcript.
        let decodeStarted = ProcessInfo.processInfo.systemUptime
        let text = try await transcribe(finalAudio)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        streamingInferenceDuration +=
            ProcessInfo.processInfo.systemUptime - decodeStarted
        let result = StreamingTranscriptionResult(
            text: text,
            totalInferenceDuration: streamingInferenceDuration,
            finalizationDuration:
                ProcessInfo.processInfo.systemUptime - finalizationStarted
        )
        return result
    }

    func cancelStreaming() async {
        await resetStreamingState(cancelTask: true)
    }

    func cancel() {
        cancellationToken?.cancel()
    }

    private func scheduleStreamingDecodeIfNeeded() {
        guard
            let sessionID = streamingSessionID,
            streamingDecodeTask == nil,
            streamingFailure == nil,
            !streamingIsFinishing
        else {
            return
        }
        let intervalSamples = Int(
            streamingConfiguration.decodeIntervalSeconds * Double(WhisperKit.sampleRate)
        )
        guard streamingAudio.count - streamingLastDecodeSample >= intervalSamples else {
            return
        }
        streamingDecodeTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.decodeStreamingWindow(sessionID: sessionID)
        }
    }

    private func decodeStreamingWindow(sessionID: UUID) async {
        guard
            streamingSessionID == sessionID,
            streamingFailure == nil
        else {
            streamingDecodeTask = nil
            return
        }
        let maximumWindowSamples = Int(
            streamingConfiguration.maximumWindowSeconds * Double(WhisperKit.sampleRate)
        )
        let windowEnd = min(
            streamingAudio.count,
            streamingStartSample + maximumWindowSamples
        )
        guard windowEnd > streamingStartSample else {
            streamingDecodeTask = nil
            return
        }
        streamingLastDecodeSample = windowEnd
        let window = Array(streamingAudio[streamingStartSample..<windowEnd])
        let decodeStarted = ProcessInfo.processInfo.systemUptime

        do {
            let transcription = try await transcribeWindow(window)
            streamingInferenceDuration +=
                ProcessInfo.processInfo.systemUptime - decodeStarted
            guard streamingSessionID == sessionID else {
                streamingDecodeTask = nil
                return
            }
            let segments = transcription.segments.map {
                StreamingTranscriptSegment(
                    text: $0.text,
                    startSeconds: Double($0.start),
                    endSeconds: Double($0.end)
                )
            }
            let update = streamingStabilizer.observe(segments)
            let reachedWindowLimit = window.count >= maximumWindowSamples
            let confirmed = !update.newlyConfirmed.isEmpty
                ? update.newlyConfirmed
                : (reachedWindowLimit ? update.agreed : [])
            if let last = confirmed.last {
                let text = confirmed
                    .map(\.text)
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    streamingCommittedText.append(text)
                }
                let confirmedSamples = max(
                    1,
                    Int(last.endSeconds * Double(WhisperKit.sampleRate))
                )
                streamingStartSample = min(
                    windowEnd,
                    streamingStartSample + confirmedSamples
                )
                streamingStabilizer.reset()
            }
        } catch {
            streamingInferenceDuration +=
                ProcessInfo.processInfo.systemUptime - decodeStarted
            streamingFailure = error
        }

        streamingDecodeTask = nil
        scheduleStreamingDecodeIfNeeded()
    }

    private struct WindowTranscription {
        var text: String
        var segments: [TranscriptionSegment]
    }

    private func transcribeWindow(
        _ audio: [Float]
    ) async throws -> WindowTranscription {
        if pipeline == nil { try await warmUp() }
        guard let pipeline else { throw TranscriberError.notLoaded }
        let results = try await pipeline.transcribe(
            audioArray: audio,
            decodeOptions: decodingOptions(for: pipeline),
            callback: { _ in Task.isCancelled ? false : nil }
        )
        return WindowTranscription(
            text: results.map(\.text).joined(separator: " "),
            segments: results.flatMap(\.segments)
        )
    }

    private func decodingOptions(for pipeline: WhisperKit) -> DecodingOptions {
        let prompt = vocabulary.prompt()?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let cachedPromptTokenization,
           cachedPromptTokenization.prompt == prompt
        {
            return Self.makeDecodingOptions(
                promptTokens: cachedPromptTokenization.tokens
            )
        }

        guard let prompt else {
            cachedPromptTokenization = (nil, nil)
            return Self.makeDecodingOptions(promptTokens: nil)
        }
        guard let tokenizer = pipeline.tokenizer else {
            // A pipeline can briefly exist before its tokenizer is published.
            // Do not cache this miss or vocabulary conditioning would remain
            // disabled for the rest of the process.
            return Self.makeDecodingOptions(promptTokens: nil)
        }

        var promptTokens: [Int]?
        // Whisper tokenizers add special tokens by default. Prompt
        // conditioning accepts only ordinary text tokens and, like
        // WhisperKit's own CLI, needs a leading space for word boundaries.
        let encoded = tokenizer
            .encode(text: " " + prompt)
            .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        if !encoded.isEmpty {
            promptTokens = encoded
        }
        cachedPromptTokenization = (prompt, promptTokens)
        return Self.makeDecodingOptions(promptTokens: promptTokens)
    }

    static func makeDecodingOptions(promptTokens: [Int]?) -> DecodingOptions {
        DecodingOptions(
            promptTokens: promptTokens,
            chunkingStrategy: .vad
        )
    }

    private func resetStreamingState(cancelTask: Bool) async {
        streamingIsFinishing = true
        if cancelTask {
            streamingDecodeTask?.cancel()
            if let task = streamingDecodeTask {
                await task.value
            }
        }
        clearStreamingState()
    }

    private func clearStreamingState() {
        streamingDecodeTask = nil
        streamingSessionID = nil
        streamingAudio = []
        streamingStartSample = 0
        streamingLastDecodeSample = 0
        streamingCommittedText = []
        streamingInferenceDuration = 0
        streamingFailure = nil
        streamingIsFinishing = false
        streamingStabilizer.reset()
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
