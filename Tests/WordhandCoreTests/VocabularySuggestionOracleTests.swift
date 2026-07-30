import Foundation
import Testing
@testable import WordhandCore

@Suite
struct VocabularySuggestionOracleTests {
    @Test
    func repeatedPairedCanonicalCorrectionProducesOneSuggestion() {
        let first = record(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            createdAt: Date(timeIntervalSince1970: 100),
            raw: "Send the proposal to value tomorrow",
            text: "Send the proposal to value tomorrow.",
            reference: "Send the proposal to Valyou tomorrow."
        )
        let second = record(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            createdAt: Date(timeIntervalSince1970: 200),
            raw: "The value team approved it",
            text: "The value team approved it.",
            reference: "The Valyou team approved it."
        )

        let suggestions = VocabularySuggestionOracle.suggestions(
            records: [first, second],
            retainedRecordingIDs: [first.id, second.id],
            existingEntries: []
        )

        let suggestion = suggestions.first
        #expect(suggestions.count == 1)
        #expect(suggestion?.canonicalTerm == "Valyou")
        #expect(suggestion?.supportCount == 2)
        #expect(suggestion?.supportingTranscriptIDs == [first.id, second.id])
        #expect(suggestion?.latestSupportingTranscriptID == second.id)
    }

    @Test
    func outputIsDeterministicAndUsesNewestCanonicalCasing() {
        let first = record(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
            createdAt: Date(timeIntervalSince1970: 100),
            raw: "open word hand",
            text: "Open word hand.",
            reference: "Open Wordhand."
        )
        let second = record(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
            createdAt: Date(timeIntervalSince1970: 200),
            raw: "use word hand today",
            text: "Use word hand today.",
            reference: "Use Wordhand today."
        )
        let ids: Set<UUID> = [first.id, second.id]

        let forward = VocabularySuggestionOracle.suggestions(
            records: [first, second],
            retainedRecordingIDs: ids,
            existingEntries: []
        )
        let reverse = VocabularySuggestionOracle.suggestions(
            records: [second, first],
            retainedRecordingIDs: ids,
            existingEntries: []
        )

        #expect(forward == reverse)
        #expect(forward.first?.canonicalTerm == "Wordhand")
    }

