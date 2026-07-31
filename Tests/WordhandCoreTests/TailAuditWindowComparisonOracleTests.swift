import Foundation
import Testing
@testable import WordhandCore

@Suite
struct TailAuditWindowComparisonOracleTests {
    @Test
    func promotesOnlyExactStableFasterCandidateThatAvoidsFullRetry() {
        let decision = TailAuditWindowComparisonOracle.evaluate(
            baselineWindowSeconds: 20,
            candidateWindowSeconds: 30,
            protectedCompletenessPassed: true,
            runs: [
                run(
                    iteration: 1,
                    order: "baseline-candidate",
                    baselineSeconds: 8,
                    candidateSeconds: 5,
                    baselineFullRetry: true,
                    candidateFullRetry: false
                ),
                run(
                    iteration: 2,
                    order: "candidate-baseline",
                    baselineSeconds: 8.2,
                    candidateSeconds: 5.1,
                    baselineFullRetry: true,
                    candidateFullRetry: false
                ),
            ]
        )

        #expect(decision.evidenceIsValid)
        #expect(decision.everyTranscriptIsExact)
        #expect(decision.baselineIsDeterministic)
        #expect(decision.baselineFullRetryCount == 2)
        #expect(decision.candidateFullRetryCount == 0)
        #expect(decision.candidatePassesPromotionGate)
        #expect(decision.rejectionReasons.isEmpty)
    }

    @Test
    func transcriptDifferenceAlwaysRejectsEvenWithLargeLatencyWin() {
        var mismatch = run(
            iteration: 2,
            order: "candidate-baseline",
            baselineSeconds: 9,
            candidateSeconds: 2,
            baselineFullRetry: true,
            candidateFullRetry: false
        )
        mismatch.candidateTranscriptSHA256 = String(repeating: "b", count: 64)
        let decision = TailAuditWindowComparisonOracle.evaluate(
            baselineWindowSeconds: 20,
            candidateWindowSeconds: 30,
            protectedCompletenessPassed: true,
            runs: [
                run(
                    iteration: 1,
                    order: "baseline-candidate",
                    baselineSeconds: 9,
                    candidateSeconds: 2,
                    baselineFullRetry: true,
                    candidateFullRetry: false
                ),
                mismatch,
            ]
        )

        #expect(!decision.candidatePassesPromotionGate)
        #expect(decision.rejectionReasons.contains("transcript_mismatch"))
    }

    @Test
    func unstableAuthorityRejectsEvenWhenEachPairHappensToMatch() {
        var second = run(
            iteration: 2,
            order: "candidate-baseline",
            baselineSeconds: 8,
            candidateSeconds: 4,
            baselineFullRetry: true,
            candidateFullRetry: false
        )
        second.baselineTranscriptSHA256 = String(repeating: "c", count: 64)
        second.candidateTranscriptSHA256 = String(repeating: "c", count: 64)
        let decision = TailAuditWindowComparisonOracle.evaluate(
            baselineWindowSeconds: 20,
            candidateWindowSeconds: 30,
            protectedCompletenessPassed: true,
            runs: [
                run(
                    iteration: 1,
                    order: "baseline-candidate",
                    baselineSeconds: 8,
                    candidateSeconds: 4,
                    baselineFullRetry: true,
                    candidateFullRetry: false
                ),
                second,
            ]
        )

        #expect(!decision.candidatePassesPromotionGate)
        #expect(decision.rejectionReasons.contains("baseline_nondeterministic"))
    }

    @Test
    func noRetryReductionOrMaterialLatencyWinRejects() {
        let noRetryReduction = TailAuditWindowComparisonOracle.evaluate(
            baselineWindowSeconds: 20,
            candidateWindowSeconds: 30,
            protectedCompletenessPassed: true,
            runs: [
                run(
                    iteration: 1,
                    order: "baseline-candidate",
                    baselineSeconds: 8,
                    candidateSeconds: 5,
                    baselineFullRetry: true,
                    candidateFullRetry: true
                ),
                run(
                    iteration: 2,
                    order: "candidate-baseline",
                    baselineSeconds: 8,
                    candidateSeconds: 5,
                    baselineFullRetry: true,
                    candidateFullRetry: true
                ),
            ]
        )
        #expect(
            noRetryReduction.rejectionReasons.contains(
                "full_retry_not_reduced"
            )
        )

