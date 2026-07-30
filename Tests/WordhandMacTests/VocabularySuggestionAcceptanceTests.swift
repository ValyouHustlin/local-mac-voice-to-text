import Foundation
import AppKit
import Testing
import WordhandCore
@testable import wordhand

@Suite
@MainActor
struct VocabularySuggestionAcceptanceTests {
    @Test
    func suggestionIsReadOnlyUntilExplicitVocabularyAcceptance() async throws {
        let fixture = try LearningFixture()
        defer { fixture.remove() }
        try fixture.populatePairedEvidence()
        let dictionaryBefore = try Data(contentsOf: fixture.dictionaryURL)

        let suggestions = try fixture.historyController.vocabularySuggestions()

        let suggestion = try #require(suggestions.first)
        #expect(suggestion.canonicalTerm == "Kierkegaard")
        #expect(try Data(contentsOf: fixture.dictionaryURL) == dictionaryBefore)

        let accepted = try fixture.dictionary.addVocabularyTerm(
            suggestion.canonicalTerm
        )
        let persisted = try DictionaryStore(fileURL: fixture.dictionaryURL).load()
        let entry = try #require(persisted.entries.first(where: {
            $0.id == accepted.id
        }))

        #expect(entry.spokenForm == "Kierkegaard")
        #expect(entry.replacement == "Kierkegaard")
        #expect(entry.isEnabled)
        #expect(fixture.dictionary.vocabulary.terms().first == "Kierkegaard")
        #expect(
            fixture.dictionary.vocabulary.prompt()?.contains("is written") == false
        )
        #expect(
            await fixture.dictionary.processor.process("Read Kierkegaard.")
                == "Read Kierkegaard."
        )
        #expect(
            try fixture.historyController.vocabularySuggestions().isEmpty
        )
    }

    @Test
    func missingRetainedRecordingLeavesHistoryFlowUnchanged() throws {
        let fixture = try LearningFixture()
        defer { fixture.remove() }
        for record in fixture.correctedRecords() {
            try fixture.history.save(record)
        }
        let dictionaryBefore = try Data(contentsOf: fixture.dictionaryURL)

        #expect(try fixture.historyController.vocabularySuggestions().isEmpty)
        #expect(try Data(contentsOf: fixture.dictionaryURL) == dictionaryBefore)
    }

    @Test
    func historyRendersOneNonInterruptingSuggestionActionWhenRequested() throws {
        // AppKit rendering requires the logged-in WindowServer. Keep ordinary
        // headless CI on the deterministic History/persistence assertions and
        // drive this visual receipt explicitly on an attended Mac.
        guard let receiptPath = ProcessInfo.processInfo.environment[
            "WORDHAND_UI_RECEIPT"
        ] else {
            return
        }
        let fixture = try LearningFixture()
        defer { fixture.remove() }
        try fixture.populatePairedEvidence()

        let windowController = HistoryWindowController(
            history: fixture.historyController
        )
        windowController.reload()
        let content = try #require(windowController.window?.contentView)
        content.layoutSubtreeIfNeeded()

        let button = try #require(
            findView(
                in: content,
                identifier: "VocabularySuggestionReviewButton"
            ) as? NSButton
        )
        let label = try #require(
            findView(
                in: content,
                identifier: "VocabularySuggestionLabel"
            ) as? NSTextField
        )
        #expect(!button.isHidden)
        #expect(button.title == "Review Suggestion…")
        #expect(label.stringValue.contains("Kierkegaard"))
        #expect(label.stringValue.contains("2 corrected transcripts"))

        let representation = try #require(
            content.bitmapImageRepForCachingDisplay(in: content.bounds)
        )
        content.cacheDisplay(in: content.bounds, to: representation)
        let png = try #require(
            representation.representation(using: .png, properties: [:])
        )
        try png.write(to: URL(fileURLWithPath: receiptPath), options: .atomic)
    }

    @Test
    func staleAliasDoesNotMasqueradeAsCanonicalVocabulary() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "wordhand-learning-alias-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DictionaryStore(
            fileURL: directory.appendingPathComponent("dictionary.json")
        )
        _ = try store.installBundledDefaults()
        _ = try store.upsert(DictionaryEntry(
            spokenForm: "key or guard",
            replacement: "Kierkegaard"
        ))
        let dictionary = DictionaryController(store: store)

        let accepted = try dictionary.addVocabularyTerm("Kierkegaard")
        let persisted = try store.load().entries

        #expect(accepted.spokenForm == "Kierkegaard")
        #expect(accepted.replacement == "Kierkegaard")
        #expect(persisted.contains(where: {
            $0.spokenForm == "key or guard" && $0.replacement == "Kierkegaard"
        }))
        #expect(persisted.contains(where: {
            $0.spokenForm == "Kierkegaard" && $0.replacement == "Kierkegaard"
        }))
    }

    @Test
    func explicitAcceptanceReenablesDisabledCanonicalEntry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "wordhand-learning-disabled-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DictionaryStore(
            fileURL: directory.appendingPathComponent("dictionary.json")
        )
        _ = try store.installBundledDefaults()
        let disabled = DictionaryEntry(
            spokenForm: "Kierkegaard",
            replacement: "Kierkegaard",
            isEnabled: false
        )
        _ = try store.upsert(disabled)
        let dictionary = DictionaryController(store: store)

        let accepted = try dictionary.addVocabularyTerm("Kierkegaard")
        let persisted = try #require(
            try store.load().entries.first(where: { $0.id == disabled.id })
        )

        #expect(accepted.id == disabled.id)
        #expect(persisted.isEnabled)
    }

    @Test
    func historySuggestionSurvivesAliasUntilCanonicalTermIsAccepted() throws {
        let fixture = try LearningFixture(seedEntries: [
            DictionaryEntry(
                spokenForm: "key or guard",
                replacement: "Kierkegaard"
            ),
        ])
        defer { fixture.remove() }
        try fixture.populatePairedEvidence()

        let suggestion = try #require(
            try fixture.historyController.vocabularySuggestions().first
        )
        _ = try fixture.dictionary.addVocabularyTerm(suggestion.canonicalTerm)

        #expect(try fixture.historyController.vocabularySuggestions().isEmpty)
        #expect(try DictionaryStore(fileURL: fixture.dictionaryURL).load()
            .entries.contains(where: {
                $0.isEnabled
                    && $0.spokenForm == "Kierkegaard"
                    && $0.replacement == "Kierkegaard"
            }))
    }

    @Test
    func historySuggestionSurvivesDisabledCanonicalUntilAcceptance() throws {
        let disabled = DictionaryEntry(
            spokenForm: "Kierkegaard",
            replacement: "Kierkegaard",
            isEnabled: false
        )
        let fixture = try LearningFixture(seedEntries: [disabled])
        defer { fixture.remove() }
        try fixture.populatePairedEvidence()

        let suggestion = try #require(
            try fixture.historyController.vocabularySuggestions().first
        )
        let accepted = try fixture.dictionary.addVocabularyTerm(
            suggestion.canonicalTerm
        )

        #expect(accepted.id == disabled.id)
        #expect(accepted.isEnabled)
        #expect(try fixture.historyController.vocabularySuggestions().isEmpty)
    }

    private func findView(
        in root: NSView,
        identifier: String
    ) -> NSView? {
        if root.identifier?.rawValue == identifier {
            return root
        }
        for child in root.subviews {
            if let match = findView(in: child, identifier: identifier) {
                return match
            }
        }
        return nil
    }
}

