import ArgumentParser
import Foundation
import Testing
@testable import wordhand

@Suite
struct QualityEvaluationCommandTests {
    @Test
    func parsesRepeatedModelsAndSafeDefaults() throws {
        let command = try QualityEvaluate.parse([
            "--model", "whisper-base.en",
            "--model", "whisper-large-v3",
        ])

        #expect(command.model == ["whisper-base.en", "whisper-large-v3"])
        #expect(command.limit == 50)
        #expect(command.modelTimeoutSeconds == 180)
        #expect(!command.allCached)
        #expect(!command.withoutDictionary)
    }

    @Test
    func rejectsAnUnboundedOrConflictingEvaluation() {
        #expect(throws: (any Error).self) {
            _ = try QualityEvaluate.parse([
                "--model-timeout-seconds", "29",
            ])
        }
        #expect(throws: (any Error).self) {
            _ = try QualityEvaluate.parse([
                "--all-cached",
                "--model", "whisper-base.en",
            ])
        }
    }

    @Test
    func vocabularyReplayParsesOnlyItsBoundedStdinShell() throws {
        let command = try QualityProveVocabulary.parse([
            "--request-stdin",
            "--json",
            "--timeout-seconds", "120",
            "--data-directory", "/tmp/wordhand-replay-fixture",
        ])

        #expect(command.requestStdin)
        #expect(command.json)
        #expect(command.timeoutSeconds == 120)
        #expect(command.dataDirectory == "/tmp/wordhand-replay-fixture")

        #expect(throws: (any Error).self) {
            _ = try QualityProveVocabulary.parse([])
        }
        #expect(throws: (any Error).self) {
            _ = try QualityProveVocabulary.parse([
                "--request-stdin",
                "--timeout-seconds", "29",
            ])
        }
    }

    @Test
    func vocabularyReplayRequestRequiresIndependentFixedEvidence() throws {
        let valid = VocabularyReplayRequest(
            schema: 1,
            candidate: "Browne-Moore",
            supportingTranscriptIDs: [UUID(), UUID()],
            modelID: "whisper-large-v3",
            repetitions: 4,
            limit: 3
        )
        try valid.validate()

        #expect(throws: (any Error).self) {
            try VocabularyReplayRequest(
                schema: 1,
                candidate: "Browne-Moore",
                supportingTranscriptIDs: [UUID()],
                modelID: "whisper-large-v3",
                repetitions: 4,
                limit: 3
            ).validate()
        }
        #expect(throws: (any Error).self) {
            try VocabularyReplayRequest(
                schema: 1,
                candidate: "Browne-Moore",
                supportingTranscriptIDs: [UUID(), UUID()],
                modelID: "whisper-large-v3",
                repetitions: 3,
                limit: 3
            ).validate()
        }
    }

    @Test
    func vocabularyReplayRejectsOversizedStandardInput() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "wordhand-replay-input-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 0x61, count: 16 * 1_024 + 1).write(to: url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        #expect(throws: (any Error).self) {
            _ = try QualityProveVocabulary.readBoundedInput(handle)
        }
    }
}
