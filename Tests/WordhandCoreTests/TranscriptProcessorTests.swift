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
    func agentStructureTurnsThreeOrMoreSentencesIntoBullets() {
        #expect(
            TranscriptProcessor.structureForAI(
                "Ship the app. Keep the rollback. Report the result."
            ) == """
            - Ship the app.
            - Keep the rollback.
            - Report the result.
            """
        )
        #expect(
            TranscriptProcessor.structureForAI("Ship the app. Report the result.")
                == "Ship the app. Report the result."
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
