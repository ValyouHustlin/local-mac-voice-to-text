import Foundation

public enum HotkeyEvent: Equatable, Sendable {
    case pressed
    case released
}

public enum DictationFailure: Equatable, Sendable {
    case capture(String)
    case transcription(String)
    case history(String)
    case historyStatus(String)
    case insertion(String)
}

public enum DictationState: Equatable, Sendable {
    case idle
    case recording
    case transcribing
    case processing
    case inserting
    case failed(DictationFailure)
}

public protocol AudioCapturing: AnyObject {
    func start() throws
    func stop() async -> [Float]
}

public protocol HotkeyMonitoring: AnyObject {
    func start(onEvent: @escaping (HotkeyEvent) -> Void) throws
    func stop()
}

public protocol Transcribing: Sendable {
    var modelID: String { get }
    func warmUp() async throws
    func transcribe(_ audio: [Float]) async throws -> String
    func cancel() async
}

public extension Transcribing {
    func cancel() async {}
}

public protocol TranscriptProcessing: Sendable {
    func process(_ text: String, target: TranscriptTarget) async -> String
}

public protocol TextInserting: Sendable {
    func insert(_ text: String, mode: InsertionMode) async throws
}

@MainActor
public final class DictationCoordinator {
    public private(set) var state: DictationState = .idle {
        didSet { onStateChange?(state) }
    }

    public var onStateChange: ((DictationState) -> Void)?
    public var onCapture: (([Float]) -> Void)?
    public var onTranscript: ((String, TimeInterval) -> Void)?
    public var onQualityAudio: ((QualityAudioSample) -> Void)?
    public var onProcessingDuration: ((TimeInterval) -> Void)?
    public var onStreamingFinalizationDuration: ((TimeInterval) -> Void)?
    public var onHistoryChange: (() -> Void)?
    public var onRecordingLimitReached: (() -> Void)?

    private let capture: AudioCapturing
    private let transcriber: Transcribing
    private let processor: TranscriptProcessing
    private let inserter: TextInserting
    private let history: TranscriptRecording?
    private var insertionMode: InsertionMode
    private var streamingEnabled: Bool
    private let language: String?
    private let audioSampleRate: Double
    private let currentTarget: () -> TranscriptTarget
    private let date: () -> Date
    private let now: () -> TimeInterval
    private let maximumCaptureGapSeconds: TimeInterval
    private let maximumRecordingNanoseconds: UInt64?
    private let sleep: @Sendable (UInt64) async throws -> Void
    private var activeOperationID: UUID?
    private var isCaptureStopping = false
    private var recordingLimitTask: Task<Void, Never>?
    private var activeStreamingCapture: (any StreamingAudioCapturing)?
    private var activeStreamingTranscriber: (any StreamingTranscribing)?
    private var streamingAudioContinuation: AsyncStream<[Float]>.Continuation?
    private var streamingForwardingTask: Task<Void, Never>?
    private var recordingStartedAt: TimeInterval?

    public init(
        capture: AudioCapturing,
        transcriber: Transcribing,
        processor: TranscriptProcessing,
        inserter: TextInserting,
        history: TranscriptRecording? = nil,
        insertionMode: InsertionMode = .unicode,
        streamingEnabled: Bool = false,
        language: String? = nil,
        audioSampleRate: Double = 16_000,
        currentTarget: @escaping () -> TranscriptTarget = { .unknown },
        date: @escaping () -> Date = Date.init,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        maximumCaptureGapSeconds: TimeInterval = 0.75,
        maximumRecordingNanoseconds: UInt64? = 600_000_000_000,
        sleep: @escaping @Sendable (UInt64) async throws -> Void = {
            try await Task.sleep(nanoseconds: $0)
        }
    ) {
        self.capture = capture
        self.transcriber = transcriber
        self.processor = processor
        self.inserter = inserter
        self.history = history
        self.insertionMode = insertionMode
        self.streamingEnabled = streamingEnabled
        self.language = language
        self.audioSampleRate = audioSampleRate
        self.currentTarget = currentTarget
        self.date = date
        self.now = now
        self.maximumCaptureGapSeconds = maximumCaptureGapSeconds
        self.maximumRecordingNanoseconds = maximumRecordingNanoseconds
        self.sleep = sleep
    }

