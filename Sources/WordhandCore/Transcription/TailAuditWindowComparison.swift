import Foundation

public struct TailAuditWindowRunEvidence: Codable, Equatable, Sendable {
    public var iteration: Int
    public var order: String
    public var baselineTranscriptSHA256: String
    public var candidateTranscriptSHA256: String
    public var baselineStopToFinalSeconds: TimeInterval
    public var candidateStopToFinalSeconds: TimeInterval
    public var baselineFullRetryPerformed: Bool
    public var candidateFullRetryPerformed: Bool
    public var baselineTailOutcome: TailRecoveryOutcome
    public var candidateTailOutcome: TailRecoveryOutcome

    public init(
        iteration: Int,
        order: String,
        baselineTranscriptSHA256: String,
        candidateTranscriptSHA256: String,
        baselineStopToFinalSeconds: TimeInterval,
        candidateStopToFinalSeconds: TimeInterval,
        baselineFullRetryPerformed: Bool,
        candidateFullRetryPerformed: Bool,
        baselineTailOutcome: TailRecoveryOutcome,
        candidateTailOutcome: TailRecoveryOutcome
    ) {
        self.iteration = iteration
        self.order = order
        self.baselineTranscriptSHA256 = baselineTranscriptSHA256
        self.candidateTranscriptSHA256 = candidateTranscriptSHA256
        self.baselineStopToFinalSeconds = baselineStopToFinalSeconds
        self.candidateStopToFinalSeconds = candidateStopToFinalSeconds
        self.baselineFullRetryPerformed = baselineFullRetryPerformed
        self.candidateFullRetryPerformed = candidateFullRetryPerformed
        self.baselineTailOutcome = baselineTailOutcome
        self.candidateTailOutcome = candidateTailOutcome
    }
}

public struct TailAuditWindowComparisonDecision:
    Codable,
    Equatable,
    Sendable
{
    public let evidenceIsValid: Bool
    public let everyTranscriptIsExact: Bool
    public let baselineIsDeterministic: Bool
    public let candidateIsDeterministic: Bool
    public let baselineFullRetryCount: Int
    public let candidateFullRetryCount: Int
    public let baselineMedianStopToFinalSeconds: TimeInterval
    public let candidateMedianStopToFinalSeconds: TimeInterval
    public let candidatePassesPromotionGate: Bool
    public let rejectionReasons: [String]
}

public enum TailAuditWindowComparisonOracle {
    public static func evaluate(
        baselineWindowSeconds: Int,
        candidateWindowSeconds: Int,
        protectedCompletenessPassed: Bool,
        runs: [TailAuditWindowRunEvidence]
    ) -> TailAuditWindowComparisonDecision {
        let evidenceIsValid = validEvidence(
            baselineWindowSeconds: baselineWindowSeconds,
            candidateWindowSeconds: candidateWindowSeconds,
            runs: runs
        )
        let everyTranscriptIsExact =
            evidenceIsValid
            && runs.allSatisfy {
                $0.baselineTranscriptSHA256
                    == $0.candidateTranscriptSHA256
            }
        let baselineHashes = Set(runs.map(\.baselineTranscriptSHA256))
        let candidateHashes = Set(runs.map(\.candidateTranscriptSHA256))
        let baselineIsDeterministic =
            evidenceIsValid && baselineHashes.count == 1
        let candidateIsDeterministic =
            evidenceIsValid && candidateHashes.count == 1
        let baselineFullRetryCount = runs.count {
            $0.baselineFullRetryPerformed
        }
        let candidateFullRetryCount = runs.count {
            $0.candidateFullRetryPerformed
        }
        let baselineMedian = median(
            runs.map(\.baselineStopToFinalSeconds)
        )
        let candidateMedian = median(
            runs.map(\.candidateStopToFinalSeconds)
        )
        let materiallyFaster =
            evidenceIsValid
            && candidateMedian
                <= baselineMedian - max(0.25, baselineMedian * 0.05)

        var reasons: [String] = []
        if !evidenceIsValid {
            reasons.append("invalid_evidence")
        } else {
            if !everyTranscriptIsExact {
                reasons.append("transcript_mismatch")
            }
            if !baselineIsDeterministic {
                reasons.append("baseline_nondeterministic")
            }
            if !candidateIsDeterministic {
                reasons.append("candidate_nondeterministic")
            }
            if !protectedCompletenessPassed {
                reasons.append("protected_completeness_unproven")
            }
            if candidateFullRetryCount >= baselineFullRetryCount {
                reasons.append("full_retry_not_reduced")
            }
            if !materiallyFaster {
                reasons.append("latency_win_not_material")
            }
        }
        return TailAuditWindowComparisonDecision(
            evidenceIsValid: evidenceIsValid,
            everyTranscriptIsExact: everyTranscriptIsExact,
            baselineIsDeterministic: baselineIsDeterministic,
            candidateIsDeterministic: candidateIsDeterministic,
            baselineFullRetryCount: baselineFullRetryCount,
            candidateFullRetryCount: candidateFullRetryCount,
            baselineMedianStopToFinalSeconds: baselineMedian,
            candidateMedianStopToFinalSeconds: candidateMedian,
            candidatePassesPromotionGate: reasons.isEmpty,
            rejectionReasons: reasons
        )
    }

    private static func validEvidence(
        baselineWindowSeconds: Int,
        candidateWindowSeconds: Int,
        runs: [TailAuditWindowRunEvidence]
    ) -> Bool {
        guard baselineWindowSeconds == 20,
              candidateWindowSeconds == 30,
              (2...10).contains(runs.count),
              runs.count.isMultiple(of: 2)
        else {
            return false
        }
        return runs.enumerated().allSatisfy { offset, run in
            let expectedIteration = offset + 1
            let expectedOrder = expectedIteration.isMultiple(of: 2)
                ? "candidate-baseline"
                : "baseline-candidate"
            return run.iteration == expectedIteration
                && run.order == expectedOrder
                && validSHA256(run.baselineTranscriptSHA256)
                && validSHA256(run.candidateTranscriptSHA256)
                && run.baselineStopToFinalSeconds.isFinite
                && run.baselineStopToFinalSeconds > 0
                && run.candidateStopToFinalSeconds.isFinite
                && run.candidateStopToFinalSeconds > 0
                && validOutcome(
                    run.baselineTailOutcome,
                    fullRetryPerformed: run.baselineFullRetryPerformed
                )
                && validOutcome(
                    run.candidateTailOutcome,
                    fullRetryPerformed: run.candidateFullRetryPerformed
                )
        }
    }

    private static func validOutcome(
        _ outcome: TailRecoveryOutcome,
        fullRetryPerformed: Bool
    ) -> Bool {
        if fullRetryPerformed {
            return outcome == .fullRetryRecovered
                || outcome == .noImprovement
        }
        return outcome == .merged || outcome == .verifiedCovered
    }

    private static func validSHA256(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy {
                (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
                    || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
            }
    }

    private static func median(_ values: [TimeInterval]) -> TimeInterval {
        let finite = values.filter(\.isFinite).sorted()
        guard !finite.isEmpty else { return 0 }
        let middle = finite.count / 2
        if finite.count.isMultiple(of: 2) {
            return (finite[middle - 1] + finite[middle]) / 2
        }
        return finite[middle]
    }
}