        let tooSmall = TailAuditWindowComparisonOracle.evaluate(
            baselineWindowSeconds: 20,
            candidateWindowSeconds: 30,
            protectedCompletenessPassed: true,
            runs: [
                run(
                    iteration: 1,
                    order: "baseline-candidate",
                    baselineSeconds: 8,
                    candidateSeconds: 7.8,
                    baselineFullRetry: true,
                    candidateFullRetry: false
                ),
                run(
                    iteration: 2,
                    order: "candidate-baseline",
                    baselineSeconds: 8,
                    candidateSeconds: 7.8,
                    baselineFullRetry: true,
                    candidateFullRetry: false
                ),
            ]
        )
        #expect(
            tooSmall.rejectionReasons.contains("latency_win_not_material")
        )
    }

    @Test
    func malformedOrUnbalancedEvidenceFailsClosed() {
        var invalid = run(
            iteration: 1,
            order: "candidate-baseline",
            baselineSeconds: .nan,
            candidateSeconds: 1,
            baselineFullRetry: false,
            candidateFullRetry: false
        )
        invalid.baselineTranscriptSHA256 = "not-a-hash"
        let decision = TailAuditWindowComparisonOracle.evaluate(
            baselineWindowSeconds: 30,
            candidateWindowSeconds: 20,
            protectedCompletenessPassed: false,
            runs: [invalid]
        )

        #expect(!decision.evidenceIsValid)
        #expect(!decision.candidatePassesPromotionGate)
        #expect(decision.rejectionReasons.contains("invalid_evidence"))
    }

    @Test
    func nonThirtySecondCandidateFailsClosed() {
        let decision = TailAuditWindowComparisonOracle.evaluate(
            baselineWindowSeconds: 20,
            candidateWindowSeconds: 29,
            protectedCompletenessPassed: true,
            runs: [
                run(
                    iteration: 1,
                    order: "baseline-candidate",
                    baselineSeconds: 8,
                    candidateSeconds: 4,
                    baselineFullRetry: true,
                    candidateFullRetry: false
                ),
                run(
                    iteration: 2,
                    order: "candidate-baseline",
                    baselineSeconds: 8,
                    candidateSeconds: 4,
                    baselineFullRetry: true,
                    candidateFullRetry: false
                ),
            ]
        )

        #expect(!decision.evidenceIsValid)
        #expect(!decision.candidatePassesPromotionGate)
        #expect(decision.rejectionReasons == ["invalid_evidence"])
    }

    @Test
    func privateExactHashesCannotReplaceProtectedFixtureProof() {
        let decision = TailAuditWindowComparisonOracle.evaluate(
            baselineWindowSeconds: 20,
            candidateWindowSeconds: 30,
            protectedCompletenessPassed: false,
            runs: [
                run(
                    iteration: 1,
                    order: "baseline-candidate",
                    baselineSeconds: 8,
                    candidateSeconds: 4,
                    baselineFullRetry: true,
                    candidateFullRetry: false
                ),
                run(
                    iteration: 2,
                    order: "candidate-baseline",
                    baselineSeconds: 8,
                    candidateSeconds: 4,
                    baselineFullRetry: true,
                    candidateFullRetry: false
                ),
            ]
        )

        #expect(!decision.candidatePassesPromotionGate)
        #expect(
            decision.rejectionReasons.contains(
                "protected_completeness_unproven"
            )
        )
    }

    private func run(
        iteration: Int,
        order: String,
        baselineSeconds: Double,
        candidateSeconds: Double,
        baselineFullRetry: Bool,
        candidateFullRetry: Bool
    ) -> TailAuditWindowRunEvidence {
        TailAuditWindowRunEvidence(
            iteration: iteration,
            order: order,
            baselineTranscriptSHA256: String(repeating: "a", count: 64),
            candidateTranscriptSHA256: String(repeating: "a", count: 64),
            baselineStopToFinalSeconds: baselineSeconds,
            candidateStopToFinalSeconds: candidateSeconds,
            baselineFullRetryPerformed: baselineFullRetry,
            candidateFullRetryPerformed: candidateFullRetry,
            baselineTailOutcome:
                baselineFullRetry ? .fullRetryRecovered : .verifiedCovered,
            candidateTailOutcome:
                candidateFullRetry ? .fullRetryRecovered : .merged
        )
    }
}
