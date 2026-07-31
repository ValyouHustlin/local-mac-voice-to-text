import Foundation
import Testing
@testable import WordhandCore

@Suite
struct WordhandHealthSnapshotTests {
    @Test
    func sevenDayWindowIncludesBothBoundariesAndExcludesOutsideEvents() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let start = WordhandHealthSnapshot.periodStart(endingAt: now)
        let firstID = UUID()
        let finalID = UUID()
        let events = [
            event(
                at: start.addingTimeInterval(-0.001),
                name: "dictation.completed",
                dictationID: UUID(),
                metrics: ["total_seconds": 99]
            ),
            event(
                at: start,
                name: "dictation.completed",
                dictationID: firstID,
                metrics: ["total_seconds": 2]
            ),
            event(
                at: now,
                name: "dictation.completed",
                dictationID: finalID,
                metrics: ["total_seconds": 4]
            ),
            event(
                at: now.addingTimeInterval(0.001),
                severity: .error,
                name: "future.failure"
            ),
        ]

        let snapshot = WordhandHealthSnapshot.make(
            generatedAt: now,
            events: events,
            labeledTranscriptIDs: [],
            retainedRecordingIDs: []
        )

        #expect(snapshot.windowStartedAt == start)
        #expect(snapshot.generatedAt == now)
        #expect(snapshot.completedDictationCount == 2)
        #expect(snapshot.medianCompletionSeconds == 3)
        #expect(snapshot.failureEventCount == 0)
    }

    @Test
    func duplicateCompletionsUseLatestValidDurationAndExactMedian() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let firstID = UUID()
        let secondID = UUID()
        let invalidIDs = [UUID(), UUID(), UUID(), UUID()]
        let events = [
            event(
                at: now.addingTimeInterval(-5),
                name: "dictation.completed",
                dictationID: firstID,
                metrics: ["total_seconds": 100]
            ),
            event(
                at: now.addingTimeInterval(-4),
                name: "dictation.completed",
                dictationID: firstID,
                metrics: ["total_seconds": 2]
            ),
            event(
                at: now.addingTimeInterval(-3),
                name: "dictation.completed",
                dictationID: secondID,
                metrics: ["total_seconds": 6]
            ),
            event(
                at: now,
                name: "dictation.completed",
                dictationID: invalidIDs[0],
                metrics: [:]
            ),
            event(
                at: now,
                name: "dictation.completed",
                dictationID: invalidIDs[1],
                metrics: ["total_seconds": -1]
            ),
            event(
                at: now,
                name: "dictation.completed",
                dictationID: invalidIDs[2],
                metrics: ["total_seconds": .nan]
            ),
            event(
                at: now,
                name: "dictation.completed",
                dictationID: invalidIDs[3],
                metrics: ["total_seconds": .infinity]
            ),
            event(
                at: now,
                name: "dictation.completed",
                metrics: ["total_seconds": 8]
            ),
        ]

        let snapshot = WordhandHealthSnapshot.make(
            generatedAt: now,
            events: events,
            labeledTranscriptIDs: [],
            retainedRecordingIDs: []
        )

        #expect(snapshot.completedDictationCount == 6)
        #expect(snapshot.medianCompletionSeconds == 4)
    }

    @Test
    func failuresAndTailRecoveriesKeepTheirHonestCountingUnits() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let recoveredID = UUID()
        let retryID = UUID()
        let events = [
            event(at: now, severity: .error, name: "app.failure"),
            event(at: now, severity: .error, name: "insertion.failed", dictationID: UUID()),
            event(at: now, severity: .warning, name: "capture.warning"),
            event(at: now, name: "dictation.cancelled", dictationID: UUID()),
            event(
                at: now,
                name: "transcription.completed",
                dictationID: recoveredID,
                attributes: ["tail_outcome": "merged"]
            ),
            event(
                at: now,
                name: "transcription.completed",
                dictationID: recoveredID,
                attributes: ["tail_outcome": "full_retry_recovered"]
            ),
            event(
                at: now,
                name: "transcription.completed",
                dictationID: retryID,
                attributes: ["tail_outcome": "full_retry_recovered"]
            ),
            event(
                at: now,
                name: "transcription.completed",
                dictationID: UUID(),
                attributes: ["tail_outcome": "covered"]
            ),
        ]

        let snapshot = WordhandHealthSnapshot.make(
            generatedAt: now,
            events: events,
            labeledTranscriptIDs: [],
            retainedRecordingIDs: []
        )

        #expect(snapshot.failureEventCount == 2)
        #expect(snapshot.tailRecoveryDictationCount == 2)
    }

    @Test
    func qualityEvidenceCountsOnlyCorrectedTranscriptsWithPairedAudio() {
        let correctedWithAudio = UUID()
        let correctedWithoutAudio = UUID()
        let orphanAudio = UUID()

        let snapshot = WordhandHealthSnapshot.make(
            generatedAt: Date(timeIntervalSince1970: 2_000_000),
            events: [],
            labeledTranscriptIDs: [
                correctedWithAudio,
                correctedWithoutAudio,
            ],
            retainedRecordingIDs: [
                correctedWithAudio,
                orphanAudio,
            ]
        )

        #expect(snapshot.completedDictationCount == 0)
        #expect(snapshot.medianCompletionSeconds == nil)
        #expect(snapshot.correctedReferenceCount == 2)
        #expect(snapshot.pairedRecordingCount == 1)
        #expect(snapshot.pairedRecordingCount <= snapshot.correctedReferenceCount)
    }

    private func event(
        at date: Date,
        severity: DiagnosticSeverity = .info,
        name: String,
        dictationID: UUID? = nil,
        metrics: [String: Double] = [:],
        attributes: [String: String] = [:]
    ) -> OperationalDiagnosticEvent {
        OperationalDiagnosticEvent(
            occurredAt: date,
            severity: severity,
            name: name,
            sessionID: UUID(),
            dictationID: dictationID,
            metrics: metrics,
            attributes: attributes
        )
    }
}
