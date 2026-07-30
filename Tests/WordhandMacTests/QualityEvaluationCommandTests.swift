import ArgumentParser
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
}
