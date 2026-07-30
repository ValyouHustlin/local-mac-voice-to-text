import Foundation
import Testing
@testable import WordhandCore

@Suite
struct PronunciationAliasSuggestionOracleTests {
    @Test
    func suggestsOneRepeatedAliasOnlyAfterCanonicalVocabularyExists() throws {
        let first = UUID()
        let second = UUID()
        let suggestion = try #require(
            PronunciationAliasSuggestionOracle.suggestions(
                records: [
                    record(
                        id: first,
                        text: "Please ask Aaron Brown more today.",
                        reference: "Please ask Aaron Browne-Moore today."
                    ),
                    record(
                        id: second,
                        text: "Email Aaron Brown more tomorrow.",
                        reference: "Email Aaron Browne-Moore tomorrow."
                    ),
                ],
                retainedRecordingIDs: [first, second],
                existingEntries: [
                    DictionaryEntry(
                        spokenForm: "Aaron Browne-Moore",
                        replacement: "Aaron Browne-Moore"
                    ),
                ]
            ).first
        )

        #expect(suggestion.heardForm == "Aaron Brown more")
        #expect(suggestion.canonicalTerm == "Aaron Browne-Moore")
        #expect(Set(suggestion.supportingTranscriptIDs) == [first, second])
    }

    @Test
    func doesNotCombineDifferentHeardFormsOrGuessMissingCanonical() {
        let first = UUID()
        let second = UUID()
        let records = [
            record(
                id: first,
                text: "Please ask Aaron Brown more today.",
                reference: "Please ask Aaron Browne-Moore today."
            ),
            record(
                id: second,
                text: "Email Aaron Brownmoor tomorrow.",
                reference: "Email Aaron Browne-Moore tomorrow."
            ),
        ]

        #expect(PronunciationAliasSuggestionOracle.suggestions(
            records: records,
            retainedRecordingIDs: [first, second],
            existingEntries: []
        ).isEmpty)
        #expect(PronunciationAliasSuggestionOracle.suggestions(
            records: records,
            retainedRecordingIDs: [first, second],
            existingEntries: [
                DictionaryEntry(
                    spokenForm: "Aaron Browne-Moore",
                    replacement: "Aaron Browne-Moore"
                ),
            ]
        ).isEmpty)
    }

    @Test
    func existingAliasConflictAndUnsafeSemanticChangesAbstain() {
        let first = UUID()
        let second = UUID()
        let records = [
            record(
                id: first,
                text: "Do deploy Friday.",
                reference: "Do not deploy Friday."
            ),
            record(
                id: second,
                text: "Do deploy Friday.",
                reference: "Do not deploy Friday."
            ),
        ]
        #expect(PronunciationAliasSuggestionOracle.suggestions(
            records: records,
            retainedRecordingIDs: [first, second],
            existingEntries: [
                DictionaryEntry(spokenForm: "not", replacement: "not"),
            ]
        ).isEmpty)

        let safeRecords = [
            record(
                id: first,
                text: "Ask Aaron Brown more today.",
                reference: "Ask Aaron Browne-Moore today."
            ),
            record(
                id: second,
                text: "Email Aaron Brown more today.",
                reference: "Email Aaron Browne-Moore today."
            ),
        ]
        #expect(PronunciationAliasSuggestionOracle.suggestions(
            records: safeRecords,
            retainedRecordingIDs: [first, second],
            existingEntries: [
                DictionaryEntry(
                    spokenForm: "Aaron Browne-Moore",
                    replacement: "Aaron Browne-Moore"
                ),
                DictionaryEntry(
                    spokenForm: "Aaron Brown more",
                    replacement: "Someone Else"
                ),
            ]
        ).isEmpty)
    }

    @Test
    func repeatedOrdinarySemanticSubstitutionCannotBecomeAnAlias() {
        let first = UUID()
        let second = UUID()
        let records = [
            record(
                id: first,
                text: "Deploy on Friday.",
                reference: "Deploy on Monday."
            ),
            record(
                id: second,
                text: "The review is Friday.",
                reference: "The review is Monday."
            ),
        ]

        #expect(PronunciationAliasSuggestionOracle.suggestions(
            records: records,
            retainedRecordingIDs: [first, second],
            existingEntries: [
                DictionaryEntry(spokenForm: "Monday", replacement: "Monday"),
            ]
        ).isEmpty)
    }

    @Test
    func semanticSplitMergeCannotBecomeAnAlias() {
        let first = UUID()
        let second = UUID()
        let records = [
            record(
                id: first,
                text: "Use it every day.",
                reference: "Use it everyday."
            ),
            record(
                id: second,
                text: "Choose every day.",
                reference: "Choose everyday."
            ),
        ]

        #expect(PronunciationAliasSuggestionOracle.suggestions(
            records: records,
            retainedRecordingIDs: [first, second],
            existingEntries: [
                DictionaryEntry(spokenForm: "everyday", replacement: "everyday"),
            ]
        ).isEmpty)
    }

    private func record(
        id: UUID,
        text: String,
        reference: String
    ) -> TranscriptRecord {
        TranscriptRecord(
            id: id,
            rawText: text,
            text: text,
            modelID: "test",
            audioDuration: 1,
            transcriptionDuration: 1,
            insertionMode: .paste,
            referenceText: reference
        )
    }
}
