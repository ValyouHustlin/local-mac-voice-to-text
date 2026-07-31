import Foundation

public enum HotkeyEvent: Equatable, Sendable {
    case pressed
    case released
}

public enum DictationFailure: Equatable, Sendable {
    case capture(String)
    case transcription(String)
    case preservedForRecovery(String)
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

public enum RecordingEndIntent: Equatable, Sendable {
    case finish
    case cancel
}

public enum CaptureInterruptionReason: String, Equatable, Sendable {
    case applicationQuit = "application_quit"
    case systemSleep = "system_sleep"
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

public enum TranscriptProcessingNotice: Equatable, Sendable {
    case spokenReplacementRejected(SpokenReplacementCommandRejection)
}

public struct TranscriptProcessingResult: Equatable, Sendable {
    public let text: String
    public let notices: [TranscriptProcessingNotice]

    public init(
        text: String,
        notices: [TranscriptProcessingNotice] = []
    ) {
        self.text = text
        self.notices = notices
    }
}

public protocol ReportingTranscriptProcessing: TranscriptProcessing {
    func processResult(
        _ text: String,
        target: TranscriptTarget
    ) async -> TranscriptProcessingResult
}

public protocol ContextualTranscriptProcessing: TranscriptProcessing {
    func process(_ text: String, context: TranscriptProcessingContext) async -> String
}

public protocol ContextualReportingTranscriptProcessing:
    ContextualTranscriptProcessing,
    ReportingTranscriptProcessing
{
    func processResult(
        _ text: String,
        context: TranscriptProcessingContext
    ) async -> TranscriptProcessingResult
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
    public var onRecordingStartAccepted: (() -> Void)?
    public var onRecordingStartRejected: (() -> Void)?
    public var onCapture: (([Float]) -> Void)?
    public var onTranscript: ((String, TimeInterval) -> Void)?
    public var onQualityAudio: ((QualityAudioSample) -> Void)?
    public var onProcessingDuration: ((TimeInterval) -> Void)?
    public var onProcessingNotice: ((TranscriptProcessingNotice) -> Void)?
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
    private var activeCaptureStopTask: Task<[Float], Never>?
    private var activeReleaseFinalization: ReleaseFinalization?
    private var pendingRecordingEndIntent: RecordingEndIntent?
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
            pendingRecordingEndIntent = nil
            onRecordingStartAccepted?()
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
                await scheduleRecordingLimit()
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
                pendingRecordingEndIntent = nil
                onRecordingStartRejected?()
                state = .failed(.capture(String(describing: error)))
            }

        case .released:
            guard state == .recording else { return }
            guard let operationID = activeOperationID else { return }
            let releaseFinalization = ReleaseFinalization()
            activeReleaseFinalization = releaseFinalization
            defer {
                releaseFinalization.complete()
                if activeReleaseFinalization === releaseFinalization {
                    activeReleaseFinalization = nil
                }
            }
            let recordingEndedAt = now()
            let recordingStartedAt = self.recordingStartedAt
            let operationStartedAt = activeOperationStartedAt
            self.recordingStartedAt = nil
            await cancelRecordingLimit()
            pendingRecordingEndIntent = .finish
            state = .transcribing
            let samples = await stopCaptureOnce()
            await finishStreamingAudioForwarding()
            let captureCompletedAt = now()
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
                    "capture_drain_seconds":
                        max(0, captureCompletedAt - recordingEndedAt),
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
            let reportedInferenceDuration: TimeInterval?
            do {
                if let streamingTranscriber = activeStreamingTranscriber {
                    do {
                        let result = try await streamingTranscriber.finishStreaming(
                            finalAudio: samples
                        )
                        raw = result.text
                        reportedInferenceDuration = result.totalInferenceDuration
                        onStreamingFinalizationDuration?(result.finalizationDuration)
                    } catch {
                        raw = try await transcriber.transcribe(samples)
                        reportedInferenceDuration = nil
                    }
                    activeStreamingTranscriber = nil
                } else {
                    raw = try await transcriber.transcribe(samples)
                    reportedInferenceDuration = nil
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
            let transcriptionCompletedAt = now()
            let transcriptionElapsed = reportedInferenceDuration
                ?? max(0, transcriptionCompletedAt - transcriptionStarted)
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
                    "primary_decode_seconds":
                        transcriptionDiagnostics.primaryDecodeSeconds,
                    "tail_audit_decode_seconds":
                        transcriptionDiagnostics.tailAuditDecodeSeconds,
                    "full_retry_decode_seconds":
                        transcriptionDiagnostics.fullRetryDecodeSeconds,
                    "release_to_raw_text_seconds":
                        max(0, transcriptionCompletedAt - recordingEndedAt),
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
                    "empty_recovery":
                        transcriptionDiagnostics
                            .emptyTranscriptRecoveryOutcome.rawValue,
                ]
            )

