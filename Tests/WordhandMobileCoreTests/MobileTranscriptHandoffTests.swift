import Foundation
import Testing
import WordhandCore
@testable import WordhandMobileCore

@Suite
struct MobileTranscriptHandoffTests {
    @Test
    func pipelineProcessesAndPersistsAProtectedDraft() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let processor = TranscriptProcessor(dictionaryEntries: [
            DictionaryEntry(spokenForm: "word hand", replacement: "Wordhand"),
        ])
        let pipeline = MobileTranscriptPipeline(
            processor: processor,
            store: fixture.store,
            date: { now }
        )

        let draft = try pipeline.processAndSave("  word hand [blank_audio] works  ")

        #expect(draft.text == "Wordhand works")
        #expect(try fixture.store.pending(now: now)?.id == draft.id)
        #expect(try fixture.store.pending(now: now)?.text == "Wordhand works")
    }

    @Test
    func consumedDraftCanOnlyBeInsertedOnce() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let draft = MobileTranscriptDraft(text: "one local transcript")
        try fixture.store.save(draft)

        #expect(try fixture.store.consume(id: draft.id))
        #expect(try fixture.store.pending() == nil)
        #expect(try !fixture.store.consume(id: draft.id))
    }

    @Test
    func staleConsumerCannotEraseANewerRecording() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let old = MobileTranscriptDraft(text: "old")
        let new = MobileTranscriptDraft(text: "new")
        try fixture.store.save(old)
        try fixture.store.save(new)

        #expect(try !fixture.store.consume(id: old.id))
        #expect(try fixture.store.pending()?.id == new.id)
    }

    @Test
    func expiredDraftIsPurged() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let createdAt = Date(timeIntervalSince1970: 100)
        try fixture.store.save(MobileTranscriptDraft(createdAt: createdAt, text: "expired"))

        let pending = try fixture.store.pending(
            now: Date(timeIntervalSince1970: 200),
            maximumAge: 60
        )

        #expect(pending == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.store.fileURL.path))
    }

    @Test
    func emptyProcessedTextNeverReplacesARecoverableDraft() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let recoverable = MobileTranscriptDraft(text: "keep me")
        try fixture.store.save(recoverable)
        let pipeline = MobileTranscriptPipeline(store: fixture.store)

        #expect(throws: MobileTranscriptDraftError.emptyText) {
            try pipeline.processAndSave("[blank_audio]")
        }
        #expect(try fixture.store.pending()?.id == recoverable.id)
    }

    @Test
    func benchmarkObservationStaysInTheLocalFixture() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let benchmarkStore = LocalBenchmarkStore(
            rootDirectory: fixture.directory.appendingPathComponent("Benchmarks")
        )
        let observation = TranscriptionObservation(
            createdAt: Date(timeIntervalSince1970: 1_900_000_000),
            engineID: "apple-speech-on-device",
            localeIdentifier: "en_US",
            rawText: "word hand",
            processedText: "Wordhand",
            audioFileName: "fixture.caf",
            audioDuration: 2.4,
            transcriptionDuration: 0.3
        )

        try benchmarkStore.save(observation)

        #expect(try benchmarkStore.loadAll() == [observation])
        #expect(
            benchmarkStore.rootDirectory.path.hasPrefix(fixture.directory.path)
        )
    }
}

private struct Fixture {
    let directory: URL
    let store: SharedTranscriptStore

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wordhand-mobile-\(UUID().uuidString)", isDirectory: true)
        store = SharedTranscriptStore(
            fileURL: directory.appendingPathComponent(SharedTranscriptStore.fileName)
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
