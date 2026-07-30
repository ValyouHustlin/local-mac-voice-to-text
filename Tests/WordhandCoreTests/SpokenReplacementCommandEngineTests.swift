import Testing
@testable import WordhandCore

@Suite
struct SpokenReplacementCommandEngineTests {
    @Test
    func replacesOneUniqueEarlierPhraseAndRemovesTheTerminalCommand() {
        let result = SpokenReplacementCommandEngine.apply(
            to: "Send the proposal Friday. Command correction. Replace Friday with Monday."
        )

        #expect(result.text == "Send the proposal Monday.")
        #expect(result.outcome == .applied)
    }

    @Test
    func replacesBoundedMultiwordUnicodeAndOrthographicTargets() {
        let examples = [
            (
                "Email Aaron Brown-Moore today. Command correction, replace Aaron Brown-Moore with Aaron Browne-Moore.",
                "Email Aaron Browne-Moore today."
            ),
            (
                "The client is valyou. Command correction: replace valyou with Valyou.",
                "The client is Valyou."
            ),
            (
                "Use version 14.5 today. Command correction—replace 14.5 with 15.2.",
                "Use version 15.2 today."
            ),
            (
                "We should deploy Friday. Command correction. Replace should deploy with should not deploy.",
                "We should not deploy Friday."
            ),
        ]

        for (input, expected) in examples {
            let result = SpokenReplacementCommandEngine.apply(to: input)
            #expect(result.text == expected)
            #expect(result.outcome == .applied)
        }
    }

    @Test
    func noReservedCommandReturnsTheInputByteForByte() {
        let input = "  Keep  deliberate spacing.\nAnd line breaks.  "
        let result = SpokenReplacementCommandEngine.apply(to: input)

        #expect(result.text == input)
        #expect(result.outcome == .noCommand)
    }

    @Test
    func missingOrRepeatedTargetsFailClosed() {
        let examples: [(String, SpokenReplacementCommandRejection)] = [
            (
                "Send the proposal Friday. Command correction, replace Tuesday with Monday.",
                .targetMissing
            ),
            (
                "Friday is possible. Friday is preferred. Command correction, replace Friday with Monday.",
                .targetRepeated
            ),
            (
                "Ha ha ha. Command correction, replace ha ha with goodbye.",
                .targetRepeated
            ),
            (
                "Alpha alpha alpha. Command correction, replace alpha alpha with beta.",
                .targetRepeated
            ),
            (
                "Concatenate the values. Command correction, replace cat with dog.",
                .targetMissing
            ),
            (
                "Use version 14.5. Command correction, replace 14 with 15.",
                .targetMissing
            ),
            (
                "Visit cat.example. Command correction, replace cat with dog.",
                .targetMissing
            ),
            (
                "Command correction, replace Friday with Monday.",
                .missingBody
            ),
        ]

        for (input, reason) in examples {
            let result = SpokenReplacementCommandEngine.apply(to: input)
            #expect(result.text == input)
            #expect(result.outcome == .rejected(reason))
        }
    }

    @Test
    func malformedOrAmbiguousCommandsFailClosed() {
        let tooManyWords = (1...9).map { "word\($0)" }.joined(separator: " ")
        let examples: [(String, SpokenReplacementCommandRejection)] = [
            (
                "Send Friday. Command correction, replace Friday with Monday with Tuesday.",
                .ambiguousDelimiter
            ),
            (
                "Send Friday. Command correction, replace Friday with Monday. Continue working.",
                .nonTerminal
            ),
            (
                "Tell command correction, replace Friday with Monday.",
                .nonStandalone
            ),
            (
                "Keep the phrase command correction here. Command correction, replace phrase with wording.",
                .multipleCommands
            ),
            (
                "Send Friday. Command correction, replace Friday with command correction replace Monday.",
                .multipleCommands
            ),
            (
                "Send Friday. Command correction, replace Friday with.",
                .missingPayload
            ),
            (
                "Send Friday. Command correction, replace Friday with \(tooManyWords).",
                .payloadTooLarge
            ),
            (
                "He wrote “Command correction, replace Friday with Monday.”",
                .nonStandalone
            ),
            (
                "Send Friday. Command correction, replace Friday with Monday?",
                .questionCommand
            ),
        ]

        for (input, reason) in examples {
            let result = SpokenReplacementCommandEngine.apply(to: input)
            #expect(result.text == input)
            #expect(result.outcome == .rejected(reason))
        }
    }

    @Test
    func commandRecognitionIsCaseInsensitiveButReplacementCasingIsExact() {
        let result = SpokenReplacementCommandEngine.apply(
            to: "Use draft status. COMMAND CORRECTION. REPLACE DRAFT STATUS WITH Final Status."
        )

        #expect(result.text == "Use Final Status.")
        #expect(result.outcome == .applied)
    }
}
