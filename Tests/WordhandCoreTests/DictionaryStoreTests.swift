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
    }

    @Test
    func mutableProcessorUsesUpdatesWithoutRestart() {
        let processor = MutableTranscriptProcessor()
        #expect(processor.process("whisper flow") == "whisper flow")

        processor.update(dictionaryEntries: [
            DictionaryEntry(spokenForm: "whisper flow", replacement: "Wispr Flow"),
        ])
        #expect(processor.process("whisper flow") == "Wispr Flow")
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
