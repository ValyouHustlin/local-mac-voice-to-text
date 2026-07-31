import CryptoKit
import Foundation
import WordhandCore
import WhisperKit

actor WhisperKitTranscriber:
    Transcribing,
    StreamingTranscribing,
    TranscriptionDiagnosticsProviding
{
    let modelID: String
    private let model: TranscriptionModel
    private let vocabulary: DictionaryVocabularySource
    private let downloadBase: URL
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
    private var streamingDecodeCount = 0
    private var streamingStabilizer = StreamingTranscriptStabilizer()
    private var streamingSnapshotTracker: CumulativeTranscriptSnapshotTracker?
    private var streamingSnapshotGeneration = 0
    private var streamingDecodeProvenance: StreamingDecodeProvenance?
    private var streamingDecodeOptions: DecodingOptions?
    private var exactFeatureCache: ExactFeatureCache?
    private var exactAudioEncoderCache: ExactAudioEncoderCache?
    private var exactCacheSessionActive = false
    private var streamingDecodeTask: Task<Void, Never>?
    private var streamingFailure: Error?
    private var streamingIsFinishing = false
    private var latestRunDiagnostics = TranscriptionRunDiagnostics.none

    init(
        model: TranscriptionModel,
        vocabulary: DictionaryVocabularySource = DictionaryVocabularySource(),
        downloadBase: URL? = nil
    ) {
        self.modelID = model.id
        self.model = model
        self.vocabulary = vocabulary
        self.downloadBase =
            downloadBase ?? WhisperModelStorage.defaultDownloadBase()
    }

    /// Loads the model into memory; downloads first if not already on disk.
    /// Call once at startup so the first hotkey press isn't blocked on model
    /// download/load.
    func warmUp() async throws {
        try await warmUp(requireCachedModel: false)
    }

    func warmUpRequiringCachedModel() async throws {
        try await warmUp(requireCachedModel: true)
    }

    private func warmUp(requireCachedModel: Bool) async throws {
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
            let cacheState = WhisperModelStorage.cacheState(
                modelID: whisperKitID,
                downloadBase: downloadBase
            )
            let config: WhisperKitConfig
            switch cacheState {
            case .ready(let localModelFolder):
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
            case .invalid:
                throw TranscriberError.cachedModelInvalid
            case .missing:
                if requireCachedModel {
                    throw TranscriberError.modelNotCached
                }
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
        latestRunDiagnostics = .none
        if pipeline == nil { try await warmUp() }
        guard let pipeline else { throw TranscriberError.notLoaded }

        let token = TranscriptionCancellationToken()
        cancellationToken = token
        defer {
            if cancellationToken === token {
                cancellationToken = nil
            }
        }
        let primaryOptions = decodingOptions(for: pipeline)
        let primaryDecodeStarted = ProcessInfo.processInfo.systemUptime
        let primary = try await decode(
            audio,
            pipeline: pipeline,
            options: primaryOptions,
            token: token
        )
        let primaryDecodeSeconds =
            ProcessInfo.processInfo.systemUptime - primaryDecodeStarted
        return try await finalize(
            primary: primary,
            audio: audio,
            pipeline: pipeline,
            token: token,
            primaryOptions: primaryOptions,
            primaryDecodeSeconds: primaryDecodeSeconds
        )
    }

    private func finalize(
        primary: DecodedTranscript,
        audio: [Float],
        pipeline: WhisperKit,
        token: TranscriptionCancellationToken,
        primaryOptions: DecodingOptions,
        primaryDecodeSeconds: TimeInterval
    ) async throws -> String {
        let isVocabularyConditioned =
            primaryOptions.promptTokens?.isEmpty == false
        let conditionedTerms = isVocabularyConditioned
            ? vocabulary.terms()
            : []
        if primary.text.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty {
            let signal = AudioSignalMetrics.measure(
                audio,
                sampleRate: Int(WhisperKit.sampleRate)
            )
            let emptyRecoveryAction = EmptyTranscriptRecoveryPolicy.action(
                primaryText: primary.text,
                signal: signal
            )
            let shouldRetry = emptyRecoveryAction == .retryPromptFree
            if shouldRetry {
                FileHandle.standardError.write(Data(
                    "empty transcript recovery: decoding complete audio "
                        .appending("without vocabulary prompt\n").utf8
                ))
            }
            let fullRetryStarted = ProcessInfo.processInfo.systemUptime
            do {
                let recovery = try await EmptyTranscriptRecoveryPolicy.recover(
                    primaryText: primary.text,
                    signal: signal,
                    promptFreeRetry: {
                        try await self.decode(
                            audio,
                            pipeline: pipeline,
                            options: Self.makeDecodingOptions(
                                promptTokens: nil
                            ),
                            token: token
                        ).text
                    }
                )
                let fullRetryDecodeSeconds = shouldRetry
                    ? ProcessInfo.processInfo.systemUptime - fullRetryStarted
                    : 0
                latestRunDiagnostics = TranscriptionRunDiagnostics(
                    primaryWordCount: 0,
                    finalWordCount: Self.wordCount(recovery.text),
                    fullRetryPerformed: recovery.retryPerformed,
                    emptyTranscriptRecoveryOutcome: recovery.outcome,
                    primaryDecodeSeconds: primaryDecodeSeconds,
                    fullRetryDecodeSeconds: fullRetryDecodeSeconds
                )
                return recovery.text
            } catch {
                let fullRetryDecodeSeconds =
                    ProcessInfo.processInfo.systemUptime - fullRetryStarted
                if token.isCancelled {
                    throw error
                }
                FileHandle.standardError.write(Data(
                    "empty transcript recovery failed; "
                        .appending("preserving the captured audio\n").utf8
                ))
                latestRunDiagnostics = TranscriptionRunDiagnostics(
                    primaryWordCount: 0,
                    finalWordCount: 0,
                    fullRetryPerformed: true,
                    emptyTranscriptRecoveryOutcome: .retryFailed,
                    primaryDecodeSeconds: primaryDecodeSeconds,
                    fullRetryDecodeSeconds: fullRetryDecodeSeconds
                )
                return primary.text
            }
        }
        var integrityIssues = TranscriptionIntegrityGuard.issues(
            in: primary.text,
            conditionedTerms: conditionedTerms,
            audio: audio,
            sampleRate: Int(WhisperKit.sampleRate),
            lastDecodedSecond: primary.lastSegmentEnd
        )
        let requiresIndependentTailAudit =
            TranscriptionIntegrityGuard.needsIndependentTailAudit(
                audio: audio,
                sampleRate: Int(WhisperKit.sampleRate)
            )
        if requiresIndependentTailAudit {
            integrityIssues.insert(.activeAudioAfterDecodedEnding)
        }
        let primaryWordCount = Self.wordCount(primary.text)
        let promptArtifactDetected = integrityIssues.contains(
            .leadingConditioningArtifact
        )
        guard !integrityIssues.isEmpty else {
            latestRunDiagnostics = TranscriptionRunDiagnostics(
                primaryWordCount: primaryWordCount,
                finalWordCount: primaryWordCount,
                primaryDecodeSeconds: primaryDecodeSeconds
            )
            return primary.text
        }

        var tailRequiresFullRetry = false
        var tailAuditFailed = false
        var tailAuditVerifiedCovered = false
        var tailAuditDecodeSeconds: TimeInterval = 0
        if integrityIssues.contains(.activeAudioAfterDecodedEnding),
           audio.count > Self.tailRecoverySampleCount
        {
            FileHandle.standardError.write(Data(
                "transcript integrity tail audit: decoding final 20 seconds "
                    .appending("without vocabulary prompt\n").utf8
            ))
            let tailAuditStarted = ProcessInfo.processInfo.systemUptime
            do {
                let tailRetry = try await decode(
                    Array(audio.suffix(Self.tailRecoverySampleCount)),
                    pipeline: pipeline,
                    options: Self.makeDecodingOptions(promptTokens: nil),
                    token: token
                )
                tailAuditDecodeSeconds =
                    ProcessInfo.processInfo.systemUptime - tailAuditStarted
                switch TranscriptionIntegrityGuard.reconcileTail(
                    primary: primary.text,
                    recovery: tailRetry.text
                ) {
                case .merged(let merged):
                    let selected = TranscriptionIntegrityGuard.select(
                        primary: primary.text,
                        retry: merged,
                        issues: integrityIssues,
                        conditionedTerms: conditionedTerms
                    )
                    if selected != primary.text {
                        latestRunDiagnostics = TranscriptionRunDiagnostics(
                            tailRecoveryOutcome: .merged,
                            primaryWordCount: primaryWordCount,
                            finalWordCount: Self.wordCount(selected),
                            promptArtifactDetected: promptArtifactDetected,
                            primaryDecodeSeconds: primaryDecodeSeconds,
                            tailAuditDecodeSeconds: tailAuditDecodeSeconds
                        )
                        return selected
                    }
                    tailRequiresFullRetry = true
                case .covered:
                    tailAuditVerifiedCovered = true
                    if integrityIssues == [.activeAudioAfterDecodedEnding] {
                        latestRunDiagnostics = TranscriptionRunDiagnostics(
                            tailRecoveryOutcome: .verifiedCovered,
                            primaryWordCount: primaryWordCount,
                            finalWordCount: primaryWordCount,
                            primaryDecodeSeconds: primaryDecodeSeconds,
                            tailAuditDecodeSeconds: tailAuditDecodeSeconds
                        )
                        return primary.text
                    }
                case .requiresFullRetry:
                    tailRequiresFullRetry = true
                }
            } catch {
                tailAuditDecodeSeconds =
                    ProcessInfo.processInfo.systemUptime - tailAuditStarted
                if token.isCancelled {
                    throw error
                }
                FileHandle.standardError.write(Data(
                    "tail audit failed; falling back to full recovery\n".utf8
                ))
                tailRequiresFullRetry = true
                tailAuditFailed = true
            }
            if tailRequiresFullRetry {
                FileHandle.standardError.write(Data(
                    "tail audit did not prove complete coverage; "
                        .appending("falling back to full recovery\n").utf8
                ))
            }
        }

        guard isVocabularyConditioned || tailRequiresFullRetry else {
            latestRunDiagnostics = TranscriptionRunDiagnostics(
                tailRecoveryOutcome: integrityIssues.contains(
                    .activeAudioAfterDecodedEnding
                ) ? .noImprovement : .notAudited,
                primaryWordCount: primaryWordCount,
                finalWordCount: primaryWordCount,
                promptArtifactDetected: promptArtifactDetected,
                primaryDecodeSeconds: primaryDecodeSeconds,
                tailAuditDecodeSeconds: tailAuditDecodeSeconds
            )
            return primary.text
        }

        FileHandle.standardError.write(Data(
            "transcript integrity retry: decoding without vocabulary prompt\n".utf8
        ))
        let retry: DecodedTranscript
        let fullRetryStarted = ProcessInfo.processInfo.systemUptime
        var fullRetryDecodeSeconds: TimeInterval = 0
        do {
            retry = try await decode(
                audio,
                pipeline: pipeline,
                options: Self.makeDecodingOptions(promptTokens: nil),
                token: token
            )
            fullRetryDecodeSeconds =
                ProcessInfo.processInfo.systemUptime - fullRetryStarted
        } catch {
            fullRetryDecodeSeconds =
                ProcessInfo.processInfo.systemUptime - fullRetryStarted
            if token.isCancelled {
                throw error
            }
            FileHandle.standardError.write(Data(
                "transcript integrity retry failed; preserving primary decode\n".utf8
            ))
            latestRunDiagnostics = TranscriptionRunDiagnostics(
                tailRecoveryOutcome: TailRecoveryOutcome.resolvingFullRetry(
                    tailIssueDetected: integrityIssues.contains(
                        .activeAudioAfterDecodedEnding
                    ),
                    auditVerifiedCovered: tailAuditVerifiedCovered,
                    auditFailed: tailAuditFailed,
                    selectedDifferentTranscript: false
                ),
                primaryWordCount: primaryWordCount,
                finalWordCount: primaryWordCount,
                fullRetryPerformed: true,
                promptArtifactDetected: promptArtifactDetected,
                primaryDecodeSeconds: primaryDecodeSeconds,
                tailAuditDecodeSeconds: tailAuditDecodeSeconds,
                fullRetryDecodeSeconds: fullRetryDecodeSeconds
            )
            return primary.text
        }
        let selected = TranscriptionIntegrityGuard.select(
            primary: primary.text,
            retry: retry.text,
            issues: integrityIssues,
            conditionedTerms: conditionedTerms,
            requireMateriallyLongerTail:
                requiresIndependentTailAudit && tailRequiresFullRetry
        )
        latestRunDiagnostics = TranscriptionRunDiagnostics(
            tailRecoveryOutcome: TailRecoveryOutcome.resolvingFullRetry(
                tailIssueDetected: integrityIssues.contains(
                    .activeAudioAfterDecodedEnding
                ),
                auditVerifiedCovered: tailAuditVerifiedCovered,
                auditFailed: tailAuditFailed,
                selectedDifferentTranscript: selected != primary.text
            ),
            primaryWordCount: primaryWordCount,
            finalWordCount: Self.wordCount(selected),
            fullRetryPerformed: true,
            promptArtifactDetected: promptArtifactDetected,
            primaryDecodeSeconds: primaryDecodeSeconds,
            tailAuditDecodeSeconds: tailAuditDecodeSeconds,
            fullRetryDecodeSeconds: fullRetryDecodeSeconds
        )
        return selected
    }

    func lastRunDiagnostics() -> TranscriptionRunDiagnostics {
        latestRunDiagnostics
    }

    /// Offline-only comparison support. Both tail windows share the exact same
    /// primary and prompt-free full-buffer decodes so audit width is the sole
    /// changed variable. Daily runtime never calls this method.
    func compareTailAuditWindows(
        audio: [Float],
        orderedWindowSeconds: [Int]
    ) async throws -> TailAuditWindowExperimentPair {
        if pipeline == nil {
            try await warmUpRequiringCachedModel()
        }
        guard let pipeline else { throw TranscriberError.notLoaded }
        guard orderedWindowSeconds.count == 2,
              Set(orderedWindowSeconds) == [20, 30],
              TranscriptionIntegrityGuard.needsIndependentTailAudit(
                  audio: audio,
                  sampleRate: Int(WhisperKit.sampleRate)
              ),
              audio.count > 30 * Int(WhisperKit.sampleRate)
        else {
            throw TailAuditWindowExperimentError.invalidInput
        }

        let token = TranscriptionCancellationToken()
        cancellationToken = token
        defer {
            if cancellationToken === token {
                cancellationToken = nil
            }
        }
        let primaryOptions = decodingOptions(for: pipeline)
        let primaryStarted = ProcessInfo.processInfo.systemUptime
        let primary = try await decode(
            audio,
            pipeline: pipeline,
            options: primaryOptions,
            token: token
        )
        let primarySeconds =
            ProcessInfo.processInfo.systemUptime - primaryStarted
        let conditionedTerms =
            primaryOptions.promptTokens?.isEmpty == false
            ? vocabulary.terms()
            : []
        var issues = TranscriptionIntegrityGuard.issues(
            in: primary.text,
            conditionedTerms: conditionedTerms,
            audio: audio,
            sampleRate: Int(WhisperKit.sampleRate),
            lastDecodedSecond: primary.lastSegmentEnd
        )
        issues.insert(.activeAudioAfterDecodedEnding)

        var audits: [Int: TailAuditWindowDecodedArm] = [:]
        for seconds in orderedWindowSeconds {
            let started = ProcessInfo.processInfo.systemUptime
            let decoded = try await decode(
                Array(audio.suffix(seconds * Int(WhisperKit.sampleRate))),
                pipeline: pipeline,
                options: Self.makeDecodingOptions(promptTokens: nil),
                token: token
            )
            audits[seconds] = TailAuditWindowDecodedArm(
                text: decoded.text,
                seconds: ProcessInfo.processInfo.systemUptime - started
            )
        }

        let preliminary = try Dictionary(
            uniqueKeysWithValues: orderedWindowSeconds.map { seconds in
                guard let audit = audits[seconds] else {
                    throw TailAuditWindowExperimentError.missingAudit
                }
                return (
                    seconds,
                    resolveTailAuditExperiment(
                        primary: primary.text,
                        audit: audit.text,
                        fullRetry: nil,
                        issues: issues,
                        conditionedTerms: conditionedTerms
                    )
                )
            }
        )
        let needsFullRetry = preliminary.values.contains {
            if case .requiresFullRetry = $0 { return true }
            return false
        }
        var fullRetry: DecodedTranscript?
        var fullRetrySeconds: TimeInterval = 0
        if needsFullRetry {
            let started = ProcessInfo.processInfo.systemUptime
            fullRetry = try await decode(
                audio,
                pipeline: pipeline,
                options: Self.makeDecodingOptions(promptTokens: nil),
                token: token
            )
            fullRetrySeconds =
                ProcessInfo.processInfo.systemUptime - started
        }

        let arms = try Dictionary(
            uniqueKeysWithValues: orderedWindowSeconds.map { seconds in
                guard let audit = audits[seconds] else {
                    throw TailAuditWindowExperimentError.missingAudit
                }
                let resolution = resolveTailAuditExperiment(
                    primary: primary.text,
                    audit: audit.text,
                    fullRetry: fullRetry?.text,
                    issues: issues,
                    conditionedTerms: conditionedTerms
                )
                guard case let .complete(
                    text,
                    fullRetryPerformed,
                    outcome
                ) = resolution else {
                    throw TailAuditWindowExperimentError.missingFullRetry
                }
                return (
                    seconds,
                    TailAuditWindowExperimentArm(
                        transcript: text,
                        auditDecodeSeconds: audit.seconds,
                        modeledStopToFinalSeconds:
                            primarySeconds
                            + audit.seconds
                            + (fullRetryPerformed ? fullRetrySeconds : 0),
                        fullRetryPerformed: fullRetryPerformed,
                        tailOutcome: outcome
                    )
                )
            }
        )
        return TailAuditWindowExperimentPair(
            primaryDecodeSeconds: primarySeconds,
            fullRetryDecodeSeconds: fullRetrySeconds,
            arms: arms
        )
    }

    private func resolveTailAuditExperiment(
        primary: String,
        audit: String,
        fullRetry: String?,
        issues: Set<TranscriptionIntegrityIssue>,
        conditionedTerms: [String]
    ) -> TailAuditWindowExperimentResolution {
        switch TranscriptionIntegrityGuard.reconcileTail(
            primary: primary,
            recovery: audit
        ) {
        case .merged(let merged):
            let selected = TranscriptionIntegrityGuard.select(
                primary: primary,
                retry: merged,
                issues: issues,
                conditionedTerms: conditionedTerms
            )
            if selected != primary {
                return .complete(
                    text: selected,
                    fullRetryPerformed: false,
                    outcome: .merged
                )
            }
        case .covered:
            if issues == [.activeAudioAfterDecodedEnding] {
                return .complete(
                    text: primary,
                    fullRetryPerformed: false,
                    outcome: .verifiedCovered
                )
            }
        case .requiresFullRetry:
            break
        }
        guard let fullRetry else {
            return .requiresFullRetry
        }
        let selected = TranscriptionIntegrityGuard.select(
            primary: primary,
            retry: fullRetry,
            issues: issues,
            conditionedTerms: conditionedTerms,
            requireMateriallyLongerTail: true
        )
        return .complete(
            text: selected,
            fullRetryPerformed: true,
            outcome: TailRecoveryOutcome.resolvingFullRetry(
                tailIssueDetected: true,
                auditVerifiedCovered: false,
                auditFailed: false,
                selectedDifferentTranscript: selected != primary
            )
        )
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
        if configuration.finalizationStrategy
            == .exactInferenceCacheAuthorityExperiment
        {
            guard let pipeline else { return }
            beginExactInferenceCacheSession(pipeline: pipeline)
            return
        }
        guard configuration.finalizationStrategy
            == .cumulativePrefixAuthorityExperiment,
              let sessionID = streamingSessionID
        else {
            return
        }
        guard let pipeline else { return }
        let decodeOptions = decodingOptions(for: pipeline)
        let provenance = makeStreamingDecodeProvenance(
            options: decodeOptions
        )
        streamingDecodeOptions = decodeOptions
        streamingDecodeProvenance = provenance
        streamingSnapshotTracker = CumulativeTranscriptSnapshotTracker(
            sessionID: sessionID.uuidString,
            provenance: provenance,
            sampleRate: Int(WhisperKit.sampleRate),
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
        let frozenPrefix = streamingSnapshotTracker?.frozenStablePrefix
        let frozenFailure = streamingFailure
        let preReleaseInferenceDuration = streamingInferenceDuration
        let preReleaseDecodeCount = streamingDecodeCount
        let cancellationDrainStarted = ProcessInfo.processInfo.systemUptime
        if let task = streamingDecodeTask {
            // A rolling decode only improves perceived progress while speech is
            // continuing. Once the user stops, it is stale work: cancel it so
            // the authoritative full-buffer decode can begin immediately.
            task.cancel()
            await task.value
        }
        let cancellationDrainDuration =
            ProcessInfo.processInfo.systemUptime - cancellationDrainStarted
        streamingDecodeTask = nil
        streamingAudio = finalAudio

        if streamingConfiguration.finalizationStrategy == .fullBufferControl {
            return try await fullBufferStreamingResult(
                finalAudio: finalAudio,
                finalizationStarted: finalizationStarted,
                preReleaseInferenceDuration: preReleaseInferenceDuration,
                preReleaseDecodeCount: preReleaseDecodeCount,
                cancellationDrainDuration: cancellationDrainDuration,
                fallbackReason: nil
            )
        }
        if streamingConfiguration.finalizationStrategy
            == .exactInferenceCacheAuthorityExperiment
        {
            guard streamingFailure == nil, exactCacheSessionActive else {
                endExactInferenceCacheSession()
                return try await fullBufferStreamingResult(
                    finalAudio: finalAudio,
                    finalizationStarted: finalizationStarted,
                    preReleaseInferenceDuration: preReleaseInferenceDuration,
                    preReleaseDecodeCount: preReleaseDecodeCount,
                    cancellationDrainDuration: cancellationDrainDuration,
                    fallbackReason: streamingFailure == nil
                        ? "exact_cache_unavailable"
                        : "pre_release_cache_population_failed"
                )
            }
            let releaseCacheStatistics = exactCacheStatistics()
            return try await fullBufferStreamingResult(
                finalAudio: finalAudio,
                finalizationStarted: finalizationStarted,
                preReleaseInferenceDuration: preReleaseInferenceDuration,
                preReleaseDecodeCount: preReleaseDecodeCount,
                cancellationDrainDuration: cancellationDrainDuration,
                fallbackReason: nil,
                authorityPath: "full_buffer_exact_inference_cache",
                cacheStatisticsAtRelease: releaseCacheStatistics
            )
        }
        guard frozenFailure == nil,
              let frozenPrefix,
              let provenance = streamingDecodeProvenance
        else {
            return try await fullBufferStreamingResult(
                finalAudio: finalAudio,
                finalizationStarted: finalizationStarted,
                preReleaseInferenceDuration: preReleaseInferenceDuration,
                preReleaseDecodeCount: preReleaseDecodeCount,
                cancellationDrainDuration: cancellationDrainDuration,
                fallbackReason: frozenFailure == nil
                    ? "no_stable_cumulative_prefix"
                    : "pre_release_decode_failed"
            )
        }
        guard frozenPrefix.snapshotSampleCount <= finalAudio.count,
              Self.sha256Audio(
                Array(finalAudio.prefix(frozenPrefix.snapshotSampleCount))
              ) == frozenPrefix.audioSHA256
        else {
            return try await fullBufferStreamingResult(
                finalAudio: finalAudio,
                finalizationStarted: finalizationStarted,
                preReleaseInferenceDuration: preReleaseInferenceDuration,
                preReleaseDecodeCount: preReleaseDecodeCount,
                cancellationDrainDuration: cancellationDrainDuration,
                fallbackReason:
                    StreamingCompositionFallbackReason.prefixAudioMismatch.rawValue
            )
        }

        if pipeline == nil { try await warmUp() }
        guard let pipeline else { throw TranscriberError.notLoaded }
        let suffixOverlapSamples = Int(12 * WhisperKit.sampleRate)
        let suffixStartSample = max(
            0,
            frozenPrefix.coveredThroughSample - suffixOverlapSamples
        )
        guard suffixStartSample < finalAudio.count else {
            return try await fullBufferStreamingResult(
                finalAudio: finalAudio,
                finalizationStarted: finalizationStarted,
                preReleaseInferenceDuration: preReleaseInferenceDuration,
                preReleaseDecodeCount: preReleaseDecodeCount,
                cancellationDrainDuration: cancellationDrainDuration,
                fallbackReason:
                    StreamingCompositionFallbackReason.invalidAudioCoverage.rawValue
            )
        }
        let token = TranscriptionCancellationToken()
        cancellationToken = token
        defer {
            if cancellationToken === token {
                cancellationToken = nil
            }
        }
        guard let primaryOptions = streamingDecodeOptions else {
            return try await fullBufferStreamingResult(
                finalAudio: finalAudio,
                finalizationStarted: finalizationStarted,
                preReleaseInferenceDuration: preReleaseInferenceDuration,
                preReleaseDecodeCount: preReleaseDecodeCount,
                cancellationDrainDuration: cancellationDrainDuration,
                fallbackReason: "decode_provenance_unavailable"
            )
        }
        let suffixDecodeStarted = ProcessInfo.processInfo.systemUptime
        let suffix: DecodedTranscript
        do {
            suffix = try await decode(
                Array(finalAudio[suffixStartSample...]),
                pipeline: pipeline,
                options: primaryOptions,
                token: token
            )
        } catch {
            if token.isCancelled {
                throw error
            }
            return try await fullBufferStreamingResult(
                finalAudio: finalAudio,
                finalizationStarted: finalizationStarted,
                preReleaseInferenceDuration: preReleaseInferenceDuration,
                preReleaseDecodeCount: preReleaseDecodeCount,
                cancellationDrainDuration: cancellationDrainDuration,
                fallbackReason:
                    StreamingCompositionFallbackReason.suffixDecodeFailed.rawValue
            )
        }
        let suffixDecodeSeconds =
            ProcessInfo.processInfo.systemUptime - suffixDecodeStarted
        streamingInferenceDuration += suffixDecodeSeconds
        let composition = StreamingAuthorityComposer.compose(
            StreamingAuthorityCompositionRequest(
                release: StreamingAuthorityRelease(
                    sessionID: frozenPrefix.sessionID,
                    snapshotGeneration: frozenPrefix.snapshotGeneration,
                    finalSampleCount: finalAudio.count,
                    stablePrefixAudioSHA256: frozenPrefix.audioSHA256,
                    provenance: provenance
                ),
                stablePrefix: frozenPrefix,
                suffix: .decoded(StreamingSuffixDecode(
                    sessionID: frozenPrefix.sessionID,
                    snapshotGeneration: frozenPrefix.snapshotGeneration,
                    text: suffix.text,
                    startSample: suffixStartSample,
                    endSample: finalAudio.count,
                    provenance: provenance
                ))
            ),
            integrity: { text in
                text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? .diverged
                    : .verified
            }
        )
        guard case .verified(let verified) = composition else {
            let reason: String
            if case .requiresFullBuffer(let fallback) = composition {
                reason = fallback.rawValue
            } else {
                reason = "composition_rejected"
            }
            return try await fullBufferStreamingResult(
                finalAudio: finalAudio,
                finalizationStarted: finalizationStarted,
                preReleaseInferenceDuration: preReleaseInferenceDuration,
                preReleaseDecodeCount: preReleaseDecodeCount,
                cancellationDrainDuration: cancellationDrainDuration,
                fallbackReason: reason
            )
        }
        latestRunDiagnostics = .none
        let globalLastSegmentEnd = suffix.lastSegmentEnd.map {
            Double(suffixStartSample) / Double(WhisperKit.sampleRate) + $0
        }
        let text = try await finalize(
            primary: DecodedTranscript(
                text: verified.text,
                lastSegmentEnd: globalLastSegmentEnd
            ),
            audio: finalAudio,
            pipeline: pipeline,
            token: token,
            primaryOptions: primaryOptions,
            primaryDecodeSeconds: suffixDecodeSeconds
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !latestRunDiagnostics.fullRetryPerformed else {
            return try await fullBufferStreamingResult(
                finalAudio: finalAudio,
                finalizationStarted: finalizationStarted,
                preReleaseInferenceDuration: preReleaseInferenceDuration,
                preReleaseDecodeCount: preReleaseDecodeCount,
                cancellationDrainDuration: cancellationDrainDuration,
                fallbackReason: "integrity_full_retry"
            )
        }
        return StreamingTranscriptionResult(
            text: text,
            totalInferenceDuration: streamingInferenceDuration,
            finalizationDuration:
                ProcessInfo.processInfo.systemUptime - finalizationStarted,
            preReleaseInferenceDuration: preReleaseInferenceDuration,
            preReleaseDecodeCount: preReleaseDecodeCount,
            cancellationDrainDuration: cancellationDrainDuration,
            authorityPath: "composed",
            reusedSampleCount: verified.reusedSampleCount,
            suffixStartSample: verified.suffixStartSample,
            suffixSampleCount: verified.suffixSampleCount,
            overlapWordCount: verified.overlapWordCount
        )
    }

    private func fullBufferStreamingResult(
        finalAudio: [Float],
        finalizationStarted: TimeInterval,
        preReleaseInferenceDuration: TimeInterval,
        preReleaseDecodeCount: Int,
        cancellationDrainDuration: TimeInterval,
        fallbackReason: String?,
        authorityPath: String = "full_buffer_control",
        cacheStatisticsAtRelease: ExactCacheStatistics? = nil
    ) async throws -> StreamingTranscriptionResult {
        let decodeStarted = ProcessInfo.processInfo.systemUptime
        let text = try await transcribe(finalAudio)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        streamingInferenceDuration +=
            ProcessInfo.processInfo.systemUptime - decodeStarted
        let cacheDelta = cacheStatisticsAtRelease.map {
            exactCacheStatistics() - $0
        } ?? .zero
        let result = StreamingTranscriptionResult(
            text: text,
            totalInferenceDuration: streamingInferenceDuration,
            finalizationDuration:
                ProcessInfo.processInfo.systemUptime - finalizationStarted,
            preReleaseInferenceDuration: preReleaseInferenceDuration,
            preReleaseDecodeCount: preReleaseDecodeCount,
            cancellationDrainDuration: cancellationDrainDuration,
            authorityPath: authorityPath,
            fallbackReason: fallbackReason,
            featureCacheHits: cacheDelta.feature.hits,
            featureCacheMisses: cacheDelta.feature.misses,
            encoderCacheHits: cacheDelta.encoder.hits,
            encoderCacheMisses: cacheDelta.encoder.misses
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
        let cumulativeAuthorityExperiment =
            streamingConfiguration.finalizationStrategy
            == .cumulativePrefixAuthorityExperiment
        let exactCacheExperiment =
            streamingConfiguration.finalizationStrategy
            == .exactInferenceCacheAuthorityExperiment
        let cumulativeInput =
            cumulativeAuthorityExperiment || exactCacheExperiment
        let maximumWindowSamples = Int(
            streamingConfiguration.maximumWindowSeconds * Double(WhisperKit.sampleRate)
        )
        let windowStart = cumulativeInput ? 0 : streamingStartSample
        let windowEnd = cumulativeInput
            ? streamingAudio.count
            : min(streamingAudio.count, streamingStartSample + maximumWindowSamples)
        guard windowEnd > windowStart else {
            streamingDecodeTask = nil
            return
        }
        streamingLastDecodeSample = windowEnd
        let window = Array(streamingAudio[windowStart..<windowEnd])
        if cumulativeAuthorityExperiment {
            streamingSnapshotGeneration += 1
        }
        let snapshotGeneration = streamingSnapshotGeneration
        let audioSHA256 = cumulativeAuthorityExperiment
            ? Self.sha256Audio(window)
            : ""
        let decodeStarted = ProcessInfo.processInfo.systemUptime

        do {
            let transcription = try await transcribeWindow(
                window,
                wordLevelSegments: cumulativeAuthorityExperiment
            )
            streamingInferenceDuration +=
                ProcessInfo.processInfo.systemUptime - decodeStarted
            streamingDecodeCount += 1
            guard streamingSessionID == sessionID else {
                streamingDecodeTask = nil
                return
            }
            let segments = transcription.segments
            if exactCacheExperiment {
                let statistics = exactCacheStatistics()
                FileHandle.standardError.write(Data(
                    "exact cache precompute: feature "
                        .appending("\(statistics.feature.hits) hits/")
                        .appending("\(statistics.feature.misses) misses, encoder ")
                        .appending("\(statistics.encoder.hits) hits/")
                        .appending("\(statistics.encoder.misses) misses\n").utf8
                ))
                streamingDecodeTask = nil
                scheduleStreamingDecodeIfNeeded()
                return
            }
            if cumulativeAuthorityExperiment,
               let provenance = streamingDecodeProvenance
            {
                let observation = streamingSnapshotTracker?.observe(
                    sessionID: sessionID.uuidString,
                    snapshotGeneration: snapshotGeneration,
                    snapshotSampleCount: windowEnd,
                    audioSHA256: audioSHA256,
                    provenance: provenance,
                    segments: segments
                )
                switch observation {
                case .accepted(let stablePrefix):
                    let covered = stablePrefix?.coveredThroughSample ?? 0
                    FileHandle.standardError.write(Data(
                        "cumulative snapshot \(snapshotGeneration): "
                            .appending("\(segments.count) segments, ")
                            .appending("stable through sample \(covered)\n")
                            .utf8
                    ))
                case .rejected(let reason):
                    let minimumStart = segments.map(\.startSeconds).min() ?? 0
                    let maximumEnd = segments.map(\.endSeconds).max() ?? 0
                    FileHandle.standardError.write(Data(
                        "cumulative snapshot \(snapshotGeneration) rejected: "
                            .appending("\(reason), range ")
                            .appending("\(minimumStart)...\(maximumEnd), ")
                            .appending("duration ")
                            .appending(
                                "\(Double(windowEnd) / Double(WhisperKit.sampleRate))\n"
                            ).utf8
                    ))
                case nil:
                    break
                }
                streamingDecodeTask = nil
                scheduleStreamingDecodeIfNeeded()
                return
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
        var segments: [StreamingTranscriptSegment]
    }

    private func transcribeWindow(
        _ audio: [Float],
        wordLevelSegments: Bool = false
    ) async throws -> WindowTranscription {
        if pipeline == nil { try await warmUp() }
        guard let pipeline else { throw TranscriberError.notLoaded }
        var options = wordLevelSegments
            ? (streamingDecodeOptions ?? decodingOptions(for: pipeline))
            : decodingOptions(for: pipeline)
        options.wordTimestamps = wordLevelSegments
        let results = try await pipeline.transcribe(
            audioArray: audio,
            decodeOptions: options,
            callback: { _ in Task.isCancelled ? false : nil }
        )
        let decodedSegments = results.flatMap(\.segments)
        let segments: [StreamingTranscriptSegment]
        if wordLevelSegments {
            segments = decodedSegments.flatMap { segment in
                (segment.words ?? []).map {
                    StreamingTranscriptSegment(
                        text: $0.word,
                        startSeconds: Double($0.start),
                        endSeconds: Double($0.end)
                    )
                }
            }
        } else {
            segments = decodedSegments.map {
                StreamingTranscriptSegment(
                    text: $0.text,
                    startSeconds: Double($0.start),
                    endSeconds: Double($0.end)
                )
            }
        }
        return WindowTranscription(
            text: results.map(\.text).joined(separator: " "),
            segments: segments
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

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    private func makeStreamingDecodeProvenance(
        options: DecodingOptions
    ) -> StreamingDecodeProvenance {
        let promptTokenBytes = (options.promptTokens ?? []).withUnsafeBytes {
            Data($0)
        }
        return StreamingDecodeProvenance(
            modelID: modelID,
            vocabularySHA256: Self.sha256(promptTokenBytes),
            decoderConfigurationID: "wordhand-english-default-v1",
            language: "en"
        )
    }

    private static func sha256Audio(_ audio: [Float]) -> String {
        audio.withUnsafeBytes { sha256(Data($0)) }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct ExactCacheStatistics {
        var feature: ExactInferenceCacheStatistics
        var encoder: ExactInferenceCacheStatistics

        static let zero = ExactCacheStatistics(
            feature: .zero,
            encoder: .zero
        )

        static func - (
            lhs: ExactCacheStatistics,
            rhs: ExactCacheStatistics
        ) -> ExactCacheStatistics {
            ExactCacheStatistics(
                feature: lhs.feature - rhs.feature,
                encoder: lhs.encoder - rhs.encoder
            )
        }
    }

    private func beginExactInferenceCacheSession(pipeline: WhisperKit) {
        if exactFeatureCache == nil {
            let featureCache = ExactFeatureCache(
                base: pipeline.featureExtractor
            )
            pipeline.featureExtractor = featureCache
            exactFeatureCache = featureCache
        }
        if exactAudioEncoderCache == nil {
            let encoderCache = ExactAudioEncoderCache(
                base: pipeline.audioEncoder
            )
            pipeline.audioEncoder = encoderCache
            exactAudioEncoderCache = encoderCache
        }
        exactFeatureCache?.beginSession()
        exactAudioEncoderCache?.beginSession()
        exactCacheSessionActive = true
    }

    private func endExactInferenceCacheSession() {
        exactFeatureCache?.endSession()
        exactAudioEncoderCache?.endSession()
        exactCacheSessionActive = false
    }

    private func exactCacheStatistics() -> ExactCacheStatistics {
        ExactCacheStatistics(
            feature: exactFeatureCache?.statistics ?? .zero,
            encoder: exactAudioEncoderCache?.statistics ?? .zero
        )
    }

    private static let tailRecoverySampleCount = Int(
        20 * WhisperKit.sampleRate
    )

    private struct DecodedTranscript {
        let text: String
        let lastSegmentEnd: TimeInterval?
    }

    private func decode(
        _ audio: [Float],
        pipeline: WhisperKit,
        options: DecodingOptions,
        token: TranscriptionCancellationToken
    ) async throws -> DecodedTranscript {
        let results = try await pipeline.transcribe(
            audioArray: audio,
            decodeOptions: options,
            callback: { _ in token.isCancelled ? false : nil }
        )
        let text = results
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lastSegmentEnd = results
            .flatMap(\.segments)
            .map { TimeInterval($0.end) }
            .max()
        return DecodedTranscript(
            text: text,
            lastSegmentEnd: lastSegmentEnd
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
        endExactInferenceCacheSession()
        streamingDecodeTask = nil
        streamingSessionID = nil
        streamingAudio = []
        streamingStartSample = 0
        streamingLastDecodeSample = 0
        streamingCommittedText = []
        streamingInferenceDuration = 0
        streamingDecodeCount = 0
        streamingFailure = nil
        streamingIsFinishing = false
        streamingStabilizer.reset()
        streamingSnapshotTracker = nil
        streamingSnapshotGeneration = 0
        streamingDecodeProvenance = nil
        streamingDecodeOptions = nil
    }
}

struct TailAuditWindowExperimentPair: Sendable {
    let primaryDecodeSeconds: TimeInterval
    let fullRetryDecodeSeconds: TimeInterval
    let arms: [Int: TailAuditWindowExperimentArm]
}

struct TailAuditWindowExperimentArm: Sendable {
    let transcript: String
    let auditDecodeSeconds: TimeInterval
    let modeledStopToFinalSeconds: TimeInterval
    let fullRetryPerformed: Bool
    let tailOutcome: TailRecoveryOutcome
}

private struct TailAuditWindowDecodedArm {
    let text: String
    let seconds: TimeInterval
}

private enum TailAuditWindowExperimentResolution {
    case complete(
        text: String,
        fullRetryPerformed: Bool,
        outcome: TailRecoveryOutcome
    )
    case requiresFullRetry
}

private enum TailAuditWindowExperimentError: Error {
    case invalidInput
    case missingAudit
    case missingFullRetry
}

enum TranscriberError: Error, Equatable {
    case missingEngineID
    case modelNotCached
    case cachedModelInvalid
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
