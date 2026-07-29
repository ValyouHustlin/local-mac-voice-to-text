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
    func automaticProfileSelectsAIPromptForCodingAndTerminalApps() {
        let developmentTargets = [
            TranscriptTarget(
                bundleIdentifier: "com.apple.Terminal",
                applicationName: "Terminal"
            ),
            TranscriptTarget(
                bundleIdentifier: "com.googlecode.iterm2",
                applicationName: "iTerm2"
            ),
            TranscriptTarget(
                bundleIdentifier: "dev.warp.Warp-Stable",
                applicationName: "Warp"
            ),
            TranscriptTarget(
                bundleIdentifier: "com.mitchellh.ghostty",
                applicationName: "Ghostty"
            ),
            TranscriptTarget(
                bundleIdentifier: "com.microsoft.VSCode",
                applicationName: "Visual Studio Code"
            ),
        ]
        for target in developmentTargets {
            #expect(
                TranscriptFormattingProfile.automatic.resolved(for: target) == .aiPrompt
            )
        }
        #expect(
            TranscriptFormattingProfile.automatic.resolved(
                for: TranscriptTarget(
                    bundleIdentifier: "com.apple.TextEdit",
                    applicationName: "TextEdit"
                )
            ) == .polished
        )
    }

    @Test
    func polishedFallbackCleansFillersCasingAndPunctuation() async {
        let processor = TranscriptProcessor(formattingProfile: .polished)
        let result = await processor.process(
            "um this is a test and then we should ship it",
            target: .unknown
        )

        #expect(result == "This is a test. Then we should ship it.")
    }

    @Test
    func verbatimProfileOnlySanitizesAndAppliesDictionary() async {
        let processor = TranscriptProcessor(
            dictionaryEntries: [
                DictionaryEntry(spokenForm: "word hand", replacement: "Wordhand"),
            ],
            formattingProfile: .verbatim
        )
        let result = await processor.process(
            "um word hand stays lowercase",
            target: .unknown
        )

        #expect(result == "um Wordhand stays lowercase")
    }
}
