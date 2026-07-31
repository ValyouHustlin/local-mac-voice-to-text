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
    func insertsOneExactPhraseAfterOneUniqueAnchorWithoutRemovingBodyText() {
        let examples = [
            (
                "Send the proposal Friday. Command correction, insert at noon after Friday.",
                "Send the proposal Friday at noon."
            ),
            (
                "Email Aaron Browne-Moore today. Command correction, insert and Valyou after Aaron Browne-Moore.",
                "Email Aaron Browne-Moore and Valyou today."
            ),
            (
                "We should deploy Friday. Command correction, insert not after should.",
                "We should not deploy Friday."
            ),
            (
                "Use API v2 today. Command correction, insert ONLY after api.",
                "Use API ONLY v2 today."
            ),
        ]

        for (input, expected) in examples {
            let result = SpokenReplacementCommandEngine.apply(to: input)
            #expect(result.text == expected)
            #expect(result.outcome == .applied)
        }
    }

    @Test
    func insertionPreservesEveryOriginalBodyByteInOrder() throws {
        let body = "Keep  API-v2, Aaron Browne-Moore; and Friday!"
        let inserted = " at 15.2"
        let result = SpokenReplacementCommandEngine.apply(
            to: body
                + " Command correction, insert at 15.2 after API-v2."
        )

        #expect(result.outcome == .applied)
        let insertedRange = try #require(result.text.range(of: inserted))
        var restored = result.text
        restored.removeSubrange(insertedRange)
        #expect(restored == body)
    }

    @Test
    func insertionRequiresOneExactUniqueBoundedAnchor() {
        let examples: [(String, SpokenReplacementCommandRejection)] = [
            (
                "Friday is possible. Friday is preferred. Command correction, insert not after Friday.",
                .targetRepeated
            ),
            (
                "Send Friday. Command correction, insert at noon after Tuesday.",
                .targetMissing
            ),
            (
                "Concatenate values. Command correction, insert black after cat.",
                .targetMissing
            ),
            (
                "Visit cat.example. Command correction, insert black after cat.",
                .targetMissing
            ),
            (
                "Use version 14.5. Command correction, insert point after 14.",
                .targetMissing
            ),
            (
                "Command correction, insert at noon after Friday.",
                .missingBody
            ),
            (
                "Send Friday at noon. Command correction, insert at noon after Friday.",
                .noChange
            ),
        ]

        for (input, reason) in examples {
            let result = SpokenReplacementCommandEngine.apply(to: input)
            #expect(result.text == input)
            #expect(result.outcome == .rejected(reason))
        }
    }

    @Test
    func malformedOrAmbiguousInsertionCommandsFailClosedByteForByte() {
        let tooManyWords = (1...9).map { "word\($0)" }.joined(separator: " ")
        let examples: [(String, SpokenReplacementCommandRejection)] = [
            (
                "Send Friday. Command correction, insert at noon after Friday after review.",
                .ambiguousDelimiter
            ),
            (
                "Send Friday. Command correction, insert at noon after Friday. Continue working.",
                .nonTerminal
            ),
            (
                "Tell command correction, insert at noon after Friday.",
                .nonStandalone
            ),
            (
                "Keep command correction here. Command correction, insert at noon after Friday.",
                .multipleCommands
            ),
            (
                "Send Friday. Command correction, insert command correction after Friday.",
                .multipleCommands
            ),
            (
                "Send Friday. Command correction, insert after Friday.",
                .missingPayload
            ),
            (
                "Send Friday. Command correction, insert at noon after.",
                .missingPayload
            ),
            (
                "Send Friday. Command correction, insert \(tooManyWords) after Friday.",
                .payloadTooLarge
            ),
            (
                "He wrote “Command correction, insert at noon after Friday.”",
                .nonStandalone
            ),
            (
                "Send Friday. Command correction, insert at noon after Friday?",
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