            if raw.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty {
                activeOperationID = nil
                activeProcessingContext = nil
                activeOperationStartedAt = nil
                if EmptyTranscriptRecoveryPolicy.hasMeaningfulActivity(signal) {
                    recordDiagnostic(
                        severity: .error,
                        name: "transcription.empty_preserved",
                        dictationID: operationID,
                        metrics: [
                            "audio_seconds": audioDuration,
                            "active_window_fraction":
                                signal.activeWindowFraction,
                        ]
                    )
                    state = .failed(.preservedForRecovery(
                        "No text was recognized. "
                            + "The recording is safe for recovery."
                    ))
                } else {
                    do {
                        try (capture as? any RecoveryManagedAudioCapturing)?
                            .discardRecovery(id: operationID)
                    } catch {
                        recordDiagnostic(
                            severity: .error,
                            name: "capture_recovery.cleanup_failed",
                            dictationID: operationID,
                            attributes: [
                                "reason": String(describing: error)
                            ]
                        )
                        state = .failed(.capture(
                            "Quiet recording cleanup failed: \(error)"
                        ))
                        return
                    }
                    recordDiagnostic(
                        name: "transcription.empty_silence",
                        dictationID: operationID,
                        metrics: ["audio_seconds": audioDuration]
                    )
                    state = .idle
                }
                return
            }

