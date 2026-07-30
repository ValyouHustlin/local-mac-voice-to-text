import Foundation
import Testing
@testable import WordhandCore

@Suite
struct TranscriptProcessorTests {
    @Test
    func sanitizeRemovesKnownNonSpeechTokens() {
        let input = "hello [BLANK_AUDIO] (silence) *music playing* <|endoftext|> world"
        #expect(TranscriptProcessor.sanitize(input) == "hello world")
    }

    @Test
    func sanitizePreservesLegitimateParentheticalAndBracketedText() {
        let input = "Use Array[String] (not a set) and say *literally* this."
        #expect(TranscriptProcessor.sanitize(input) == input)
    }

    @Test
    func sanitizeRepairsMalformedWebSchemeSlashes() {
        let input = #"Visit https:\value.solutions and http:/example.com."#
        let expected = "Visit https://value.solutions and http://example.com."
        #expect(TranscriptProcessor.sanitize(input) == expected)
    }

    @Test
    func removesHesitationFillersAnywhereInTranscript() {
        let input = "Um, I, uh, think we should erm ship. Hmm... Please do."
        #expect(
            TranscriptProcessor.removeSpeechFillers(input)
                == "I think we should ship. Please do."
        )
    }

    @Test
    func removesStretchedFillersAndCleansSpacing() {
        let input = "Ummm this is uhhh ready — ermmm — ship it."
        #expect(
            TranscriptProcessor.removeSpeechFillers(input)
                == "this is ready ship it."
        )
    }

    @Test
    func removesFillersWithoutLeavingSentencePunctuationBehind() {
        #expect(TranscriptProcessor.removeSpeechFillers("Um! Ship it.") == "Ship it.")
        #expect(
            TranscriptProcessor.removeSpeechFillers("Done. Um. Start the next task.")
                == "Done. Start the next task."
        )
        #expect(TranscriptProcessor.removeSpeechFillers("Um, uh, hmm...") == "")
    }

    @Test
    func removingPostSentenceFillersCapitalizesTheNextWord() {
        let input = "Where is it? Hmm. Um, this is the end."
        #expect(
            TranscriptProcessor.removeSpeechFillers(input)
                == "Where is it? This is the end."
        )
    }

    @Test
    func preservesWordsAndAffirmationsThatContainFillerLetters() {
        let input = "The album, thumb, human, and hummus remain; uh-huh."
        #expect(TranscriptProcessor.removeSpeechFillers(input) == input)
    }

    @Test
    func dictionaryMeaningWinsBeforeFillerRemoval() async {
        let processor = TranscriptProcessor(dictionaryEntries: [
            DictionaryEntry(spokenForm: "UM", replacement: "University of Michigan"),
        ])
        #expect(
            await processor.process("UM has a campus.")
                == "University of Michigan has a campus."
        )
    }

    @Test
    func dictionaryAppliesLongestMatchWithoutCascading() async {
        let entries = [
            DictionaryEntry(spokenForm: "whisper", replacement: "Wispr"),
            DictionaryEntry(spokenForm: "whisper flow", replacement: "Wispr Flow"),
            DictionaryEntry(spokenForm: "Wispr Flow", replacement: "SHOULD NOT CASCADE"),
        ]
        let processor = TranscriptProcessor(dictionaryEntries: entries)
        #expect(await processor.process("whisper flow uses whisper") == "Wispr Flow uses Wispr")
    }

    @Test
    func wordModeUsesUnicodeBoundaries() {
        let matcher = DictionaryMatcher(entries: [
            DictionaryEntry(spokenForm: "cat", replacement: "dog", matchMode: .word),
        ])
        #expect(matcher.apply(to: "cat scatter bobcat cat.") == "dog scatter bobcat dog.")
    }

    @Test
    func caseSensitiveAndDisabledEntriesAreHonored() {
        let matcher = DictionaryMatcher(entries: [
            DictionaryEntry(
                spokenForm: "api",
                replacement: "API",
                matchMode: .word,
                isCaseSensitive: true
            ),
            DictionaryEntry(
                spokenForm: "secret",
                replacement: "visible",
                isEnabled: false
            ),
        ])
        #expect(matcher.apply(to: "api API secret") == "API API secret")
    }

    @Test
    func exposesFourExplicitWritingStyles() {
        #expect(
            TranscriptFormattingProfile.allCases
                == [.casual, .formatted, .professional, .aiCommunication]
        )
    }

    @Test
    func casualFallbackCleansFillersCasingAndPunctuation() async {
        let processor = TranscriptProcessor(formattingProfile: .casual)
        let result = await processor.process(
            "um this is a test and then we should ship it",
            target: .unknown
        )

        #expect(result == "This is a test. Then we should ship it.")
    }

    @Test
    func appliesEarlierPhraseReplacementAfterImmediateRepairs() async {
        let processor = TranscriptProcessor()
        let result = await processor.processResult(
            "Send Friday—wait, no, Tuesday. "
                + "Command correction. Replace Tuesday with Monday."
        )

        #expect(result.text == "Send Monday.")
        #expect(result.notices.isEmpty)
    }

    @Test
    func rejectedEarlierPhraseReplacementPreservesTextAndReportsReason() async {
        let processor = TranscriptProcessor(
            formattingProfile: .professional
        )
        let input =
            "Friday is possible. Friday is preferred. "
            + "Command correction, replace Friday with Monday."
        let result = await processor.processResult(input)

        #expect(result.text == input)
        #expect(
            result.notices
                == [.spokenReplacementRejected(.targetRepeated)]
        )
    }

    @Test
    func migratesLegacyWritingStyleValues() throws {
        let decoder = JSONDecoder()
        let legacyValues: [(String, TranscriptFormattingProfile)] = [
            ("automatic", .formatted),
            ("polished", .formatted),
            ("aiPrompt", .aiCommunication),
            ("verbatim", .casual),
        ]

        for (storedValue, expected) in legacyValues {
            let profile = try decoder.decode(
                TranscriptFormattingProfile.self,
                from: Data("\"\(storedValue)\"".utf8)
            )
            #expect(profile == expected)
        }
    }

    @Test
    func agentStructureDoesNotForceOrdinaryProseIntoBullets() {
        #expect(
            TranscriptProcessor.structureForAI(
                "The current app works well. I think the model is accurate. "
                    + "The remaining concern is latency."
            ) == "The current app works well. I think the model is accurate. "
                + "The remaining concern is latency."
        )
        #expect(
            TranscriptProcessor.structureForAI(
                "Goal:\nImprove dictation.\n\nConstraints:\n- Keep everything local."
            ) == "Goal:\nImprove dictation.\n\nConstraints:\n- Keep everything local."
        )
    }

    @Test
    func professionalStyleRemovesOnlyOpeningThroatClearing() {
        #expect(
            TranscriptProcessor.professionalize(
                "Okay, so I think we should ship. Maybe wait for review."
            ) == "I think we should ship. Maybe wait for review."
        )
        #expect(
            TranscriptProcessor.professionalize(
                "I think we should ship. Maybe wait for review."
            ) == "I think we should ship. Maybe wait for review."
        )
    }
}