@MainActor
private final class LearningFixture {
    let directory: URL
    let dictionaryURL: URL
    let history: TranscriptHistoryStore
    let archive: LocalQualityAudioArchive
    let dictionary: DictionaryController
    let historyController: HistoryController

    init(seedEntries: [DictionaryEntry] = []) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "wordhand-learning-\(UUID().uuidString)",
            isDirectory: true
        )
        dictionaryURL = directory.appendingPathComponent("dictionary.json")
        history = try TranscriptHistoryStore(
            fileURL: directory.appendingPathComponent("history.sqlite")
        )
        archive = LocalQualityAudioArchive(
            directoryURL: directory.appendingPathComponent(
                "Quality Recordings",
                isDirectory: true
            )
        )
        let dictionaryStore = DictionaryStore(fileURL: dictionaryURL)
        _ = try dictionaryStore.installBundledDefaults()
        for entry in seedEntries {
            _ = try dictionaryStore.upsert(entry)
        }
        dictionary = DictionaryController(store: dictionaryStore)
        historyController = HistoryController(
            store: history,
            dictionary: dictionary,
            inserter: LearningFakeInserter(),
            qualityAudioArchive: archive
        )
    }

    func correctedRecords() -> [TranscriptRecord] {
        [
            record(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
                createdAt: Date(timeIntervalSince1970: 100),
                raw: "Read key or guard",
                text: "Read key or guard.",
                reference: "Read Kierkegaard."
            ),
            record(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!,
                createdAt: Date(timeIntervalSince1970: 200),
                raw: "Quote key or guard today",
                text: "Quote key or guard today.",
                reference: "Quote Kierkegaard today."
            ),
        ]
    }

    func populatePairedEvidence() throws {
        for record in correctedRecords() {
            try history.save(record)
            _ = try archive.store(QualityAudioSample(
                transcriptID: record.id,
                createdAt: record.createdAt,
                samples: [0, 0.1, -0.1],
                sampleRate: 16_000
            ))
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func record(
        id: UUID,
        createdAt: Date,
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
            audioDuration: 2,
            transcriptionDuration: 1,
            insertionMode: .paste,
            status: .inserted,
            referenceText: reference
        )
    }
}

private struct LearningFakeInserter: TextInserting {
    func insert(_ text: String, mode: InsertionMode) async throws {}
}
