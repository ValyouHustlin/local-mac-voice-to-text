import Testing
@testable import WordhandCore

@Suite
struct CumulativeTranscriptSnapshotTrackerTests {
    @Test
    func dailyConfigurationKeepsFullBufferAuthority() {
        let daily = StreamingTranscriptionConfiguration()
        let experiment = StreamingTranscriptionConfiguration(
            finalizationStrategy: .cumulativePrefixAuthorityExperiment
        )
        let cacheExperiment = StreamingTranscriptionConfiguration(
            finalizationStrategy: .exactInferenceCacheAuthorityExperiment
        )

        #expect(daily.finalizationStrategy == .fullBufferControl)
        #expect(
            experiment.finalizationStrategy
                == .cumulativePrefixAuthorityExperiment
        )
        #expect(
            cacheExperiment.finalizationStrategy
                == .exactInferenceCacheAuthorityExperiment
        )
    }

    @Test
    func successiveAgreementRetainsOnlyOutsideCorrectionHorizon() {
        var tracker = CumulativeTranscriptSnapshotTracker(
            sessionID: sessionID,
            provenance: provenance,
            sampleRate: 100,
            correctionHorizonSegments: 2
        )
        let first = tracker.observe(
            sessionID: sessionID,
            snapshotGeneration: 1,
            snapshotSampleCount: 1_000,
            audioSHA256: hashA,
            provenance: provenance,
            segments: segments(["one", "two", "three", "four"])
        )
        let second = tracker.observe(
            sessionID: sessionID,
            snapshotGeneration: 2,
            snapshotSampleCount: 1_200,
            audioSHA256: hashB,
            provenance: provenance,
            segments: segments(["one", "two", "three", "four"])
        )

        #expect(first == .accepted(stablePrefix: nil))
        #expect(second == .accepted(stablePrefix: StableStreamingPrefix(
            sessionID: sessionID,
            snapshotGeneration: 2,
            text: "one two",
            coveredThroughSample: 400,
            snapshotSampleCount: 1_200,
            audioSHA256: hashB,
            provenance: provenance
        )))
        #expect(tracker.frozenStablePrefix == second.stablePrefix)
    }

    @Test
    func correctionInsideHorizonDoesNotChangeStablePrefix() {
        var tracker = trackerAfterFirstSnapshot()
        let observation = tracker.observe(
            sessionID: sessionID,
            snapshotGeneration: 2,
            snapshotSampleCount: 1_200,
            audioSHA256: hashB,
            provenance: provenance,
            segments: segments(["one", "two", "corrected", "ending"])
        )

        #expect(observation.stablePrefix?.text == "one two")
    }

    @Test
    func cumulativeWordAgreementDoesNotDependOnDecoderTimestampDrift() {
        var tracker = trackerAfterFirstSnapshot()
        let observation = tracker.observe(
            sessionID: sessionID,
            snapshotGeneration: 2,
            snapshotSampleCount: 1_200,
            audioSHA256: hashB,
            provenance: provenance,
            segments: [
                .init(text: "one", startSeconds: 1, endSeconds: 3),
                .init(text: "two", startSeconds: 3, endSeconds: 5),
                .init(text: "three", startSeconds: 5, endSeconds: 7),
                .init(text: "four", startSeconds: 7, endSeconds: 9)
            ]
        )

        #expect(observation.stablePrefix?.text == "one two")
        #expect(observation.stablePrefix?.coveredThroughSample == 500)
    }

    @Test
    func decodeProvenanceMismatchCannotMutateFrozenPrefix() {
        var tracker = trackerAfterTwoStableSnapshots()
        let frozen = tracker.frozenStablePrefix
        let different = StreamingDecodeProvenance(
            modelID: "different-model",
            vocabularySHA256: vocabularySHA256,
            decoderConfigurationID: "english-default-v1",
            language: "en"
        )

        #expect(
            tracker.observe(
                sessionID: sessionID,
                snapshotGeneration: 3,
                snapshotSampleCount: 1_400,
                audioSHA256: hashC,
                provenance: different,
                segments: segments(["one", "two", "three", "four"])
            ) == .rejected(.decodeProvenanceMismatch)
        )
        #expect(tracker.frozenStablePrefix == frozen)
    }

    @Test
    func correctionBeforeStableBoundaryRevokesUnsafePrefix() {
        var tracker = trackerAfterTwoStableSnapshots()
        let observation = tracker.observe(
            sessionID: sessionID,
            snapshotGeneration: 3,
            snapshotSampleCount: 1_400,
            audioSHA256: hashC,
            provenance: provenance,
            segments: segments(["changed", "two", "three", "four"])
        )

        #expect(observation == .accepted(stablePrefix: nil))
        #expect(tracker.frozenStablePrefix == nil)
    }

    @Test
    func staleSessionCannotMutateFrozenPrefix() {
        var tracker = trackerAfterTwoStableSnapshots()
        let frozen = tracker.frozenStablePrefix
        let observation = tracker.observe(
            sessionID: "older-session",
            snapshotGeneration: 3,
            snapshotSampleCount: 1_400,
            audioSHA256: hashC,
            provenance: provenance,
            segments: segments(["changed", "words", "arrived", "late"])
        )

        #expect(observation == .rejected(.staleSession))
        #expect(tracker.frozenStablePrefix == frozen)
    }

    @Test
    func lateSameSessionGenerationCannotMutateFrozenPrefix() {
        var tracker = trackerAfterTwoStableSnapshots()
        let frozen = tracker.frozenStablePrefix
        let observation = tracker.observe(
            sessionID: sessionID,
            snapshotGeneration: 2,
            snapshotSampleCount: 1_400,
            audioSHA256: hashC,
            provenance: provenance,
            segments: segments(["changed", "words", "arrived", "late"])
        )

        #expect(observation == .rejected(.staleGeneration))
        #expect(tracker.frozenStablePrefix == frozen)
    }

    @Test
    func nonIncreasingSnapshotCannotMutateFrozenPrefix() {
        var tracker = trackerAfterTwoStableSnapshots()
        let frozen = tracker.frozenStablePrefix
        let observation = tracker.observe(
            sessionID: sessionID,
            snapshotGeneration: 3,
            snapshotSampleCount: 1_200,
            audioSHA256: hashC,
            provenance: provenance,
            segments: segments(["one", "two", "three", "four"])
        )

        #expect(observation == .rejected(.nonIncreasingSampleCount))
        #expect(tracker.frozenStablePrefix == frozen)
    }

    @Test
    func malformedHashAndOutOfBoundsSegmentsFailClosed() {
        var tracker = CumulativeTranscriptSnapshotTracker(
            sessionID: sessionID,
            provenance: provenance,
            sampleRate: 100,
            correctionHorizonSegments: 2
        )

        #expect(
            tracker.observe(
                sessionID: sessionID,
                snapshotGeneration: 1,
                snapshotSampleCount: 1_000,
                audioSHA256: "not-a-hash",
                provenance: provenance,
                segments: segments(["one", "two", "three", "four"])
            ) == .rejected(.invalidAudioIdentity)
        )
        #expect(
            tracker.observe(
                sessionID: sessionID,
                snapshotGeneration: 1,
                snapshotSampleCount: 500,
                audioSHA256: hashA,
                provenance: provenance,
                segments: segments(["one", "two", "three", "four"])
            ) == .rejected(.invalidSegmentCoverage)
        )
    }

    private let sessionID = "current-session"
    private let hashA = String(repeating: "a", count: 64)
    private let hashB = String(repeating: "b", count: 64)
    private let hashC = String(repeating: "c", count: 64)
    private let vocabularySHA256 = String(repeating: "d", count: 64)
    private var provenance: StreamingDecodeProvenance {
        StreamingDecodeProvenance(
            modelID: "whisper-large-v3",
            vocabularySHA256: vocabularySHA256,
            decoderConfigurationID: "english-default-v1",
            language: "en"
        )
    }

    private func trackerAfterFirstSnapshot()
        -> CumulativeTranscriptSnapshotTracker
    {
        var tracker = CumulativeTranscriptSnapshotTracker(
            sessionID: sessionID,
            provenance: provenance,
            sampleRate: 100,
            correctionHorizonSegments: 2
        )
        _ = tracker.observe(
            sessionID: sessionID,
            snapshotGeneration: 1,
            snapshotSampleCount: 1_000,
            audioSHA256: hashA,
            provenance: provenance,
            segments: segments(["one", "two", "three", "four"])
        )
        return tracker
    }

    private func trackerAfterTwoStableSnapshots()
        -> CumulativeTranscriptSnapshotTracker
    {
        var tracker = trackerAfterFirstSnapshot()
        _ = tracker.observe(
            sessionID: sessionID,
            snapshotGeneration: 2,
            snapshotSampleCount: 1_200,
            audioSHA256: hashB,
            provenance: provenance,
            segments: segments(["one", "two", "three", "four"])
        )
        return tracker
    }

    private func segments(_ texts: [String])
        -> [StreamingTranscriptSegment]
    {
        texts.enumerated().map { index, text in
            StreamingTranscriptSegment(
                text: text,
                startSeconds: Double(index * 2),
                endSeconds: Double((index + 1) * 2)
            )
        }
    }
}
