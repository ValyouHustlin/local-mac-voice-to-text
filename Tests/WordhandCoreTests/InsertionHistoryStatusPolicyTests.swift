import Testing
@testable import WordhandCore

@Suite
struct InsertionHistoryStatusPolicyTests {
    @Test
    func recordsOnlyAcknowledgedDeliveryAsInserted() {
        for verification in [
            InsertionVerificationOutcome.verified,
            .verifiedAfterRetry,
            .verifiedWithoutUndo,
        ] {
            #expect(
                InsertionHistoryStatusPolicy.status(
                    for: InsertionRunDiagnostics(
                        mode: .paste,
                        verification: verification
                    )
                ) == .inserted
            )
        }

        for verification in [
            InsertionVerificationOutcome.notAttempted,
            .copyOnly,
            .unavailable,
            .unchangedWithoutRetry,
            .failed,
        ] {
            #expect(
                InsertionHistoryStatusPolicy.status(
                    for: InsertionRunDiagnostics(
                        mode: .paste,
                        verification: verification
                    )
                ) == .insertionPostedUnverified
            )
        }
    }

    @Test
    func copyOnlyIsRecordedAsCopiedInsteadOfInserted() {
        #expect(
            InsertionHistoryStatusPolicy.status(
                for: InsertionRunDiagnostics(
                    mode: .copyOnly,
                    verification: .copyOnly
                )
            ) == .copied
        )
        #expect(
            InsertionHistoryStatusPolicy.status(
                for: InsertionRunDiagnostics(mode: .copyOnly)
            ) == .copied
        )
    }
}
