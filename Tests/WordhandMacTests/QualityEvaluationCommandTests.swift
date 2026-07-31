import ArgumentParser
import Foundation
import Testing
import WordhandCore
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
    func pronunciationAliasReplayRequiresDistinctHeardFormAndSixOrders() throws {
        let valid = VocabularyReplayRequest(
            schema: 2,
            candidate: "Aaron Browne-Moore",
            heardAs: "Aaron Brown more",
            supportingTranscriptIDs: [UUID(), UUID()],
            modelID: "whisper-large-v3",
            repetitions: 6,
            limit: 3
        )
        try valid.validate()
        #expect(valid.candidateKind == .pronunciationAlias)

        #expect(throws: (any Error).self) {
            try VocabularyReplayRequest(
                schema: 2,
                candidate: "Aaron Browne-Moore",
                heardAs: "Aaron Browne-Moore",
                supportingTranscriptIDs: [UUID(), UUID()],
                modelID: "whisper-large-v3",
                repetitions: 6,
                limit: 3
            ).validate()
        }
        #expect(throws: (any Error).self) {
            try VocabularyReplayRequest(
                schema: 2,
                candidate: "Aaron Browne-Moore",
                heardAs: "Aaron Brown more",
                supportingTranscriptIDs: [UUID(), UUID()],
                modelID: "whisper-large-v3",
                repetitions: 4,
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

    @Test
    func tailWindowComparisonIsFixedBalancedCachedEvidence() throws {
        let command = try Models.TailWindowCompare.parse([
            "/tmp/retained.aiff",
            "--fixture", "/tmp/completeness.json",
            "--iterations", "4",
            "--json",
        ])

        #expect(command.fixture == "/tmp/completeness.json")
        #expect(!command.userDictionary)
        #expect(command.iterations == 4)
        #expect(command.json)
        #expect(throws: (any Error).self) {
            _ = try Models.TailWindowCompare.parse([
                "/tmp/retained.aiff",
                "--fixture", "/tmp/completeness.json",
                "--user-dictionary",
            ])
        }
        #expect(throws: (any Error).self) {
            _ = try Models.TailWindowCompare.parse([
                "/tmp/retained.aiff",
                "--fixture", "/tmp/completeness.json",
                "--iterations", "3",
            ])
        }
    }

    @Test
    func tailWindowReportSchemaCannotLeakTranscriptEvidence() throws {
        let run = TailAuditWindowRunEvidence(
            iteration: 1,
            order: "baseline-candidate",
            baselineTranscriptSHA256: String(repeating: "a", count: 64),
            candidateTranscriptSHA256: String(repeating: "a", count: 64),
            baselineStopToFinalSeconds: 8,
            candidateStopToFinalSeconds: 5,
            baselineFullRetryPerformed: true,
            candidateFullRetryPerformed: false,
            baselineTailOutcome: .fullRetryRecovered,
            candidateTailOutcome: .merged
        )
        let decision = TailAuditWindowComparisonOracle.evaluate(
            baselineWindowSeconds: 20,
            candidateWindowSeconds: 30,
            protectedCompletenessPassed: true,
            runs: [
                run,
                TailAuditWindowRunEvidence(
                    iteration: 2,
                    order: "candidate-baseline",
                    baselineTranscriptSHA256:
                        run.baselineTranscriptSHA256,
                    candidateTranscriptSHA256:
                        run.candidateTranscriptSHA256,
                    baselineStopToFinalSeconds: 8,
                    candidateStopToFinalSeconds: 5,
                    baselineFullRetryPerformed: true,
                    candidateFullRetryPerformed: false,
                    baselineTailOutcome: .fullRetryRecovered,
                    candidateTailOutcome: .merged
                ),
            ]
        )
        let report = TailWindowCompareReport(
            schemaVersion: 1,
            modelID: "whisper-large-v3",
            baselineImplementationID: "tail-audit-window-20s-v1",
            candidateImplementationID: "tail-audit-window-30s-v1",
            decoderConfigurationID: "wordhand-english-default-v1",
            audioSHA256: String(repeating: "b", count: 64),
            fixtureSHA256: String(repeating: "c", count: 64),
            vocabularySHA256: String(repeating: "d", count: 64),
            sampleCount: 640_000,
            sampleRate: 16_000,
            audioDurationSeconds: 40,
            baselineWindowSeconds: 20,
            candidateWindowSeconds: 30,
            iterations: 2,
            protectedCompletenessPassed: true,
            decision: decision,
            runs: [
                run,
                TailAuditWindowRunEvidence(
                    iteration: 2,
                    order: "candidate-baseline",
                    baselineTranscriptSHA256:
                        run.baselineTranscriptSHA256,
                    candidateTranscriptSHA256:
                        run.candidateTranscriptSHA256,
                    baselineStopToFinalSeconds: 8,
                    candidateStopToFinalSeconds: 5,
                    baselineFullRetryPerformed: true,
                    candidateFullRetryPerformed: false,
                    baselineTailOutcome: .fullRetryRecovered,
                    candidateTailOutcome: .merged
                ),
            ]
        )
        let object = try #require(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(report)
            ) as? [String: Any]
        )
        let keys = allKeys(in: object)
        #expect(
            keys.isDisjoint(with: [
                "transcript",
                "reference",
                "audioPath",
                "vocabularyTerms",
                "acceptedForms",
                "matchedForm",
                "fixtureID",
            ])
        )
    }

    private func allKeys(in value: Any) -> Set<String> {
        if let dictionary = value as? [String: Any] {
            return Set(dictionary.keys).union(
                dictionary.values.reduce(into: Set<String>()) {
                    $0.formUnion(allKeys(in: $1))
                }
            )
        }
        if let array = value as? [Any] {
            return array.reduce(into: Set<String>()) {
                $0.formUnion(allKeys(in: $1))
            }
        }
        return []
    }
}
