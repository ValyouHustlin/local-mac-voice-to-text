import Foundation

public enum StreamingFinalizationStrategy: Equatable, Sendable {
    case fullBufferControl
    case cumulativePrefixAuthorityExperiment
    case exactInferenceCacheAuthorityExperiment
}

public struct StreamingTranscriptionConfiguration: Equatable, Sendable {
    public var decodeIntervalSeconds: Double
    public var maximumWindowSeconds: Double
    public var correctionHorizonSegments: Int
    public var finalizationStrategy: StreamingFinalizationStrategy

    public init(
        decodeIntervalSeconds: Double = 2,
        maximumWindowSeconds: Double = 20,
        correctionHorizonSegments: Int = 2,
        finalizationStrategy: StreamingFinalizationStrategy = .fullBufferControl
    ) {
        let safeInterval = max(0.5, decodeIntervalSeconds)
        self.decodeIntervalSeconds = safeInterval
        self.maximumWindowSeconds = max(safeInterval * 2, maximumWindowSeconds)
        self.correctionHorizonSegments = max(0, correctionHorizonSegments)
        self.finalizationStrategy = finalizationStrategy
    }
}

public struct StreamingTranscriptSegment: Equatable, Sendable {
    public var text: String
    public var startSeconds: Double
    public var endSeconds: Double

    public init(text: String, startSeconds: Double, endSeconds: Double) {
        self.text = text
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }
}

public struct StreamingStabilizationUpdate: Equatable, Sendable {
    public var newlyConfirmed: [StreamingTranscriptSegment]
    public var agreed: [StreamingTranscriptSegment]
    public var pending: [StreamingTranscriptSegment]

    public init(
        newlyConfirmed: [StreamingTranscriptSegment],
        agreed: [StreamingTranscriptSegment],
        pending: [StreamingTranscriptSegment]
    ) {
        self.newlyConfirmed = newlyConfirmed
        self.agreed = agreed
        self.pending = pending
    }
}

public struct StreamingTranscriptStabilizer: Sendable {
    private let correctionHorizonSegments: Int
    private let requiresTimestampAgreement: Bool
    private var previous: [StreamingTranscriptSegment] = []

    public init(
        correctionHorizonSegments: Int = 2,
        requiresTimestampAgreement: Bool = true
    ) {
        self.correctionHorizonSegments = max(0, correctionHorizonSegments)
        self.requiresTimestampAgreement = requiresTimestampAgreement
    }

    public mutating func observe(
        _ segments: [StreamingTranscriptSegment]
    ) -> StreamingStabilizationUpdate {
        let commonCount = zip(previous, segments)
            .prefix {
                Self.matches(
                    $0.0,
                    $0.1,
                    requiresTimestampAgreement: requiresTimestampAgreement
                )
            }
            .count
        let agreed = Array(segments.prefix(commonCount))
        let safeCount = min(
            commonCount,
            max(0, segments.count - correctionHorizonSegments)
        )
        let confirmed = Array(segments.prefix(safeCount))
        let pending = Array(segments.dropFirst(safeCount))
        previous = segments
        return StreamingStabilizationUpdate(
            newlyConfirmed: confirmed,
            agreed: agreed,
            pending: pending
        )
    }

    public mutating func reset() {
        previous = []
    }

    private static func matches(
        _ lhs: StreamingTranscriptSegment,
        _ rhs: StreamingTranscriptSegment,
        requiresTimestampAgreement: Bool
    ) -> Bool {
        normalize(lhs.text) == normalize(rhs.text)
            && (
                !requiresTimestampAgreement
                || (
                    abs(lhs.startSeconds - rhs.startSeconds) < 0.35
                    && abs(lhs.endSeconds - rhs.endSeconds) < 0.35
                )
            )
    }

