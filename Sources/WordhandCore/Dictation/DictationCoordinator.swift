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

public protocol RecoveryManagedAudioCapturing: AudioCapturing {
    func prepareRecovery(id: UUID, createdAt: Date, sampleRate: Int) throws
    func markRecoveryCommitted(id: UUID) throws
    func discardRecovery(id: UUID) throws
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

public struct TranscriptProcessingContext: Equatable, Sendable {
    public let target: TranscriptTarget
    public let formattingProfile: TranscriptFormattingProfile?
    public let formattingRouteSource: ApplicationFormattingRouteSource?
    public let performanceMode: ProcessingPerformanceMode?

    public init(
        target: TranscriptTarget,
        formattingProfile: TranscriptFormattingProfile? = nil,
        formattingRouteSource: ApplicationFormattingRouteSource? = nil,
        performanceMode: ProcessingPerformanceMode? = nil
    ) {
        self.target = target
        self.formattingProfile = formattingProfile
        self.formattingRouteSource = formattingRouteSource
        self.performanceMode = performanceMode
    }
}

public protocol TranscriptProcessing: Sendable {
    func process(_ text: String, target: TranscriptTarget) async -> String
}

public protocol ContextualTranscriptProcessing: TranscriptProcessing {
    func process(_ text: String, context: TranscriptProcessingContext) async -> String
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
    public var onDiagnosticEvent: ((OperationalDiagnosticEvent) -> Void)?
    public private(set) var activeProcessingContext: TranscriptProcessingContext?

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
    private let currentProcessingContext:
        (TranscriptTarget) -> TranscriptProcessingContext
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
    private var activeOperationStartedAt: TimeInterval?
    private let diagnosticSessionID: UUID

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
        currentProcessingContext: @escaping (TranscriptTarget)
            -> TranscriptProcessingContext = {
                TranscriptProcessingContext(target: $0)
            },
        date: @escaping () -> Date = Date.init,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        maximumCaptureGapSeconds: TimeInterval = 0.75,
        maximumRecordingNanoseconds: UInt64? = 600_000_000_000,
        diagnosticSessionID: UUID = UUID(),
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
        self.currentProcessingContext = currentProcessingContext
        self.date = date
        self.now = now
        self.maximumCaptureGapSeconds = maximumCaptureGapSeconds
        self.maximumRecordingNanoseconds = maximumRecordingNanoseconds
        self.diagnosticSessionID = diagnosticSessionID
        self.sleep = sleep
    }

