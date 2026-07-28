import Testing
@testable import ParrotCore

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
    func dictionaryAppliesLongestMatchWithoutCascading() {
        let entries = [
            DictionaryEntry(spokenForm: "whisper", replacement: "Wispr"),
            DictionaryEntry(spokenForm: "whisper flow", replacement: "Wispr Flow"),
            DictionaryEntry(spokenForm: "Wispr Flow", replacement: "SHOULD NOT CASCADE"),
        ]
        let processor = TranscriptProcessor(dictionaryEntries: entries)
        #expect(processor.process("whisper flow uses whisper") == "Wispr Flow uses Wispr")
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
}
