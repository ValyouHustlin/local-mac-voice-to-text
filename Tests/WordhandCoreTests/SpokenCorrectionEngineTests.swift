import Testing
@testable import WordhandCore

@Suite
struct SpokenCorrectionEngineTests {
    @Test
    func replacesTheLastWordAfterWaitNo() {
        #expect(
            SpokenCorrectionEngine.apply(
                to: "Send it Friday—wait, no, Monday."
            ) == "Send it Monday."
        )
    }

    @Test
    func replacesAProperNameAfterIMeant() {
        #expect(
            SpokenCorrectionEngine.apply(
                to: "Email Blumira—sorry, I meant Valyou."
            ) == "Email Valyou."
        )
    }

    @Test
    func replacesAValueWithAMultiwordValue() {
        #expect(
            SpokenCorrectionEngine.apply(
                to: "The price is fifteen—make that fifty dollars."
            ) == "The price is fifty dollars."
        )
    }

    @Test
    func scratchThatReplacesTheCurrentSentence() {
        #expect(
            SpokenCorrectionEngine.apply(
                to: "Keep the draft. We should launch—actually, scratch that—we should wait."
            ) == "Keep the draft. We should wait."
        )
    }

    @Test
    func replacesAMultiwordProperNameWithoutDroppingTheVerb() {
        #expect(
            SpokenCorrectionEngine.apply(
                to: "Contact Aaron Brown—sorry, I meant Aaron Browne-Moore."
            ) == "Contact Aaron Browne-Moore."
        )
    }

    @Test
    func handlesMultipleCorrectionsInOneTranscript() {
        #expect(
            SpokenCorrectionEngine.apply(
                to: "Send it Friday—wait, no, Monday. Email Blumira—I meant Valyou."
            ) == "Send it Monday. Email Valyou."
        )
    }

    @Test
    func removesSafeImmediateFalseStarts() {
        #expect(
            SpokenCorrectionEngine.apply(
                to: "I, I think we should should ship."
            ) == "I think we should ship."
        )
    }

    @Test
    func preservesSemanticNoAndMeaningfulRepetition() {
        let input = "No, do not send it. I had had enough."
        #expect(SpokenCorrectionEngine.apply(to: input) == input)
    }

    @Test
    func leavesAmbiguousIMeanUsageUntouched() {
        let input = "I mean the arithmetic average, not the median."
        #expect(SpokenCorrectionEngine.apply(to: input) == input)
    }

    @Test
    func preservesOrdinaryIMeantStatements() {
        let examples = [
            "I meant that sincerely.",
            "What I meant was that Monday works better.",
        ]
        for input in examples {
            #expect(SpokenCorrectionEngine.apply(to: input) == input)
        }
    }

    @Test
    func emptyCorrectionMarkerDoesNotDeletePriorText() {
        #expect(
            SpokenCorrectionEngine.apply(to: "Send it Friday—wait, no.")
                == "Send it Friday."
        )
    }
}