    private static func normalize(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(
                of: #"[^\p{L}\p{N}]+"#,
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum CumulativeSnapshotRejectionReason: Equatable, Sendable {
    case staleSession
    case staleGeneration
    case nonIncreasingSampleCount
    case decodeProvenanceMismatch
    case invalidAudioIdentity
    case invalidSegmentCoverage
}

public enum CumulativeSnapshotObservation: Equatable, Sendable {
    case accepted(stablePrefix: StableStreamingPrefix?)
    case rejected(CumulativeSnapshotRejectionReason)

    public var stablePrefix: StableStreamingPrefix? {
        guard case .accepted(let stablePrefix) = self else { return nil }
        return stablePrefix
    }
}

public struct CumulativeTranscriptSnapshotTracker: Sendable {
    public private(set) var frozenStablePrefix: StableStreamingPrefix?

    private let sessionID: String
    private let provenance: StreamingDecodeProvenance
    private let sampleRate: Int
    private var lastGeneration = 0
    private var lastSnapshotSampleCount = 0
    private var stabilizer: StreamingTranscriptStabilizer

    public init(
        sessionID: String,
        provenance: StreamingDecodeProvenance,
        sampleRate: Int,
        correctionHorizonSegments: Int
    ) {
        self.sessionID = sessionID
        self.provenance = provenance
        self.sampleRate = sampleRate
        self.stabilizer = StreamingTranscriptStabilizer(
            correctionHorizonSegments: correctionHorizonSegments,
            requiresTimestampAgreement: false
        )
    }

    public mutating func observe(
        sessionID: String,
        snapshotGeneration: Int,
        snapshotSampleCount: Int,
        audioSHA256: String,
        provenance: StreamingDecodeProvenance,
        segments: [StreamingTranscriptSegment]
    ) -> CumulativeSnapshotObservation {
        guard sessionID == self.sessionID else {
            return .rejected(.staleSession)
        }
        guard snapshotGeneration > lastGeneration else {
            return .rejected(.staleGeneration)
        }
        guard snapshotSampleCount > lastSnapshotSampleCount else {
            return .rejected(.nonIncreasingSampleCount)
        }
        guard provenance.isValid, provenance == self.provenance else {
            return .rejected(.decodeProvenanceMismatch)
        }
        guard StreamingAudioIdentity.isCanonicalSHA256(audioSHA256) else {
            return .rejected(.invalidAudioIdentity)
        }
        guard validSegments(
            segments,
            snapshotSampleCount: snapshotSampleCount
        ) else {
            return .rejected(.invalidSegmentCoverage)
        }

        lastGeneration = snapshotGeneration
        lastSnapshotSampleCount = snapshotSampleCount
        let update = stabilizer.observe(segments)
        guard let last = update.newlyConfirmed.last else {
            frozenStablePrefix = nil
            return .accepted(stablePrefix: nil)
        }
        let text = update.newlyConfirmed
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let coveredThroughSample = min(
            snapshotSampleCount,
            Int(last.endSeconds * Double(sampleRate))
        )
        guard !text.isEmpty, coveredThroughSample > 0 else {
            frozenStablePrefix = nil
            return .accepted(stablePrefix: nil)
        }
        let stablePrefix = StableStreamingPrefix(
            sessionID: sessionID,
            snapshotGeneration: snapshotGeneration,
            text: text,
            coveredThroughSample: coveredThroughSample,
            snapshotSampleCount: snapshotSampleCount,
            audioSHA256: audioSHA256,
            provenance: provenance
        )
        frozenStablePrefix = stablePrefix
        return .accepted(stablePrefix: stablePrefix)
    }

    private func validSegments(
        _ segments: [StreamingTranscriptSegment],
        snapshotSampleCount: Int
    ) -> Bool {
        guard sampleRate > 0, snapshotSampleCount > 0 else { return false }
        let snapshotDuration =
            Double(snapshotSampleCount) / Double(sampleRate)
        var previousStart: Double = 0
        for segment in segments {
            guard segment.startSeconds.isFinite,
                  segment.endSeconds.isFinite,
                  segment.startSeconds >= 0,
                  segment.startSeconds >= previousStart,
                  segment.endSeconds >= segment.startSeconds,
                  segment.endSeconds <= snapshotDuration
            else {
                return false
            }
            previousStart = segment.startSeconds
        }
        return true
    }
}

public struct StreamingTranscriptionResult: Equatable, Sendable {
    public var text: String
    public var totalInferenceDuration: TimeInterval
    public var finalizationDuration: TimeInterval
    public var preReleaseInferenceDuration: TimeInterval
    public var preReleaseDecodeCount: Int
    public var cancellationDrainDuration: TimeInterval
    public var authorityPath: String
    public var fallbackReason: String?
    public var reusedSampleCount: Int
    public var suffixStartSample: Int?
    public var suffixSampleCount: Int?
    public var overlapWordCount: Int
    public var featureCacheHits: Int
    public var featureCacheMisses: Int
    public var encoderCacheHits: Int
    public var encoderCacheMisses: Int

    public init(
        text: String,
        totalInferenceDuration: TimeInterval,
        finalizationDuration: TimeInterval,
        preReleaseInferenceDuration: TimeInterval = 0,
        preReleaseDecodeCount: Int = 0,
        cancellationDrainDuration: TimeInterval = 0,
        authorityPath: String = "full_buffer_control",
        fallbackReason: String? = nil,
        reusedSampleCount: Int = 0,
        suffixStartSample: Int? = nil,
        suffixSampleCount: Int? = nil,
        overlapWordCount: Int = 0,
        featureCacheHits: Int = 0,
        featureCacheMisses: Int = 0,
        encoderCacheHits: Int = 0,
        encoderCacheMisses: Int = 0
    ) {
        self.text = text
        self.totalInferenceDuration = totalInferenceDuration
        self.finalizationDuration = finalizationDuration
        self.preReleaseInferenceDuration = preReleaseInferenceDuration
        self.preReleaseDecodeCount = preReleaseDecodeCount
        self.cancellationDrainDuration = cancellationDrainDuration
        self.authorityPath = authorityPath
        self.fallbackReason = fallbackReason
        self.reusedSampleCount = reusedSampleCount
        self.suffixStartSample = suffixStartSample
        self.suffixSampleCount = suffixSampleCount
        self.overlapWordCount = overlapWordCount
        self.featureCacheHits = featureCacheHits
        self.featureCacheMisses = featureCacheMisses
        self.encoderCacheHits = encoderCacheHits
        self.encoderCacheMisses = encoderCacheMisses
    }
}

public protocol StreamingAudioCapturing: AudioCapturing {
    func setStreamingChunkHandler(
        _ handler: (@Sendable ([Float]) -> Void)?
    )
}

public protocol StreamingTranscribing: Transcribing {
    func beginStreaming(
        configuration: StreamingTranscriptionConfiguration
    ) async
    func appendStreamingAudio(_ samples: [Float]) async
    func finishStreaming(finalAudio: [Float]) async throws -> StreamingTranscriptionResult
    func cancelStreaming() async
}
