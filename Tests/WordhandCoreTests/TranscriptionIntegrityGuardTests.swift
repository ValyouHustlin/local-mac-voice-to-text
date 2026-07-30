import Testing
@testable import WordhandCore

@Suite
struct TranscriptionIntegrityGuardTests {
    @Test
    func detectsTruncatedConditioningTermAtTheBeginning() {
        let issues = TranscriptionIntegrityGuard.issues(
            in: "Aaron Browne- Yeah, so at this point I want to finish.",
            conditionedTerms: ["Aaron Browne-Moore", "tmux"],
            audio: energeticAudio(seconds: 2),
            sampleRate: 16_000
        )

        #expect(issues.contains(.leadingConditioningArtifact))
    }

    @Test
    func preservesANameThatWasActuallyUsedAsTheSentenceSubject() {
        let issues = TranscriptionIntegrityGuard.issues(
            in: "Aaron Browne-Moore finished the Wordhand release.",
            conditionedTerms: ["Aaron Browne-Moore", "Wordhand"],
            audio: energeticAudio(seconds: 2),
            sampleRate: 16_000
        )

        #expect(!issues.contains(.leadingConditioningArtifact))
    }

    @Test
    func preservesACompleteConditionedTermBeforeAColon() {
        let issues = TranscriptionIntegrityGuard.issues(
            in: "Wordhand: ship the corrected build.",
            conditionedTerms: ["Wordhand"],
            audio: energeticAudio(seconds: 2),
            sampleRate: 16_000
        )

        #expect(!issues.contains(.leadingConditioningArtifact))
    }

    @Test
    func detectsAnUnpunctuatedEndingWhileTheAudioTailIsActive() {
        let issues = TranscriptionIntegrityGuard.issues(
            in: "Once it is fit and finished, we'll go into doing",
            conditionedTerms: ["Wordhand"],
            audio: energeticAudio(seconds: 4),
            sampleRate: 16_000,
            lastDecodedSecond: nil
        )

        #expect(issues.contains(.activeAudioAfterDecodedEnding))
    }

    @Test
    func decoderCoverageCannotSuppressSuspiciousUnpunctuatedSpeech() {
        let issues = TranscriptionIntegrityGuard.issues(
            in: "This is a deliberate sentence fragment",
            conditionedTerms: ["Wordhand"],
            audio: energeticAudio(seconds: 4),
            sampleRate: 16_000,
            lastDecodedSecond: 3.9
        )

        #expect(issues.contains(.activeAudioAfterDecodedEnding))
    }

    @Test
    func activeSpeechAfterDecodedSegmentTriggersRetryEvenWithPunctuation() {
        let issues = TranscriptionIntegrityGuard.issues(
            in: "The decoder stopped here.",
            conditionedTerms: ["Wordhand"],
            audio: energeticAudio(seconds: 4),
            sampleRate: 16_000,
            lastDecodedSecond: 2
        )

        #expect(issues.contains(.activeAudioAfterDecodedEnding))
    }

    @Test
    func silenceAfterDecodedSegmentDoesNotTriggerRetry() {
        let speech = energeticAudio(seconds: 2)
        let silence = Array(repeating: Float.zero, count: 32_000)
        let issues = TranscriptionIntegrityGuard.issues(
            in: "The decoder covered all spoken audio.",
            conditionedTerms: ["Wordhand"],
            audio: speech + silence,
            sampleRate: 16_000,
            lastDecodedSecond: 2
        )

        #expect(!issues.contains(.activeAudioAfterDecodedEnding))
    }

    @Test
    func briefPostSegmentNoiseDoesNotTriggerRetry() {
        var audio = Array(repeating: Float.zero, count: 64_000)
        for index in 40_000..<40_160 {
            audio[index] = index.isMultiple(of: 2) ? 0.03 : -0.03
        }
        let issues = TranscriptionIntegrityGuard.issues(
            in: "The decoder covered the actual speech.",
            conditionedTerms: ["Wordhand"],
            audio: audio,
            sampleRate: 16_000,
            lastDecodedSecond: 2
        )

        #expect(!issues.contains(.activeAudioAfterDecodedEnding))
    }

