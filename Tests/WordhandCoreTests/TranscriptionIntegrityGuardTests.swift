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
            sampleRate: 16_000
        )

        #expect(issues.contains(.activeAudioAfterUnpunctuatedEnding))
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

        #expect(!issues.contains(.activeAudioAfterUnpunctuatedEnding))
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
            issues: [.activeAudioAfterUnpunctuatedEnding],
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
            issues: [.activeAudioAfterUnpunctuatedEnding],
            conditionedTerms: ["Wordhand"]
        )

        #expect(selected == primary)
    }

    private func energeticAudio(seconds: Int) -> [Float] {
        (0..<(seconds * 16_000)).map { index in
            index.isMultiple(of: 2) ? 0.03 : -0.03
        }
    }
}
