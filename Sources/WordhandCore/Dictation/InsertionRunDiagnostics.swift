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

public enum InsertionPostAction: String, Codable, Sendable {
    case none
    case returnKey = "return_key"
}

public enum InsertionPostActionOutcome: String, Sendable {
    case notRequested = "not_requested"
    case performed
    case skippedUnverified = "skipped_unverified"
    case unsupportedMode = "unsupported_mode"
    case failed
}

public struct InsertionRunDiagnostics: Equatable, Sendable {
    public var mode: InsertionMode
    public var verification: InsertionVerificationOutcome
    public var retryCount: Int
    public var checkpointAvailable: Bool
    public var secureInputBlocked: Bool
    public var undoAvailable: Bool
    public var postActionOutcome: InsertionPostActionOutcome

    public init(
        mode: InsertionMode,
        verification: InsertionVerificationOutcome = .notAttempted,
        retryCount: Int = 0,
        checkpointAvailable: Bool = false,
        secureInputBlocked: Bool = false,
        undoAvailable: Bool = false,
        postActionOutcome: InsertionPostActionOutcome = .notRequested
    ) {
        self.mode = mode
        self.verification = verification
        self.retryCount = retryCount
        self.checkpointAvailable = checkpointAvailable
        self.secureInputBlocked = secureInputBlocked
        self.undoAvailable = undoAvailable
        self.postActionOutcome = postActionOutcome
    }
}

public protocol InsertionDiagnosticsProviding: Sendable {
    func lastInsertionDiagnostics() async -> InsertionRunDiagnostics
}

public protocol PostActionTextInserting: TextInserting {
    func insert(
        _ text: String,
        mode: InsertionMode,
        postAction: InsertionPostAction
    ) async throws
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