    @Test
    func silentTailDoesNotTriggerAQualityRetry() {
        let speech = energeticAudio(seconds: 2)
        let silence = Array(repeating: Float.zero, count: 32_000)
        let issues = TranscriptionIntegrityGuard.issues(
            in: "This deliberate fragment has no punctuation",
            conditionedTerms: ["Wordhand"],
            audio: speech + silence,
            sampleRate: 16_000
        )

        #expect(!issues.contains(.activeAudioAfterDecodedEnding))
    }

    @Test
    func cleanRetryReplacesAConditioningArtifact() {
        let primary = "Aaron Browne- Yeah, so at this point I want to finish."
        let retry = "Yeah, so at this point I want to finish."

        let selected = TranscriptionIntegrityGuard.select(
            primary: primary,
            retry: retry,
            issues: [.leadingConditioningArtifact],
            conditionedTerms: ["Aaron Browne-Moore"]
        )

        #expect(selected == retry)
    }

    @Test
    func unrelatedRetryCannotReplaceAConditioningArtifact() {
        let primary = "Aaron Browne- Yeah, so at this point I want to finish."
        let retry = "Completely unrelated words can have the same overall length."

        let selected = TranscriptionIntegrityGuard.select(
            primary: primary,
            retry: retry,
            issues: [.leadingConditioningArtifact],
            conditionedTerms: ["Aaron Browne-Moore"]
        )

        #expect(selected == primary)
    }

    @Test
    func longerCompleteRetryReplacesAnIncompleteEnding() {
        let primary = "Once it is fit and finished, we'll go into doing"
        let retry = "Once it is fit and finished, we'll go into doing the launch posts."

        let selected = TranscriptionIntegrityGuard.select(
            primary: primary,
            retry: retry,
            issues: [.activeAudioAfterDecodedEnding],
            conditionedTerms: ["Wordhand"]
        )

        #expect(selected == retry)
    }

    @Test
    func unrelatedLongerRetryCannotReplaceAnIncompleteEnding() {
        let primary = "Once it is fit and finished, we'll go into doing"
        let retry = "A different decoder hallucination with several extra words should never win."

        let selected = TranscriptionIntegrityGuard.select(
            primary: primary,
            retry: retry,
            issues: [.activeAudioAfterDecodedEnding],
            conditionedTerms: ["Wordhand"]
        )

        #expect(selected == primary)
    }

    @Test
    func mergesAnOverlappingTailRecoveryWithoutRewritingEarlierSpeech() {
        let primary = """
        I do not think we need that. Once it is fit and finished, we'll go into doing
        """
        let recovery = """
        I think we need that. Once it is finished, we'll go into doing the launch post. \
        Just use what we have.
        """

        let merged = TranscriptionIntegrityGuard.mergeTail(
            primary: primary,
            recovery: recovery
        )

        #expect(
            merged
                == "I do not think we need that. Once it is fit and finished, "
                    + "we'll go into doing the launch post. Just use what we have."
        )
    }

    @Test
    func tailRecoveryPreservesRecoveredSentenceBoundary() {
        let merged = TranscriptionIntegrityGuard.mergeTail(
            primary: "Please send this when we finish",
            recovery: "send this when we finish. Then archive the receipt."
        )

        #expect(
            merged == "Please send this when we finish. Then archive the receipt."
        )
    }

    @Test
    func tailRecoveryRequiresAStableFourWordOverlap() {
        let merged = TranscriptionIntegrityGuard.mergeTail(
            primary: "The primary decode stopped here",
            recovery: "stopped here and invented unrelated material"
        )

        #expect(merged == nil)
    }

    @Test
    func tailRecoveryRejectsAnAmbiguousRepeatedOverlap() {
        let merged = TranscriptionIntegrityGuard.mergeTail(
            primary: "Please remember we need to do that",
            recovery: """
            We need to do that, and later we need to do that before launch.
            """
        )

        #expect(merged == nil)
    }

    private func energeticAudio(seconds: Int) -> [Float] {
        (0..<(seconds * 16_000)).map { index in
            index.isMultiple(of: 2) ? 0.03 : -0.03
        }
    }
}