    @Test
    func oneCorrectionOrMissingRecordingAbstains() {
        let first = record(
            raw: "Send it to value",
            text: "Send it to value.",
            reference: "Send it to Valyou."
        )
        let second = record(
            raw: "Ask the value team",
            text: "Ask the value team.",
            reference: "Ask the Valyou team."
        )

        #expect(VocabularySuggestionOracle.suggestions(
            records: [first],
            retainedRecordingIDs: [first.id],
            existingEntries: []
        ).isEmpty)
        #expect(VocabularySuggestionOracle.suggestions(
            records: [first, second],
            retainedRecordingIDs: [first.id],
            existingEntries: []
        ).isEmpty)
    }

    @Test
    func formattingAndSemanticCorrectionsAbstain() {
        let formatting = [
            record(raw: "hello world", text: "Hello world.", reference: "Hello, world!"),
            record(raw: "hello world", text: "Hello world.", reference: "HELLO WORLD"),
        ]
        let semantic = [
            record(raw: "meet Friday", text: "Meet Friday.", reference: "Meet Monday."),
            record(raw: "ship Friday", text: "Ship Friday.", reference: "Ship Monday."),
        ]
        let commonSpelling = [
            record(raw: "use colour", text: "Use colour.", reference: "Use color."),
            record(raw: "choose colour", text: "Choose colour.", reference: "Choose color."),
        ]
        let typography = [
            record(raw: "don't stop", text: "Don't stop.", reference: "Don’t stop."),
            record(raw: "don't wait", text: "Don't wait.", reference: "Don’t wait."),
        ]
        let semanticMerge = [
            record(raw: "go now here", text: "Go now here.", reference: "Go nowhere."),
            record(raw: "stay now here", text: "Stay now here.", reference: "Stay nowhere."),
        ]

        #expect(VocabularySuggestionOracle.suggestions(
            records: formatting,
            retainedRecordingIDs: Set(formatting.map(\.id)),
            existingEntries: []
        ).isEmpty)
        #expect(VocabularySuggestionOracle.suggestions(
            records: semantic,
            retainedRecordingIDs: Set(semantic.map(\.id)),
            existingEntries: []
        ).isEmpty)
        #expect(VocabularySuggestionOracle.suggestions(
            records: commonSpelling,
            retainedRecordingIDs: Set(commonSpelling.map(\.id)),
            existingEntries: []
        ).isEmpty)
        #expect(VocabularySuggestionOracle.suggestions(
            records: typography,
            retainedRecordingIDs: Set(typography.map(\.id)),
            existingEntries: []
        ).isEmpty)
        #expect(VocabularySuggestionOracle.suggestions(
            records: semanticMerge,
            retainedRecordingIDs: Set(semanticMerge.map(\.id)),
            existingEntries: []
        ).isEmpty)
    }

    @Test
    func unsafeOrAmbiguousEditsAbstain() {
        let unsafePairs = [
            (
                "Do deploy Friday",
                "Do not deploy Friday",
                "Do deploy Monday",
                "Do not deploy Monday"
            ),
            (
                "Use version fourteen",
                "Use version 14",
                "Ship version fourteen",
                "Ship version 14"
            ),
            (
                "Alpha beta gamma",
                "Alpha delta epsilon",
                "Alpha beta today",
                "Alpha delta today"
            ),
        ]

        for pair in unsafePairs {
            let records = [
                record(raw: pair.0, text: pair.0, reference: pair.1),
                record(raw: pair.2, text: pair.2, reference: pair.3),
            ]
            #expect(VocabularySuggestionOracle.suggestions(
                records: records,
                retainedRecordingIDs: Set(records.map(\.id)),
                existingEntries: []
            ).isEmpty)
        }
    }

    @Test
    func competingCorrectionOrExistingVocabularyAbstains() {
        let first = record(
            raw: "Send to value",
            text: "Send to value.",
            reference: "Send to Valyou."
        )
        let second = record(
            raw: "Ask value",
            text: "Ask value.",
            reference: "Ask Valyou."
        )
        let competing = record(
            raw: "Call value",
            text: "Call value.",
            reference: "Call Valu."
        )
        let paired = Set([first.id, second.id, competing.id])

        #expect(VocabularySuggestionOracle.suggestions(
            records: [first, second, competing],
            retainedRecordingIDs: paired,
            existingEntries: []
        ).isEmpty)
        #expect(VocabularySuggestionOracle.suggestions(
            records: [first, second],
            retainedRecordingIDs: paired,
            existingEntries: [
                DictionaryEntry(spokenForm: "Valyou", replacement: "Valyou"),
            ]
        ).isEmpty)
    }

    @Test
    func rawRecognitionMustContainTheCorrectedSource() {
        let records = [
            record(
                raw: "Use Valyou",
                text: "Use value.",
                reference: "Use Valyou."
            ),
            record(
                raw: "Ask Valyou",
                text: "Ask value.",
                reference: "Ask Valyou."
            ),
        ]

        #expect(VocabularySuggestionOracle.suggestions(
            records: records,
            retainedRecordingIDs: Set(records.map(\.id)),
            existingEntries: []
        ).isEmpty)
    }

    @Test
    func technicalMergeAndHyphenatedNameRemainEligible() {
        let wordhand = [
            record(raw: "open word hand", text: "Open word hand.", reference: "Open Wordhand."),
            record(raw: "use word hand", text: "Use word hand.", reference: "Use Wordhand."),
        ]
        let name = [
            record(
                raw: "ask Aaron Brown Moore",
                text: "Ask Aaron Brown Moore.",
                reference: "Ask Aaron Browne-Moore."
            ),
            record(
                raw: "email Aaron Brown Moore",
                text: "Email Aaron Brown Moore.",
                reference: "Email Aaron Browne-Moore."
            ),
        ]

        #expect(VocabularySuggestionOracle.suggestions(
            records: wordhand,
            retainedRecordingIDs: Set(wordhand.map(\.id)),
            existingEntries: []
        ).map(\.canonicalTerm) == ["Wordhand"])
        #expect(VocabularySuggestionOracle.suggestions(
            records: name,
            retainedRecordingIDs: Set(name.map(\.id)),
            existingEntries: []
        ).map(\.canonicalTerm) == ["Browne-Moore"])
    }

    @Test
    func supportedTechnicalPunctuationIsPreservedAndUnknownPunctuationAbstains() {
        let ampersand = [
            record(raw: "ask A T T", text: "Ask A T T.", reference: "Ask AT&T."),
            record(raw: "email A T T", text: "Email A T T.", reference: "Email AT&T."),
        ]
        let unsupported = [
            record(raw: "open foo bar", text: "Open foo bar.", reference: "Open foo|bar."),
            record(raw: "use foo bar", text: "Use foo bar.", reference: "Use foo|bar."),
        ]

        #expect(VocabularySuggestionOracle.suggestions(
            records: ampersand,
            retainedRecordingIDs: Set(ampersand.map(\.id)),
            existingEntries: []
        ).map(\.canonicalTerm) == ["AT&T"])
        #expect(VocabularySuggestionOracle.suggestions(
            records: unsupported,
            retainedRecordingIDs: Set(unsupported.map(\.id)),
            existingEntries: []
        ).isEmpty)
    }

    private func record(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        raw: String,
        text: String,
        reference: String
    ) -> TranscriptRecord {
        TranscriptRecord(
            id: id,
            createdAt: createdAt,
            rawText: raw,
            text: text,
            modelID: "whisper-large-v3",
            language: "en",
            audioDuration: 3,
            transcriptionDuration: 1,
            insertionMode: .paste,
            status: .inserted,
            referenceText: reference
        )
    }
}
