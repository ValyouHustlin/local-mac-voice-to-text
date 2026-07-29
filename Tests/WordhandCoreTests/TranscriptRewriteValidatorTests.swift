import Testing
@testable import WordhandCore

@Suite
struct TranscriptRewriteValidatorTests {
    @Test
    func acceptsAConservativeStructuredRewrite() {
        let original = """
        we need a minimal popup keep it local and do not change the clipboard
        add an x so I can cancel it
        """
        let candidate = """
        We need a minimal pop-up. Keep it local, and do not change the clipboard.

        Add an X so I can cancel it.
        """

        #expect(TranscriptRewriteValidator.isAcceptable(candidate: candidate, original: original))
    }

    @Test
    func rejectsDroppedNumbersAndTechnicalTerms() {
        let original = "Use M5 Max with 128GB and keep src/App_Model.swift unchanged."

        #expect(!TranscriptRewriteValidator.isAcceptable(
            candidate: "Use the Max model and keep the source file unchanged.",
            original: original
        ))
    }

    @Test
    func rejectsDroppedNegation() {
        #expect(!TranscriptRewriteValidator.isAcceptable(
            candidate: "Send the transcript to the service.",
            original: "Do not send the transcript to the service."
        ))
    }

    @Test
    func acceptsEquivalentNegationSpelling() {
        #expect(TranscriptRewriteValidator.isAcceptable(
            candidate: "You cannot upload it.",
            original: "You can't upload it."
        ))
    }

    @Test
    func rejectsImplausibleLengthChanges() {
        #expect(!TranscriptRewriteValidator.isAcceptable(
            candidate: "Build it.",
            original: "Build the native Mac application with history, dictionary, hotkeys, and reliable paste behavior."
        ))
    }
}
