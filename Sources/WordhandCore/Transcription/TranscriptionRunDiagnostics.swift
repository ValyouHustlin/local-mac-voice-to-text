import Foundation

public enum TailRecoveryOutcome: String, Codable, CaseIterable, Sendable {
    case notAudited = "not_audited"
    case verifiedCovered = "verified_covered"
    case merged
    case fullRetryRecovered = "full_retry_recovered"
    case noImprovement = "no_improvement"
    case auditFailed = "audit_failed"

    public var recoveredMissingText: Bool {
        self == .merged || self == .fullRetryRecovered
    }

    public var historyBadgeTitle: String? {
        recoveredMissingText ? "Tail recovered" : nil
    }

    public static func resolvingFullRetry(
        tailIssueDetected: Bool,
        auditVerifiedCovered: Bool,
        auditFailed: Bool,
        selectedDifferentTranscript: Bool
    ) -> TailRecoveryOutcome {
        guard tailIssueDetected else { return .notAudited }
        if auditVerifiedCovered { return .verifiedCovered }
        if selectedDifferentTranscript { return .fullRetryRecovered }
        if auditFailed { return .auditFailed }
        return .noImprovement
    }
}

public struct TranscriptionRunDiagnostics: Codable, Equatable, Sendable {
    public var tailRecoveryOutcome: TailRecoveryOutcome
    public var primaryWordCount: Int
    public var finalWordCount: Int
    public var fullRetryPerformed: Bool
    public var promptArtifactDetected: Bool
    public var emptyTranscriptRecoveryOutcome:
        EmptyTranscriptRecoveryOutcome
    public var primaryDecodeSeconds: TimeInterval
    public var tailAuditDecodeSeconds: TimeInterval
    public var fullRetryDecodeSeconds: TimeInterval

    public init(
        tailRecoveryOutcome: TailRecoveryOutcome = .notAudited,
        primaryWordCount: Int = 0,
        finalWordCount: Int = 0,
        fullRetryPerformed: Bool = false,
        promptArtifactDetected: Bool = false,
        emptyTranscriptRecoveryOutcome:
            EmptyTranscriptRecoveryOutcome = .notNeeded,
        primaryDecodeSeconds: TimeInterval = 0,
        tailAuditDecodeSeconds: TimeInterval = 0,
        fullRetryDecodeSeconds: TimeInterval = 0
    ) {
        self.tailRecoveryOutcome = tailRecoveryOutcome
        self.primaryWordCount = primaryWordCount
        self.finalWordCount = finalWordCount
        self.fullRetryPerformed = fullRetryPerformed
        self.promptArtifactDetected = promptArtifactDetected
        self.emptyTranscriptRecoveryOutcome =
            emptyTranscriptRecoveryOutcome
        self.primaryDecodeSeconds = primaryDecodeSeconds
        self.tailAuditDecodeSeconds = tailAuditDecodeSeconds
        self.fullRetryDecodeSeconds = fullRetryDecodeSeconds
    }

    public static let none = TranscriptionRunDiagnostics()
}

public protocol TranscriptionDiagnosticsProviding: Sendable {
    func lastRunDiagnostics() async -> TranscriptionRunDiagnostics
}
