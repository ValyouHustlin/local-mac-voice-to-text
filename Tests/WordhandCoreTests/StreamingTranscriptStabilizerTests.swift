import Testing
@testable import WordhandCore

@Suite
struct StreamingTranscriptStabilizerTests {
    @Test
    func configurationClampsUnsafeTimingValues() {
        let configuration = StreamingTranscriptionConfiguration(
            decodeIntervalSeconds: 0,
            maximumWindowSeconds: 0.25,
            correctionHorizonSegments: -1
        )

        #expect(configuration.decodeIntervalSeconds == 0.5)
        #expect(configuration.maximumWindowSeconds == 1)
        #expect(configuration.correctionHorizonSegments == 0)
    }

    @Test
    func confirmsOnlySegmentsThatAgreeAcrossSuccessiveDecodes() {
        var stabilizer = StreamingTranscriptStabilizer(correctionHorizonSegments: 2)
        let first = segments(["one", "two", "three"], seconds: [0, 2, 4, 6])
        let second = segments(["one", "two", "three", "four"], seconds: [0, 2, 4, 6, 8])

        #expect(stabilizer.observe(first).newlyConfirmed.isEmpty)
        let update = stabilizer.observe(second)

        #expect(update.newlyConfirmed.map(\.text) == ["one", "two"])
        #expect(update.pending.map(\.text) == ["three", "four"])
    }

    @Test
    func leavesChangedWordsInsideTheCorrectionHorizon() {
        var stabilizer = StreamingTranscriptStabilizer(correctionHorizonSegments: 2)
        let first = segments(["send it", "Friday", "wait"], seconds: [0, 2, 4, 6])
        let corrected = segments(["send it", "Monday", "now"], seconds: [0, 2, 4, 6])

        _ = stabilizer.observe(first)
        let update = stabilizer.observe(corrected)

        #expect(update.newlyConfirmed.map(\.text) == ["send it"])
        #expect(update.pending.map(\.text) == ["Monday", "now"])
    }

    @Test
    func exposesAgreedSegmentsForBoundedWindowProgress() {
        var stabilizer = StreamingTranscriptStabilizer(correctionHorizonSegments: 2)
        let snapshot = segments(["one long segment"], seconds: [0, 20])

        _ = stabilizer.observe(snapshot)
        let update = stabilizer.observe(snapshot)

        #expect(update.newlyConfirmed.isEmpty)
        #expect(update.agreed.map(\.text) == ["one long segment"])
    }

    @Test
    func resetRequiresFreshAgreement() {
        var stabilizer = StreamingTranscriptStabilizer(correctionHorizonSegments: 0)
        let snapshot = segments(["stable"], seconds: [0, 2])

        _ = stabilizer.observe(snapshot)
        #expect(stabilizer.observe(snapshot).newlyConfirmed.map(\.text) == ["stable"])
        stabilizer.reset()
        #expect(stabilizer.observe(snapshot).newlyConfirmed.isEmpty)
    }

    private func segments(
        _ texts: [String],
        seconds: [Double]
    ) -> [StreamingTranscriptSegment] {
        zip(texts.indices, texts).map { index, text in
            StreamingTranscriptSegment(
                text: text,
                startSeconds: seconds[index],
                endSeconds: seconds[index + 1]
            )
        }
    }
}
