import Foundation

public enum InsertionVerificationOutcome: String, Sendable {
    case notAttempted = "not_attempted"
    case copyOnly = "copy_only"
    case verified
    case verifiedAfterRetry = "verified_after_retry"
    case verifiedWithoutUndo = "verified_without_undo"
    case unavailable
    case unchangedWithoutRetry = "unchanged_without_retry"
    case failed
}

public struct InsertionRunDiagnostics: Equatable, Sendable {
    public var mode: InsertionMode
    public var verification: InsertionVerificationOutcome
    public var retryCount: Int
    public var checkpointAvailable: Bool
    public var secureInputBlocked: Bool
    public var undoAvailable: Bool

    public init(
        mode: InsertionMode,
        verification: InsertionVerificationOutcome = .notAttempted,
        retryCount: Int = 0,
        checkpointAvailable: Bool = false,
        secureInputBlocked: Bool = false,
        undoAvailable: Bool = false
    ) {
        self.mode = mode
        self.verification = verification
        self.retryCount = retryCount
        self.checkpointAvailable = checkpointAvailable
        self.secureInputBlocked = secureInputBlocked
        self.undoAvailable = undoAvailable
    }
}

public protocol InsertionDiagnosticsProviding: Sendable {
    func lastInsertionDiagnostics() async -> InsertionRunDiagnostics
}

public enum InsertionHistoryStatusPolicy {
    public static func status(
        for diagnostics: InsertionRunDiagnostics
    ) -> TranscriptInsertionStatus {
        if diagnostics.mode == .copyOnly {
            return .copied
        }
        switch diagnostics.verification {
        case .verified, .verifiedAfterRetry, .verifiedWithoutUndo:
            return .inserted
        case .notAttempted, .copyOnly, .unavailable, .unchangedWithoutRetry,
             .failed:
            return .insertionPostedUnverified
        }
    }
}
