import Testing
@testable import WordhandCore

@Suite
struct EmptyTranscriptRecoveryPolicyTests {
    @Test
    func activeAudioWithAnEmptyPrimaryRequiresPromptFreeRetry() {
        let signal = AudioSignalMetrics(
            sampleCount: 444_647,
            rms: 0.0175,
            peak: 0.224,
            clippedSampleFraction: 0,
            activeWindowFraction: 0.973
        )

        #expect(
            EmptyTranscriptRecoveryPolicy.action(
                primaryText: "",
                signal: signal
            ) == .retryPromptFree
        )
        #expect(
            EmptyTranscriptRecoveryPolicy.select(
                primaryText: "",
                retryText: "Recovered beginning and ending."
            ) == "Recovered beginning and ending."
        )
    }

    @Test
    func recoveryExecutorRunsOneRetryAndReturnsItsCompleteText() async {
        let signal = AudioSignalMetrics(
            sampleCount: 444_647,
            rms: 0.0175,
            peak: 0.224,
            clippedSampleFraction: 0,
            activeWindowFraction: 0.973
        )
        var retryCount = 0

        let result = await EmptyTranscriptRecoveryPolicy.recover(
            primaryText: "",
            signal: signal,
            promptFreeRetry: {
                retryCount += 1
                return "Recovered beginning, number 14.5, and ending."
            }
        )

        #expect(retryCount == 1)
        #expect(result.retryPerformed)
        #expect(result.outcome == .recovered)
        #expect(
            result.text
                == "Recovered beginning, number 14.5, and ending."
        )
    }

    @Test
    func quietAudioDoesNotPayForASecondDecode() async {
        let signal = AudioSignalMetrics(
            sampleCount: 160_000,
            rms: 0.0002,
            peak: 0.004,
            clippedSampleFraction: 0,
            activeWindowFraction: 0
        )

        #expect(
            EmptyTranscriptRecoveryPolicy.action(
                primaryText: "   ",
                signal: signal
            ) == .treatAsSilence
        )
        var retryCount = 0
        let result = await EmptyTranscriptRecoveryPolicy.recover(
            primaryText: "",
            signal: signal,
            promptFreeRetry: {
                retryCount += 1
                return "must not run"
            }
        )
        #expect(retryCount == 0)
        #expect(!result.retryPerformed)
        #expect(result.outcome == .quietAudio)
    }

    @Test
    func nonemptyPrimaryRemainsAuthoritative() async {
        let signal = AudioSignalMetrics(
            sampleCount: 160_000,
            rms: 0.02,
            peak: 0.2,
            clippedSampleFraction: 0,
            activeWindowFraction: 1
        )

        #expect(
            EmptyTranscriptRecoveryPolicy.action(
                primaryText: "Do not deploy Friday.",
                signal: signal
            ) == .acceptPrimary
        )
        #expect(
            EmptyTranscriptRecoveryPolicy.select(
                primaryText: "Do not deploy Friday.",
                retryText: "Deploy Friday."
            ) == "Do not deploy Friday."
        )
        var retryCount = 0
        let result = await EmptyTranscriptRecoveryPolicy.recover(
            primaryText: "Do not deploy Friday.",
            signal: signal,
            promptFreeRetry: {
                retryCount += 1
                return "Deploy Friday."
            }
        )
        #expect(retryCount == 0)
        #expect(result.text == "Do not deploy Friday.")
        #expect(result.outcome == .notNeeded)
    }

    @Test
    func anEmptyRetryCannotInventARecovery() {
        #expect(
            EmptyTranscriptRecoveryPolicy.select(
                primaryText: "",
                retryText: " \n "
            ).isEmpty
        )
    }
}