    public func handle(_ event: HotkeyEvent) async {
        switch event {
        case .pressed:
            if case .failed = state {
                state = .idle
            }
            guard state == .idle else { return }
            let operationID = UUID()
            do {
                try (capture as? any RecoveryManagedAudioCapturing)?.prepareRecovery(
                    id: operationID,
                    createdAt: date(),
                    sampleRate: Int(audioSampleRate.rounded())
                )
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
                activeOperationStartedAt = recordingStartedAt
                activeOperationID = operationID
                let target = currentTarget()
                let resolvedContext = currentProcessingContext(target)
                activeProcessingContext = TranscriptProcessingContext(
                    target: target,
                    formattingProfile: resolvedContext.formattingProfile,
                    formattingRouteSource:
                        resolvedContext.formattingRouteSource,
                    performanceMode: resolvedContext.performanceMode
                )
                state = .recording
                recordDiagnostic(
                    name: "dictation.started",
                    dictationID: operationID,
                    attributes: [
                        "model_id": transcriber.modelID,
                        "insertion_mode": insertionMode.rawValue,
                        "streaming_enabled": String(streamingEnabled),
                        "target_bundle_id": target.bundleIdentifier ?? "unknown",
                        "target_app": target.applicationName ?? "unknown",
                        "formatting_profile":
                            activeProcessingContext?.formattingProfile?.rawValue
                                ?? "processor_default",
                        "formatting_route":
                            activeProcessingContext?.formattingRouteSource?.rawValue
                                ?? "processor_default",
                        "performance_mode":
                            activeProcessingContext?.performanceMode?.rawValue
                                ?? "processor_default",
                    ]
                )
                scheduleRecordingLimit()
            } catch {
                try? (capture as? any RecoveryManagedAudioCapturing)?
                    .discardRecovery(id: operationID)
                recordingStartedAt = nil
                activeOperationStartedAt = nil
                await stopActiveStreaming()
                recordDiagnostic(
                    severity: .error,
                    name: "capture.failed",
                    attributes: ["reason": String(describing: error)]
                )
                state = .failed(.capture(String(describing: error)))
            }

        case .released:
            guard state == .recording else { return }
            guard let operationID = activeOperationID else { return }
            let recordingEndedAt = now()
            let recordingStartedAt = self.recordingStartedAt
            let operationStartedAt = activeOperationStartedAt
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
            let audioDuration = Double(samples.count) / audioSampleRate
            let signal = AudioSignalMetrics.measure(
                samples,
                sampleRate: Int(audioSampleRate.rounded())
            )
            let wallDuration = recordingStartedAt.map {
                max(0, recordingEndedAt - $0)
            } ?? audioDuration
            recordDiagnostic(
                name: "capture.completed",
                dictationID: operationID,
                metrics: [
                    "audio_seconds": audioDuration,
                    "recording_wall_seconds": wallDuration,
                    "sample_count": Double(samples.count),
                    "rms": signal.rms,
                    "peak": signal.peak,
                    "clipped_sample_fraction": signal.clippedSampleFraction,
                    "active_window_fraction": signal.activeWindowFraction,
                ]
            )
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
                activeProcessingContext = nil
                activeOperationStartedAt = nil
                recordDiagnostic(
                    severity: .error,
                    name: "capture.failed",
                    dictationID: operationID,
                    metrics: [
                        "audio_seconds": audioDuration,
                        "recording_wall_seconds": wallDuration,
                    ],
                    attributes: ["reason": "captured_buffer_shorter_than_session"]
                )
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
                activeProcessingContext = nil
                activeOperationStartedAt = nil
                recordDiagnostic(
                    severity: .warning,
                    name: "capture.empty",
                    dictationID: operationID
                )
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
                activeProcessingContext = nil
                activeOperationStartedAt = nil
                recordDiagnostic(
                    severity: .error,
                    name: "transcription.failed",
                    dictationID: operationID,
                    metrics: ["audio_seconds": audioDuration],
                    attributes: [
                        "model_id": transcriber.modelID,
                        "reason": String(describing: error),
                    ]
                )
                state = .failed(.transcription(String(describing: error)))
                return
            }
            guard activeOperationID == operationID else { return }
            let transcriptionDiagnostics: TranscriptionRunDiagnostics
            if let provider = transcriber as? any TranscriptionDiagnosticsProviding {
                transcriptionDiagnostics = await provider.lastRunDiagnostics()
            } else {
                transcriptionDiagnostics = .none
            }
            recordDiagnostic(
                name: "transcription.completed",
                dictationID: operationID,
                metrics: [
                    "audio_seconds": audioDuration,
                    "transcription_seconds": transcriptionElapsed,
                    "raw_character_count": Double(raw.count),
                    "primary_word_count": Double(
                        transcriptionDiagnostics.primaryWordCount
                    ),
                    "final_word_count": Double(
                        transcriptionDiagnostics.finalWordCount
                    ),
                ],
                attributes: [
                    "model_id": transcriber.modelID,
                    "tail_outcome":
                        transcriptionDiagnostics.tailRecoveryOutcome.rawValue,
                    "full_retry_performed": String(
                        transcriptionDiagnostics.fullRetryPerformed
                    ),
                    "prompt_artifact_detected": String(
                        transcriptionDiagnostics.promptArtifactDetected
                    ),
                ]
            )

            state = .processing
            let processingContext = activeProcessingContext
                ?? TranscriptProcessingContext(target: .unknown)
            let target = processingContext.target
            let processingStarted = now()
            let text = await process(raw, context: processingContext)
            let processingElapsed = now() - processingStarted
            onProcessingDuration?(processingElapsed)
            recordDiagnostic(
                name: "processing.completed",
                dictationID: operationID,
                metrics: [
                    "processing_seconds": processingElapsed,
                    "processed_character_count": Double(text.count),
                ],
                attributes: [
                    "target_bundle_id": target.bundleIdentifier ?? "unknown",
                    "target_app": target.applicationName ?? "unknown",
                    "formatting_profile":
                        processingContext.formattingProfile?.rawValue
                            ?? "processor_default",
                    "formatting_route":
                        processingContext.formattingRouteSource?.rawValue
                            ?? "processor_default",
                    "performance_mode":
                        processingContext.performanceMode?.rawValue
                            ?? "processor_default",
                ]
            )
            guard activeOperationID == operationID else { return }
            guard !text.isEmpty else {
                activeOperationID = nil
                activeProcessingContext = nil
                activeOperationStartedAt = nil
                recordDiagnostic(
                    severity: .warning,
                    name: "processing.empty",
                    dictationID: operationID
                )
                state = .idle
                return
            }

            let record = TranscriptRecord(
                id: operationID,
                createdAt: date(),
                rawText: raw,
                text: text,
                modelID: transcriber.modelID,
                language: language,
                audioDuration: Double(samples.count) / audioSampleRate,
                transcriptionDuration: transcriptionElapsed,
                insertionMode: insertionMode,
                target: target,
                status: .pendingInsertion,
                tailRecoveryOutcome:
                    transcriptionDiagnostics.tailRecoveryOutcome
            )
            if let history {
                do {
                    try history.save(record)
                    onHistoryChange?()
                    recordDiagnostic(
                        name: "history.saved",
                        dictationID: operationID,
                        attributes: [
                            "transcript_id": record.id.uuidString.lowercased()
                        ]
                    )
                } catch {
                    activeOperationID = nil
                    activeProcessingContext = nil
                    activeOperationStartedAt = nil
                    recordDiagnostic(
                        severity: .error,
                        name: "history.failed",
                        dictationID: operationID,
                        attributes: ["reason": String(describing: error)]
                    )
                    state = .failed(.history(String(describing: error)))
                    return
                }
                do {
                    try (capture as? any RecoveryManagedAudioCapturing)?
                        .markRecoveryCommitted(id: operationID)
                } catch {
                    recordDiagnostic(
                        severity: .warning,
                        name: "capture_recovery.cleanup_failed",
                        dictationID: operationID,
                        attributes: ["reason": String(describing: error)]
                    )
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
            let insertionStarted = now()
            do {
                try await inserter.insert(text, mode: insertionMode)
            } catch {
                let insertionElapsed = now() - insertionStarted
                let insertionDiagnostics = await currentInsertionDiagnostics()
                if let history {
                    try? history.updateStatus(
                        id: record.id,
                        status: .insertionFailed(String(describing: error))
                    )
                    onHistoryChange?()
                }
                activeOperationID = nil
                activeProcessingContext = nil
                activeOperationStartedAt = nil
                recordDiagnostic(
                    severity: .error,
                    name: "insertion.failed",
                    dictationID: operationID,
                    metrics: ["insertion_seconds": insertionElapsed],
                    attributes: [
                        "insertion_mode": insertionMode.rawValue,
                        "reason": String(describing: error),
                        "verification":
                            insertionDiagnostics.verification.rawValue,
                        "secure_input_blocked": String(
                            insertionDiagnostics.secureInputBlocked
                        ),
                    ]
                )
                state = .failed(.insertion(String(describing: error)))
                return
            }
            let insertionElapsed = now() - insertionStarted
            let insertionDiagnostics = await currentInsertionDiagnostics()
            recordDiagnostic(
                name: "insertion.completed",
                dictationID: operationID,
                metrics: [
                    "insertion_seconds": insertionElapsed,
                    "retry_count": Double(insertionDiagnostics.retryCount),
                ],
                attributes: [
                    "insertion_mode": insertionMode.rawValue,
                    "verification": insertionDiagnostics.verification.rawValue,
                    "checkpoint_available": String(
                        insertionDiagnostics.checkpointAvailable
                    ),
                    "undo_available": String(
                        insertionDiagnostics.undoAvailable
                    ),
                ]
            )

            if let history {
                do {
                    try history.updateStatus(id: record.id, status: .inserted)
                    onHistoryChange?()
                } catch {
                    activeOperationID = nil
                    activeProcessingContext = nil
                    activeOperationStartedAt = nil
                    recordDiagnostic(
                        severity: .error,
                        name: "history_status.failed",
                        dictationID: operationID,
                        attributes: ["reason": String(describing: error)]
                    )
                    state = .failed(.historyStatus(String(describing: error)))
                    return
                }
            }
            recordDiagnostic(
                name: "dictation.completed",
                dictationID: operationID,
                metrics: [
                    "total_seconds": operationStartedAt.map {
                        max(0, now() - $0)
                    } ?? 0
                ]
            )
            activeOperationID = nil
            activeProcessingContext = nil
            activeOperationStartedAt = nil
            state = .idle
        }
    }

    public func cancelCurrent() async {
        switch state {
        case .recording:
            let operationID = activeOperationID
            cancelRecordingLimit()
            recordingStartedAt = nil
            activeOperationID = nil
            activeProcessingContext = nil
            activeOperationStartedAt = nil
            await stopActiveStreaming()
            _ = await capture.stop()
            if let operationID {
                try? (capture as? any RecoveryManagedAudioCapturing)?
                    .discardRecovery(id: operationID)
            }
            recordDiagnostic(
                severity: .warning,
                name: "dictation.cancelled",
                dictationID: operationID,
                attributes: ["stage": "recording"]
            )
            state = .idle
        case .transcribing, .processing:
            let operationID = activeOperationID
            let cancelledStage = state == .transcribing
                ? "transcribing"
                : "processing"
            activeOperationID = nil
            activeProcessingContext = nil
            activeOperationStartedAt = nil
            await stopActiveStreaming()
            if let operationID {
                try? (capture as? any RecoveryManagedAudioCapturing)?
                    .discardRecovery(id: operationID)
            }
            if !isCaptureStopping {
                if state == .transcribing {
                    await transcriber.cancel()
                }
                recordDiagnostic(
                    severity: .warning,
                    name: "dictation.cancelled",
                    dictationID: operationID,
                    attributes: ["stage": cancelledStage]
                )
                state = .idle
            }
        case .idle, .inserting, .failed:
            break
        }
    }

    public func resetFailure() {
        guard case .failed = state else { return }
        activeProcessingContext = nil
        state = .idle
    }

    private func process(
        _ text: String,
        context: TranscriptProcessingContext
    ) async -> String {
        if let contextual = processor as? any ContextualTranscriptProcessing {
            return await contextual.process(text, context: context)
        }
        return await processor.process(text, target: context.target)
    }

    /// Replays an orphaned audio journal through the same complete-buffer
    /// transcription and processing path. Recovered work is saved to History
    /// but never inserted because the original target is no longer trustworthy.
    public func recover(_ recovered: RecoveredAudioCapture) async -> Bool {
        guard state == .idle, let history else { return false }
        state = .transcribing
        let started = now()
        let raw: String
        do {
            raw = try await transcriber.transcribe(recovered.samples)
        } catch {
            recordDiagnostic(
                severity: .error,
                name: "capture_recovery.failed",
                dictationID: recovered.id,
                attributes: [
                    "stage": "transcription",
                    "reason": String(describing: error),
                ]
            )
            state = .failed(.transcription(String(describing: error)))
            return false
        }
        let transcriptionElapsed = now() - started
        state = .processing
        let text = await process(
            raw,
            context: TranscriptProcessingContext(target: .unknown)
        )
        guard !text.isEmpty else {
            recordDiagnostic(
                severity: .warning,
                name: "capture_recovery.failed",
                dictationID: recovered.id,
                attributes: ["stage": "empty_processing"]
            )
            state = .failed(.transcription("Recovered audio produced no text."))
            return false
        }

        let diagnostics = if let provider =
            transcriber as? any TranscriptionDiagnosticsProviding
        {
            await provider.lastRunDiagnostics()
        } else {
            TranscriptionRunDiagnostics.none
        }
        let record = TranscriptRecord(
            id: recovered.id,
            createdAt: recovered.createdAt,
            rawText: raw,
            text: text,
            modelID: transcriber.modelID,
            language: language,
            audioDuration: Double(recovered.samples.count)
                / Double(recovered.sampleRate),
            transcriptionDuration: transcriptionElapsed,
            insertionMode: insertionMode,
            target: .unknown,
            status: .insertionFailed(
                "Recovered after Wordhand closed before insertion."
            ),
            tailRecoveryOutcome: diagnostics.tailRecoveryOutcome
        )
        do {
            try history.save(record)
        } catch TranscriptHistoryError.duplicateRecord {
            state = .idle
            return true
        } catch {
            recordDiagnostic(
                severity: .error,
                name: "capture_recovery.failed",
                dictationID: recovered.id,
                attributes: [
                    "stage": "history",
                    "reason": String(describing: error),
                ]
            )
            state = .failed(.history(String(describing: error)))
            return false
        }
        onQualityAudio?(QualityAudioSample(
            transcriptID: record.id,
            createdAt: record.createdAt,
            samples: recovered.samples,
            sampleRate: recovered.sampleRate
        ))
        onTranscript?(text, transcriptionElapsed)
        onHistoryChange?()
        recordDiagnostic(
            name: "capture_recovery.completed",
            dictationID: recovered.id,
            metrics: [
                "audio_seconds": record.audioDuration,
                "transcription_seconds": transcriptionElapsed,
            ],
            attributes: ["model_id": transcriber.modelID]
        )
        state = .idle
        return true
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

    private func recordDiagnostic(
        severity: DiagnosticSeverity = .info,
        name: String,
        dictationID: UUID? = nil,
        metrics: [String: Double] = [:],
        attributes: [String: String] = [:]
    ) {
        onDiagnosticEvent?(OperationalDiagnosticEvent(
            occurredAt: date(),
            severity: severity,
            name: name,
            sessionID: diagnosticSessionID,
            dictationID: dictationID,
            metrics: metrics,
            attributes: attributes
        ))
    }

    private func currentInsertionDiagnostics() async
        -> InsertionRunDiagnostics
    {
        if let provider = inserter as? any InsertionDiagnosticsProviding {
            return await provider.lastInsertionDiagnostics()
        }
        return InsertionRunDiagnostics(mode: insertionMode)
    }
}
