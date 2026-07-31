import Foundation

public enum EmptyTranscriptRecoveryAction: Equatable, Sendable {
    case acceptPrimary
    case retryPromptFree
    case treatAsSilence
}

public enum EmptyTranscriptRecoveryOutcome:
    String,
    Codable,
    Equatable,
    Sendable
{
    case notNeeded = "not_needed"
    case recovered
    case noImprovement = "no_improvement"
    case retryFailed = "retry_failed"
    case quietAudio = "quiet_audio"
}

public struct EmptyTranscriptRecoveryResult: Equatable, Sendable {
    public let text: String
    public let retryPerformed: Bool
    public let outcome: EmptyTranscriptRecoveryOutcome

    public init(
        text: String,
        retryPerformed: Bool,
        outcome: EmptyTranscriptRecoveryOutcome
    ) {
        self.text = text
        self.retryPerformed = retryPerformed
        self.outcome = outcome
    }
}

public enum EmptyTranscriptRecoveryPolicy {
    public static func action(
        primaryText: String,
        signal: AudioSignalMetrics
    ) -> EmptyTranscriptRecoveryAction {
        guard primaryText.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            return .acceptPrimary
        }
        return hasMeaningfulActivity(signal)
            ? .retryPromptFree
            : .treatAsSilence
    }

    public static func select(
        primaryText: String,
        retryText: String
    ) -> String {
        guard primaryText.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            return primaryText
        }
        return retryText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func recover(
        primaryText: String,
        signal: AudioSignalMetrics,
        promptFreeRetry: () async throws -> String
    ) async rethrows -> EmptyTranscriptRecoveryResult {
        switch action(primaryText: primaryText, signal: signal) {
        case .acceptPrimary:
            return EmptyTranscriptRecoveryResult(
                text: primaryText,
                retryPerformed: false,
                outcome: .notNeeded
            )
        case .treatAsSilence:
            return EmptyTranscriptRecoveryResult(
                text: primaryText,
                retryPerformed: false,
                outcome: .quietAudio
            )
        case .retryPromptFree:
            let retryText = try await promptFreeRetry()
            let selected = select(
                primaryText: primaryText,
                retryText: retryText
            )
            return EmptyTranscriptRecoveryResult(
                text: selected,
                retryPerformed: true,
                outcome: selected.isEmpty ? .noImprovement : .recovered
            )
        }
    }

    public static func hasMeaningfulActivity(
        _ signal: AudioSignalMetrics
    ) -> Bool {
        guard signal.sampleCount > 0,
              signal.activeWindowFraction >= 0.1
        else {
            return false
        }
        return signal.rms >= 0.003 || signal.peak >= 0.02
    }
}
