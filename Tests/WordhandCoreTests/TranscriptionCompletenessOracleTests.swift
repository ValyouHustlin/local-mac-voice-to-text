import CryptoKit
import Foundation
import Testing
@testable import WordhandCore

@Suite
struct TranscriptionCompletenessOracleTests {
    private let fixture = TranscriptionCompletenessFixture(
        id: "english-boundaries-v1",
        reference: """
        Boundary alpha begins this test. The value is fourteen point five. \
        Do not deploy on Friday. WhisperKit and GitHub support \
        Aaron Browne-Moore. Boundary omega ends this test.
        """,
        vocabularyTerms: ["WhisperKit", "GitHub", "Aaron Browne-Moore"],
        protectedSpans: [
            ProtectedTranscriptSpan(
                id: "opening",
                category: .beginning,
                acceptedForms: ["Boundary alpha begins"]
            ),
            ProtectedTranscriptSpan(
                id: "closing",
                category: .ending,
                acceptedForms: ["Boundary omega ends this test"]
            ),
            ProtectedTranscriptSpan(
                id: "decimal",
                category: .number,
                acceptedForms: ["fourteen point five", "14.5"]
            ),
            ProtectedTranscriptSpan(
                id: "negation",
                category: .negation,
                acceptedForms: ["do not deploy on Friday"]
            ),
            ProtectedTranscriptSpan(
                id: "whisperkit",
                category: .technicalTerm,
                acceptedForms: ["WhisperKit"]
            ),
            ProtectedTranscriptSpan(
                id: "github",
                category: .technicalTerm,
                acceptedForms: ["GitHub"]
            ),
            ProtectedTranscriptSpan(
                id: "name",
                category: .dictionarySpelling,
                acceptedForms: ["Aaron Browne-Moore"]
            ),
        ]
    )

