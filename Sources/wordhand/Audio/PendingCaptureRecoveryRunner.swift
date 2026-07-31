import Foundation
import WordhandCore

@MainActor
func recoverPendingCapturesInOrder(
    _ captures: [RecoveredAudioCapture],
    recover: (RecoveredAudioCapture) async -> Bool,
    currentFailure: () -> DictationFailure?,
    resetFailure: () -> Void,
    discard: (UUID) throws -> Void,
    surfacePreservedFailure: (String) -> Void
) async throws {
    var preservedFailureMessage: String?
    for capture in captures {
        if await recover(capture) {
            try discard(capture.id)
            continue
        }
        guard case .preservedForRecovery(let message) = currentFailure() else {
            return
        }
        preservedFailureMessage = message
        resetFailure()
    }
    if let preservedFailureMessage {
        surfacePreservedFailure(preservedFailureMessage)
    }
}
