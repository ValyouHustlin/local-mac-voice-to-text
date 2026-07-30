import Foundation
import Testing
@testable import WordhandCore

@Suite
struct DictionaryStoreTests {
    @Test
    func roundTripsCreatesDirectoryAndDeletes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DictionaryStore(fileURL: root.appendingPathComponent("nested/dictionary.json"))
        let timestamp = Date(timeIntervalSince1970: 1_000)
        let entry = DictionaryEntry(
            spokenForm: "whisper flow",
            replacement: "Wispr Flow",
            createdAt: timestamp,
            updatedAt: timestamp
        )

        let added = try store.upsert(entry)
        #expect(added.entries == [entry])
        #expect(try store.load().entries == [entry])
        let attributes = try FileManager.default.attributesOfItem(
            atPath: store.fileURL.path
        )
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        let deleted = try store.delete(id: entry.id)
        #expect(deleted.entries.isEmpty)
        #expect(try store.load().entries.isEmpty)
    }

    @Test
    func rejectsEmptyAndDuplicateMatches() {
        let duplicateEntries = [
            DictionaryEntry(spokenForm: "Wordhand", replacement: "one"),
            DictionaryEntry(spokenForm: "wordhand", replacement: "two"),
        ]

        #expect(throws: DictionaryStoreError.emptySpokenForm) {
            try DictionaryDocument(entries: [
                DictionaryEntry(spokenForm: " ", replacement: "value"),
            ]).validated()
        }
        #expect(throws: DictionaryStoreError.emptyReplacement) {
            try DictionaryDocument(entries: [
                DictionaryEntry(spokenForm: "word", replacement: " "),
            ]).validated()
        }
        #expect(throws: DictionaryStoreError.duplicateSpokenForm("wordhand")) {
            try DictionaryDocument(entries: duplicateEntries).validated()
        }
    }

    @Test
    func migratesLegacyEntryArray() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("dictionary.json")
        let timestamp = Date(timeIntervalSince1970: 1_000)
        let entry = DictionaryEntry(
            spokenForm: "air on",
            replacement: "Aaron",
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode([entry]).write(to: url)

        let store = DictionaryStore(fileURL: url)
        #expect(try store.load().entries == [entry])

        let migratedData = try Data(contentsOf: url)
        let object = try #require(
            JSONSerialization.jsonObject(with: migratedData) as? [String: Any]
        )
        #expect(object["schemaVersion"] as? Int == DictionaryDocument.currentSchemaVersion)
        #expect(object["installedDefaultVocabularyVersion"] as? Int == 0)
    }

    @Test
    func decodesDocumentsCreatedBeforeVocabularySeeding() throws {
        let data = """
        {"schemaVersion":1,"entries":[]}
        """.data(using: .utf8)!
        let document = try JSONDecoder().decode(DictionaryDocument.self, from: data)

        #expect(document.installedDefaultVocabularyVersion == 0)
        #expect(document.entries.isEmpty)
    }

    @Test
    func installsEditableDefaultsOnceWithoutOverwritingCustomTerms() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DictionaryStore(fileURL: root.appendingPathComponent("dictionary.json"))
        let custom = DictionaryEntry(spokenForm: "value", replacement: "Valyou")
        try store.save(DictionaryDocument(entries: [custom]))
        let seed = DictionaryVocabularySeed(
            version: 1,
            terms: ["Valyou", "Blumira", "Wordhand"]
        )

        let installed = try store.installDefaults(seed)
        #expect(installed.installedDefaultVocabularyVersion == 1)
        #expect(installed.entries.contains {
            $0.id == custom.id
                && $0.spokenForm == custom.spokenForm
                && $0.replacement == custom.replacement
        })
        #expect(installed.entries.map(\.replacement).filter { $0 == "Valyou" }.count == 1)
        #expect(installed.entries.map(\.replacement).contains("Blumira"))
        #expect(installed.entries.map(\.replacement).contains("Wordhand"))
        #expect(
            installed.entries
                .filter { $0.id != custom.id }
                .allSatisfy { $0.origin == .starterVocabulary }
        )
        #expect(
            installed.entries
                .filter { $0.id != custom.id }
                .compactMap(\.starterVocabularyOrder) == [1, 2]
        )

        let blumiraID = try #require(
            installed.entries.first(where: { $0.replacement == "Blumira" })?.id
        )
        _ = try store.delete(id: blumiraID)
        let reloaded = try store.installDefaults(seed)
        #expect(!reloaded.entries.map(\.replacement).contains("Blumira"))
    }

    @Test
    func installsNewTermsWhenBundledSeedVersionAdvances() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DictionaryStore(fileURL: root.appendingPathComponent("dictionary.json"))

        _ = try store.installDefaults(DictionaryVocabularySeed(version: 1, terms: ["Valyou"]))
        let upgraded = try store.installDefaults(
            DictionaryVocabularySeed(version: 2, terms: ["Valyou", "Blumira"])
        )

        #expect(upgraded.installedDefaultVocabularyVersion == 2)
        #expect(upgraded.entries.map(\.replacement).contains("Valyou"))
        #expect(upgraded.entries.map(\.replacement).contains("Blumira"))
    }

    @Test
    func backfillsStarterOrderWithoutReinstallingDeletedTerms() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DictionaryStore(fileURL: root.appendingPathComponent("dictionary.json"))
        try store.save(DictionaryDocument(
            installedDefaultVocabularyVersion: 1,
            entries: [
                DictionaryEntry(
                    spokenForm: "Blumira",
                    replacement: "Blumira",
                    origin: .starterVocabulary
                ),
            ]
        ))

        let document = try store.installDefaults(
            DictionaryVocabularySeed(version: 1, terms: ["Valyou", "Blumira"])
        )

        #expect(document.entries.count == 1)
        #expect(document.entries[0].replacement == "Blumira")
        #expect(document.entries[0].starterVocabularyOrder == 1)
    }

    @Test
    func bundledDefaultsContainVersionOneStarterVocabulary() throws {
        let seed = try BundledDictionaryVocabulary.load()

        #expect(seed.version == 1)
        #expect(seed.terms.contains("Valyou"))
        #expect(seed.terms.contains("Blumira"))
        #expect(seed.terms.contains("Banana Farmer"))
        #expect(seed.terms.contains("WhisperKit"))
        #expect(seed.terms.contains("Valyou Solutions"))
        #expect(seed.terms.count >= 39)
    }

    @Test
    func vocabularyPromptUsesEnabledCanonicalSpellingsAndUpdatesLive() {
        let timestamp = Date(timeIntervalSince1970: 1_000)
        let source = DictionaryVocabularySource(entries: [
            DictionaryEntry(
                spokenForm: "value",
                replacement: "Valyou",
                createdAt: timestamp,
                updatedAt: timestamp
            ),
            DictionaryEntry(
                spokenForm: "blue mirror",
                replacement: "Blumira",
                createdAt: timestamp,
                updatedAt: timestamp
            ),
            DictionaryEntry(
                spokenForm: "val you",
                replacement: "valyou",
                createdAt: timestamp,
                updatedAt: timestamp
            ),
            DictionaryEntry(
                spokenForm: "ghost",
                replacement: "Ghostty",
                isEnabled: false,
                createdAt: timestamp,
                updatedAt: timestamp
            ),
        ])

        #expect(source.terms() == ["Valyou", "Blumira"])
        #expect(
            source.prompt()
                == "Vocabulary: Blumira, Valyou. Preferred spellings: Blumira, Valyou."
        )

        source.update(entries: [
            DictionaryEntry(spokenForm: "word hand", replacement: "Wordhand"),
        ])
        #expect(
            source.prompt()
                == "Vocabulary: Wordhand. Preferred spellings: Wordhand."
        )
    }

    @Test
    func vocabularyPromptPlacesHighestPriorityTermAtDecodeBoundary() {
        let timestamp = Date(timeIntervalSince1970: 1_000)
        let source = DictionaryVocabularySource(entries: [
            DictionaryEntry(
                spokenForm: "Valyou",
                replacement: "Valyou",
                origin: .starterVocabulary,
                starterVocabularyOrder: 0,
                createdAt: timestamp,
                updatedAt: timestamp
            ),
            DictionaryEntry(
                spokenForm: "new correction",
                replacement: "NewestTerm",
                updatedAt: timestamp.addingTimeInterval(2)
            ),
            DictionaryEntry(
                spokenForm: "older correction",
                replacement: "OlderTerm",
                updatedAt: timestamp.addingTimeInterval(1)
            ),
        ])

        #expect(source.terms() == ["NewestTerm", "OlderTerm", "Valyou"])
        #expect(
            source.prompt()
                == """
                Vocabulary: Valyou, OlderTerm, NewestTerm. Preferred spellings: Valyou, OlderTerm, NewestTerm.
                """
        )
    }

    @Test
    func decoderPromptGateMovesConfidenceCheckToFirstRealOutput() {
        let gate = DecoderPromptPrefillGate(forcedTokenCount: 2)

        let firstForced = gate.evaluate(
            sampledCompletion: true,
            sampledLogProbability: -4,
            firstOutputLogProbabilityThreshold: -1.5
        )
        let secondForced = gate.evaluate(
            sampledCompletion: true,
            sampledLogProbability: -3,
            firstOutputLogProbabilityThreshold: -1.5
        )
        let lowConfidenceFirstOutput = gate.evaluate(
            sampledCompletion: false,
            sampledLogProbability: -2,
            firstOutputLogProbabilityThreshold: -1.5
        )
        let laterOutput = gate.evaluate(
            sampledCompletion: false,
            sampledLogProbability: -3,
            firstOutputLogProbabilityThreshold: -1.5
        )

        #expect(firstForced == DecoderPromptPrefillDecision(
            shouldComplete: false,
            effectiveLogProbability: -1.5
        ))
        #expect(secondForced == DecoderPromptPrefillDecision(
            shouldComplete: false,
            effectiveLogProbability: -1.5
        ))
        #expect(lowConfidenceFirstOutput.shouldComplete)
        #expect(!laterOutput.shouldComplete)
    }

    @Test
    func vocabularyPromptPrioritizesCustomCorrectionsAndCapsStarterTerms() {
        let timestamp = Date(timeIntervalSince1970: 1_000)
        let starters = (1...30).map {
            DictionaryEntry(
                spokenForm: "Starter \($0)",
                replacement: "Starter \($0)",
                origin: .starterVocabulary,
                starterVocabularyOrder: $0 - 1,
                createdAt: timestamp,
                updatedAt: timestamp
            )
        }
        let source = DictionaryVocabularySource(entries: starters + [
            DictionaryEntry(
                spokenForm: "blue mirror",
                replacement: "Blumira",
                updatedAt: timestamp.addingTimeInterval(1)
            ),
        ])

        let terms = source.terms()
        #expect(terms.count == DictionaryVocabularySource.maximumPromptTerms)
        #expect(terms.first == "Blumira")
        #expect(terms.contains("Starter 1"))
        #expect(!terms.contains("Starter 24"))
    }

    @Test
    func mutableProcessorUsesUpdatesWithoutRestart() async {
        let processor = MutableTranscriptProcessor()
        #expect(await processor.process("whisper flow") == "whisper flow")

        processor.update(dictionaryEntries: [
            DictionaryEntry(spokenForm: "whisper flow", replacement: "Wispr Flow"),
        ])
        #expect(await processor.process("whisper flow") == "Wispr Flow")
    }

    @Test
    func rejectsNewerSchemaWithoutOverwritingIt() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("dictionary.json")
        let original = """
        {"schemaVersion":99,"entries":[]}
        """.data(using: .utf8)!
        try original.write(to: url)

        let store = DictionaryStore(fileURL: url)
        #expect(throws: DictionaryStoreError.unsupportedSchema(99)) {
            try store.load()
        }
        #expect(try Data(contentsOf: url) == original)
    }
}