            state = .processing
            let processingContext = activeProcessingContext
                ?? TranscriptProcessingContext(target: .unknown)
            let target = processingContext.target
            let processingStarted = now()
            let processingResult = await process(
                raw,
                context: processingContext
            )
            let text = processingResult.text
            let processingCompletedAt = now()
            let processingElapsed = max(
                0,
                processingCompletedAt - processingStarted
            )
            onProcessingDuration?(processingElapsed)
            recordProcessingNotices(
                processingResult.notices,
                dictationID: operationID
            )
            recordDiagnostic(
                name: "processing.completed",
                dictationID: operationID,
                metrics: [
                    "processing_seconds": processingElapsed,
                    "release_to_formatted_text_seconds":
                        max(0, processingCompletedAt - recordingEndedAt),
                    "processed_character_count": Double(text.count),
                    "notice_count": Double(processingResult.notices.count),
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
            guard !text.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty else {
                activeOperationID = nil
                activeProcessingContext = nil
                activeOperationStartedAt = nil
                recordDiagnostic(
                    severity: .error,
                    name: "processing.empty_preserved",
                    dictationID: operationID
                )
                state = .failed(.preservedForRecovery(
                    "Formatting produced no text. "
                        + "The recording is safe for recovery."
                ))
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
                let insertionCompletedAt = now()
                let insertionElapsed = max(
                    0,
                    insertionCompletedAt - insertionStarted
                )
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
                    metrics: [
                        "insertion_seconds": insertionElapsed,
                        "release_to_insertion_seconds":
                            max(0, insertionCompletedAt - recordingEndedAt),
                    ],
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
            let insertionCompletedAt = now()
            let insertionElapsed = max(
                0,
                insertionCompletedAt - insertionStarted
            )
            let insertionDiagnostics = await currentInsertionDiagnostics()
            let insertionHistoryStatus = InsertionHistoryStatusPolicy.status(
                for: insertionDiagnostics
            )
            recordDiagnostic(
                name: "insertion.completed",
                dictationID: operationID,
                metrics: [
                    "insertion_seconds": insertionElapsed,
                    "release_to_insertion_seconds":
                        max(0, insertionCompletedAt - recordingEndedAt),
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
            for notice in processingResult.notices {
                onProcessingNotice?(notice)
            }

            if let history {
                do {
                    try history.updateStatus(
                        id: record.id,
                        status: insertionHistoryStatus
                    )
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
        markCancellationIntent()
        switch state {
        case .recording:
            let operationID = activeOperationID
            await cancelRecordingLimit()
            recordingStartedAt = nil
            activeOperationID = nil
            activeProcessingContext = nil
            activeOperationStartedAt = nil
            await stopActiveStreaming()
            _ = await stopCaptureOnce()
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

    /// Seals in-flight audio without transcription or insertion. The recovery
    /// journal deliberately remains until the same UUID is restored to History.
    @discardableResult
    public func preserveCurrentCaptureForRecovery(
        reason: CaptureInterruptionReason
    ) async -> Bool {
        guard let operationID = activeOperationID else { return false }
        let interruptedState = state
        let releaseFinalization = activeReleaseFinalization
        switch interruptedState {
        case .recording, .transcribing, .processing:
            break
        case .idle, .inserting, .failed:
            return false
        }

        pendingRecordingEndIntent = .cancel
        await cancelRecordingLimit()
        recordingStartedAt = nil
        activeOperationID = nil
        activeProcessingContext = nil
        activeOperationStartedAt = nil
        await stopActiveStreaming()

        switch interruptedState {
        case .recording:
            state = .transcribing
            _ = await stopCaptureOnce()
        case .transcribing:
            if isCaptureStopping {
                _ = await stopCaptureOnce()
            } else {
                await transcriber.cancel()
            }
        case .processing:
            break
        case .idle, .inserting, .failed:
            return false
        }

        if let releaseFinalization {
            await releaseFinalization.wait()
        }
        recordDiagnostic(
            name: "capture_recovery.preserved",
            dictationID: operationID,
            attributes: ["reason": reason.rawValue]
        )
        if activeOperationID == nil {
            state = .idle
        }
        return true
    }

    public func markCancellationIntent() {
        guard
            state == .recording
                || (state == .transcribing && isCaptureStopping)
        else {
            return
        }
        pendingRecordingEndIntent = .cancel
    }

    public func consumeRecordingEndIntent() -> RecordingEndIntent? {
        defer { pendingRecordingEndIntent = nil }
        return pendingRecordingEndIntent
    }

    public func resetFailure() {
        guard case .failed = state else { return }
        activeProcessingContext = nil
        state = .idle
    }

    public func surfacePreservedRecoveryFailure(_ message: String) {
        guard state == .idle else { return }
        state = .failed(.preservedForRecovery(message))
    }

    private func process(
        _ text: String,
        context: TranscriptProcessingContext
    ) async -> TranscriptProcessingResult {
        if let contextual =
            processor as? any ContextualReportingTranscriptProcessing
        {
            return await contextual.processResult(text, context: context)
        }
        if let contextual = processor as? any ContextualTranscriptProcessing {
            return TranscriptProcessingResult(
                text: await contextual.process(text, context: context)
            )
        }
        if let reporting = processor as? any ReportingTranscriptProcessing {
            return await reporting.processResult(
                text,
                target: context.target
            )
        }
        return TranscriptProcessingResult(
            text: await processor.process(text, target: context.target)
        )
    }

    private func stopCaptureOnce() async -> [Float] {
        if let activeCaptureStopTask {
            return await activeCaptureStopTask.value
        }
        isCaptureStopping = true
        let task = Task { await capture.stop() }
        activeCaptureStopTask = task
        let samples = await task.value
        activeCaptureStopTask = nil
        isCaptureStopping = false
        return samples
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
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let signal = AudioSignalMetrics.measure(
                recovered.samples,
                sampleRate: recovered.sampleRate
            )
            if EmptyTranscriptRecoveryPolicy.hasMeaningfulActivity(signal) {
                recordDiagnostic(
                    severity: .error,
                    name: "capture_recovery.empty_preserved",
                    dictationID: recovered.id,
                    metrics: [
                        "audio_seconds":
                            Double(recovered.samples.count)
                                / Double(recovered.sampleRate),
                        "active_window_fraction":
                            signal.activeWindowFraction,
                    ]
                )
                state = .failed(.preservedForRecovery(
                    "No text was recognized. "
                        + "The recording remains safe for recovery."
                ))
                return false
            }
            do {
                try (capture as? any RecoveryManagedAudioCapturing)?
                    .discardRecovery(id: recovered.id)
            } catch {
                recordDiagnostic(
                    severity: .error,
                    name: "capture_recovery.cleanup_failed",
                    dictationID: recovered.id,
                    attributes: ["reason": String(describing: error)]
                )
                state = .failed(.capture(
                    "Quiet recovery cleanup failed: \(error)"
                ))
                return false
            }
            recordDiagnostic(
                name: "capture_recovery.empty_silence",
                dictationID: recovered.id
            )
            state = .idle
            return true
        }
        state = .processing
        let processingResult = await process(
            raw,
            context: TranscriptProcessingContext(target: .unknown)
        )
        let text = processingResult.text
        recordProcessingNotices(
            processingResult.notices,
            dictationID: recovered.id
        )
        guard !text.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            recordDiagnostic(
                severity: .warning,
                name: "capture_recovery.failed",
                dictationID: recovered.id,
                attributes: ["stage": "empty_processing"]
            )
            state = .failed(.preservedForRecovery(
                "Formatting produced no text. "
                    + "The recording remains safe for recovery."
            ))
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

    private func recordProcessingNotices(
        _ notices: [TranscriptProcessingNotice],
        dictationID: UUID
    ) {
        for notice in notices {
            switch notice {
            case .spokenReplacementRejected(let reason):
                recordDiagnostic(
                    severity: .warning,
                    name: "processing.command_rejected",
                    dictationID: dictationID,
                    attributes: ["reason": reason.rawValue]
                )
            }
        }
    }

    public func updateInsertionMode(_ insertionMode: InsertionMode) {
        self.insertionMode = insertionMode
    }

    public func updateStreamingEnabled(_ enabled: Bool) {
        streamingEnabled = enabled
    }

    private func scheduleRecordingLimit() async {
        await cancelRecordingLimit()
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

    private func cancelRecordingLimit() async {
        guard let task = recordingLimitTask else { return }
        recordingLimitTask = nil
        task.cancel()
        await task.value
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

@MainActor
private final class ReleaseFinalization {
    private var isComplete = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isComplete else { return }
        await withCheckedContinuation { continuation in
            precondition(waiter == nil)
            waiter = continuation
        }
    }

    func complete() {
        guard !isComplete else { return }
        isComplete = true
        let waiter = waiter
        self.waiter = nil
        waiter?.resume()
    }
}