    public func handle(_ event: HotkeyEvent) async {
        switch event {
        case .pressed:
            if case .failed = state {
                state = .idle
            }
            guard state == .idle else { return }
            do {
                if streamingEnabled,
                   let streamingCapture = capture as? any StreamingAudioCapturing,
                   let streamingTranscriber = transcriber as? any StreamingTranscribing
                {
                    await streamingTranscriber.beginStreaming(
                        configuration: StreamingTranscriptionConfiguration()
                    )
                    let audioStream = AsyncStream<[Float]>.makeStream(
                        bufferingPolicy: .unbounded
                    )
                    streamingAudioContinuation = audioStream.continuation
                    streamingForwardingTask = Task {
                        for await samples in audioStream.stream {
                            await streamingTranscriber.appendStreamingAudio(samples)
                        }
                    }
                    streamingCapture.setStreamingChunkHandler { samples in
                        audioStream.continuation.yield(samples)
                    }
                    activeStreamingCapture = streamingCapture
                    activeStreamingTranscriber = streamingTranscriber
                }
                try capture.start()
                recordingStartedAt = now()
                activeOperationID = UUID()
                state = .recording
                scheduleRecordingLimit()
            } catch {
                recordingStartedAt = nil
                await stopActiveStreaming()
                state = .failed(.capture(String(describing: error)))
            }

        case .released:
            guard state == .recording else { return }
            guard let operationID = activeOperationID else { return }
            let recordingEndedAt = now()
            let recordingStartedAt = self.recordingStartedAt
            self.recordingStartedAt = nil
            cancelRecordingLimit()
            state = .transcribing
            isCaptureStopping = true
            let samples = await capture.stop()
            isCaptureStopping = false
            await finishStreamingAudioForwarding()
            guard activeOperationID == operationID else {
                if activeOperationID == nil {
                    state = .idle
                }
                return
            }
            onCapture?(samples)
            if let recordingStartedAt,
               hasCaptureGap(
                   samples: samples,
                   recordingStartedAt: recordingStartedAt,
                   recordingEndedAt: recordingEndedAt
               )
            {
                await activeStreamingTranscriber?.cancelStreaming()
                activeStreamingTranscriber = nil
                activeOperationID = nil
                state = .failed(.capture(
                    "Audio input stopped before recording ended. "
                        + "Wordhand did not insert a partial transcript."
                ))
                return
            }
            guard !samples.isEmpty else {
                await activeStreamingTranscriber?.cancelStreaming()
                activeStreamingTranscriber = nil
                activeOperationID = nil
                state = .idle
                return
            }

            let transcriptionStarted = now()
            let raw: String
            let transcriptionElapsed: TimeInterval
            do {
                if let streamingTranscriber = activeStreamingTranscriber {
                    do {
                        let result = try await streamingTranscriber.finishStreaming(
                            finalAudio: samples
                        )
                        raw = result.text
                        transcriptionElapsed = result.totalInferenceDuration
                        onStreamingFinalizationDuration?(result.finalizationDuration)
                    } catch {
                        raw = try await transcriber.transcribe(samples)
                        transcriptionElapsed = now() - transcriptionStarted
                    }
                    activeStreamingTranscriber = nil
                } else {
                    raw = try await transcriber.transcribe(samples)
                    transcriptionElapsed = now() - transcriptionStarted
                }
            } catch {
                guard activeOperationID == operationID else { return }
                await stopActiveStreaming()
                activeOperationID = nil
                state = .failed(.transcription(String(describing: error)))
                return
            }
            guard activeOperationID == operationID else { return }

            state = .processing
            let target = currentTarget()
            let processingStarted = now()
            let text = await processor.process(raw, target: target)
            onProcessingDuration?(now() - processingStarted)
            guard activeOperationID == operationID else { return }
            guard !text.isEmpty else {
                activeOperationID = nil
                state = .idle
                return
            }

            let record = TranscriptRecord(
                createdAt: date(),
                rawText: raw,
                text: text,
                modelID: transcriber.modelID,
                language: language,
                audioDuration: Double(samples.count) / audioSampleRate,
                transcriptionDuration: transcriptionElapsed,
                insertionMode: insertionMode,
                target: target,
                status: .pendingInsertion
            )
            if let history {
                do {
                    try history.save(record)
                    onHistoryChange?()
                } catch {
                    activeOperationID = nil
                    state = .failed(.history(String(describing: error)))
                    return
                }
            }
            if history != nil {
                onQualityAudio?(QualityAudioSample(
                    transcriptID: record.id,
                    createdAt: record.createdAt,
                    samples: samples,
                    sampleRate: Int(audioSampleRate.rounded())
                ))
            }
            onTranscript?(text, transcriptionElapsed)

            state = .inserting
            do {
                try await inserter.insert(text, mode: insertionMode)
            } catch {
                if let history {
                    try? history.updateStatus(
                        id: record.id,
                        status: .insertionFailed(String(describing: error))
                    )
                    onHistoryChange?()
                }
                activeOperationID = nil
                state = .failed(.insertion(String(describing: error)))
                return
            }

            if let history {
                do {
                    try history.updateStatus(id: record.id, status: .inserted)
                    onHistoryChange?()
                } catch {
                    activeOperationID = nil
                    state = .failed(.historyStatus(String(describing: error)))
                    return
                }
            }
            activeOperationID = nil
            state = .idle
        }
    }