    @Test
    func identicalCompleteCandidatePassesCompletenessGate() throws {
        let comparison = try #require(TranscriptionCompletenessOracle.compare(
            fixture: fixture,
            baseline: fixture.reference,
            candidate: fixture.reference
        ))

        #expect(comparison.candidatePassesCompletenessGate)
        #expect(comparison.rejectionReasons.isEmpty)
        #expect(comparison.candidateProtected.allSatisfy { $0.passed })
    }

    @Test(arguments: [
        (
            "this test. The value is fourteen point five. Do not deploy on Friday. "
                + "WhisperKit and GitHub support Aaron Browne-Moore. "
                + "Boundary omega ends this test.",
            "protected_opening_occurrence_mismatch"
        ),
        (
            "Boundary alpha begins this test. The value is fourteen point five. "
                + "Do not deploy on Friday. WhisperKit and GitHub support "
                + "Aaron Browne-Moore.",
            "protected_closing_occurrence_mismatch"
        ),
        (
            "Boundary alpha begins this test. The value changed. "
                + "Do not deploy on Friday. WhisperKit and GitHub support "
                + "Aaron Browne-Moore. Boundary omega ends this test.",
            "protected_decimal_occurrence_mismatch"
        ),
        (
            "Boundary alpha begins this test. The value is fourteen point five. "
                + "Deploy on Friday. WhisperKit and GitHub support "
                + "Aaron Browne-Moore. Boundary omega ends this test.",
            "protected_negation_occurrence_mismatch"
        ),
        (
            "Boundary alpha begins this test. The value is fourteen point five. "
                + "Do not deploy on Friday. Whisper and git support "
                + "Aaron Brown Moore. Boundary omega ends this test.",
            "protected_whisperkit_occurrence_mismatch"
        ),
    ])
    func protectedRegressionAlwaysRejectsCandidate(
        candidate: String,
        expectedReason: String
    ) throws {
        let comparison = try #require(TranscriptionCompletenessOracle.compare(
            fixture: fixture,
            baseline: fixture.reference,
            candidate: candidate
        ))

        #expect(!comparison.candidatePassesCompletenessGate)
        #expect(comparison.rejectionReasons.contains(expectedReason))
    }

    @Test
    func decimalAlternativePreservesNumberMeaning() throws {
        let candidate = fixture.reference.replacing(
            "fourteen point five",
            with: "14.5"
        )
        let comparison = try #require(TranscriptionCompletenessOracle.compare(
            fixture: fixture,
            baseline: fixture.reference,
            candidate: candidate
        ))

        #expect(
            comparison.candidateProtected.first {
                $0.category == .number
            }?.passed == true
        )
    }

    @Test
    func lowerAggregateAccuracyCannotWinOnProtectedSpansAlone() throws {
        let candidate = fixture.reference.replacing(
            "support",
            with: "replace"
        )
        let comparison = try #require(TranscriptionCompletenessOracle.compare(
            fixture: fixture,
            baseline: fixture.reference,
            candidate: candidate
        ))

        #expect(comparison.candidateProtected.allSatisfy { $0.passed })
        #expect(!comparison.candidatePassesCompletenessGate)
        #expect(comparison.rejectionReasons.contains("word_error_regression"))
    }

    @Test
    func duplicateProtectedMeaningIsRejected() throws {
        let candidate = fixture.reference + " Do not deploy on Friday."
        let comparison = try #require(TranscriptionCompletenessOracle.compare(
            fixture: fixture,
            baseline: fixture.reference,
            candidate: candidate
        ))

        #expect(!comparison.candidatePassesCompletenessGate)
        #expect(
            comparison.rejectionReasons.contains(
                "protected_negation_occurrence_mismatch"
            )
        )
    }

    @Test
    func incompleteFixtureFailsClosed() {
        let incomplete = TranscriptionCompletenessFixture(
            id: "incomplete",
            reference: "Boundary alpha begins.",
            protectedSpans: []
        )

        #expect(!incomplete.validationIssues().isEmpty)
        #expect(TranscriptionCompletenessOracle.compare(
            fixture: incomplete,
            baseline: incomplete.reference,
            candidate: incomplete.reference
        ) == nil)
    }

    @Test
    func invalidBoundaryPlacementAndReferenceFailClosed() {
        var spans = fixture.protectedSpans
        spans[0] = ProtectedTranscriptSpan(
            id: "opening",
            category: .beginning,
            acceptedForms: ["alpha begins"],
            placement: .anywhere
        )
        let invalid = TranscriptionCompletenessFixture(
            id: "invalid-boundary",
            reference: fixture.reference,
            vocabularyTerms: fixture.vocabularyTerms,
            protectedSpans: spans
        )

        #expect(
            invalid.validationIssues().contains {
                $0.contains("invalid placement")
            }
        )
        #expect(TranscriptionCompletenessOracle.compare(
            fixture: invalid,
            baseline: invalid.reference,
            candidate: invalid.reference
        ) == nil)
    }

    @Test
    func protectedSpanAbsentFromReferenceFailsClosed() {
        var spans = fixture.protectedSpans
        spans[2] = ProtectedTranscriptSpan(
            id: "decimal",
            category: .number,
            acceptedForms: ["ninety nine"]
        )
        let invalid = TranscriptionCompletenessFixture(
            id: "invalid-reference",
            reference: fixture.reference,
            vocabularyTerms: fixture.vocabularyTerms,
            protectedSpans: spans
        )

        #expect(
            invalid.validationIssues().contains(
                "reference does not satisfy protected span decimal"
            )
        )
        #expect(TranscriptionCompletenessOracle.compare(
            fixture: invalid,
            baseline: invalid.reference,
            candidate: invalid.reference
        ) == nil)
    }

    @Test
    func retainedManifestsAreBoundToCheckedInAudio() throws {
        let fixtureDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
        let fixtures = [
            ("english-completeness-v1", 201_154),
            ("english-boundary-long-v1", 788_154),
        ]
        for (name, sampleCount) in fixtures {
            let fixtureData = try Data(
                contentsOf: fixtureDirectory.appendingPathComponent("\(name).json")
            )
            let retainedFixture = try JSONDecoder().decode(
                TranscriptionCompletenessFixture.self,
                from: fixtureData
            )
            let audioData = try Data(
                contentsOf: fixtureDirectory.appendingPathComponent("\(name).aiff")
            )
            let audioHash = SHA256.hash(data: audioData)
                .map { String(format: "%02x", $0) }
                .joined()

            #expect(
                retainedFixture.validationIssues(requireAudioIdentity: true).isEmpty
            )
            #expect(retainedFixture.audioSHA256 == audioHash)
            #expect(retainedFixture.sampleCount == sampleCount)
            #expect(retainedFixture.sampleRate == 16_000)
        }
    }
}

private extension String {
    func replacing(_ target: String, with replacement: String) -> String {
        replacingOccurrences(of: target, with: replacement)
    }
}
