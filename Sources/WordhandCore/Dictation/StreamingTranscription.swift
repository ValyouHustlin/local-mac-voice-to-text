import Foundation

public struct StreamingTranscriptionConfiguration: Equatable, Sendable {
    public var decodeIntervalSeconds: Double
    public var maximumWindowSeconds: Double
    public var correctionHorizonSegments: Int

    public init(
        decodeIntervalSeconds: Double = 2,
        maximumWindowSeconds: Double = 20,
        correctionHorizonSegments: Int = 2
    ) {
        let safeInterval = max(0.5, decodeIntervalSeconds)
        self.decodeIntervalSeconds = safeInterval
        self.maximumWindowSeconds = max(safeInterval * 2, maximumWindowSeconds)
        self.correctionHorizonSegments = max(0, correctionHorizonSegments)
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
    private var previous: [StreamingTranscriptSegment] = []

    public init(correctionHorizonSegments: Int = 2) {
        self.correctionHorizonSegments = max(0, correctionHorizonSegments)
    }

    public mutating func observe(
        _ segments: [StreamingTranscriptSegment]
    ) -> StreamingStabilizationUpdate {
        let commonCount = zip(previous, segments)
            .prefix { Self.matches($0.0, $0.1) }
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
        _ rhs: StreamingTranscriptSegment
    ) -> Bool {
        normalize(lhs.text) == normalize(rhs.text)
            && abs(lhs.startSeconds - rhs.startSeconds) < 0.35
            && abs(lhs.endSeconds - rhs.endSeconds) < 0.35
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

public struct StreamingTranscriptionResult: Equatable, Sendable {
    public var text: String
    public var totalInferenceDuration: TimeInterval
    public var finalizationDuration: TimeInterval
    public var preReleaseInferenceDuration: TimeInterval
    public var preReleaseDecodeCount: Int
    public var cancellationDrainDuration: TimeInterval

    public init(
        text: String,
        totalInferenceDuration: TimeInterval,
        finalizationDuration: TimeInterval,
        preReleaseInferenceDuration: TimeInterval = 0,
        preReleaseDecodeCount: Int = 0,
        cancellationDrainDuration: TimeInterval = 0
    ) {
        self.text = text
        self.totalInferenceDuration = totalInferenceDuration
        self.finalizationDuration = finalizationDuration
        self.preReleaseInferenceDuration = preReleaseInferenceDuration
        self.preReleaseDecodeCount = preReleaseDecodeCount
        self.cancellationDrainDuration = cancellationDrainDuration
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