    public func cancelCurrent() async {
        switch state {
        case .recording:
            cancelRecordingLimit()
            recordingStartedAt = nil
            activeOperationID = nil
            await stopActiveStreaming()
            _ = await capture.stop()
            state = .idle
        case .transcribing, .processing:
            activeOperationID = nil
            await stopActiveStreaming()
            if !isCaptureStopping {
                if state == .transcribing {
                    await transcriber.cancel()
                }
                state = .idle
            }
        case .idle, .inserting, .failed:
            break
        }
    }

    public func resetFailure() {
        guard case .failed = state else { return }
        state = .idle
    }

    public func updateInsertionMode(_ insertionMode: InsertionMode) {
        self.insertionMode = insertionMode
    }

    public func updateStreamingEnabled(_ enabled: Bool) {
        streamingEnabled = enabled
    }

    private func scheduleRecordingLimit() {
        cancelRecordingLimit()
        guard let maximumRecordingNanoseconds else { return }
        let sleep = self.sleep
        recordingLimitTask = Task { [weak self] in
            do {
                try await sleep(maximumRecordingNanoseconds)
            } catch {
                return
            }
            guard let self else { return }
            guard !Task.isCancelled, state == .recording else { return }
            recordingLimitTask = nil
            onRecordingLimitReached?()
            await handle(.released)
        }
    }

    private func cancelRecordingLimit() {
        recordingLimitTask?.cancel()
        recordingLimitTask = nil
    }

    private func stopActiveStreaming() async {
        await finishStreamingAudioForwarding()
        await activeStreamingTranscriber?.cancelStreaming()
        activeStreamingTranscriber = nil
    }

    private func finishStreamingAudioForwarding() async {
        activeStreamingCapture?.setStreamingChunkHandler(nil)
        activeStreamingCapture = nil
        streamingAudioContinuation?.finish()
        streamingAudioContinuation = nil
        if let streamingForwardingTask {
            await streamingForwardingTask.value
        }
        streamingForwardingTask = nil
    }

    private func hasCaptureGap(
        samples: [Float],
        recordingStartedAt: TimeInterval,
        recordingEndedAt: TimeInterval
    ) -> Bool {
        guard audioSampleRate > 0 else { return false }
        let wallDuration = max(0, recordingEndedAt - recordingStartedAt)
        let audioDuration = Double(samples.count) / audioSampleRate
        return wallDuration - audioDuration > maximumCaptureGapSeconds
    }
}
