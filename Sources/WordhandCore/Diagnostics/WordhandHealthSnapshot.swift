import Foundation

public struct WordhandHealthSnapshot: Equatable, Sendable {
    public static let periodDays = 7

    public let windowStartedAt: Date
    public let generatedAt: Date
    public let completedDictationCount: Int
    public let failureEventCount: Int
    public let medianCompletionSeconds: Double?
    public let tailRecoveryDictationCount: Int
    public let correctedReferenceCount: Int
    public let pairedRecordingCount: Int

    public init(
        windowStartedAt: Date,
        generatedAt: Date,
        completedDictationCount: Int,
        failureEventCount: Int,
        medianCompletionSeconds: Double?,
        tailRecoveryDictationCount: Int,
        correctedReferenceCount: Int,
        pairedRecordingCount: Int
    ) {
        self.windowStartedAt = windowStartedAt
        self.generatedAt = generatedAt
        self.completedDictationCount = completedDictationCount
        self.failureEventCount = failureEventCount
        self.medianCompletionSeconds = medianCompletionSeconds
        self.tailRecoveryDictationCount = tailRecoveryDictationCount
        self.correctedReferenceCount = correctedReferenceCount
        self.pairedRecordingCount = pairedRecordingCount
    }

    public static func make(
        generatedAt: Date,
        events: [OperationalDiagnosticEvent],
        labeledTranscriptIDs: Set<UUID>,
        retainedRecordingIDs: Set<UUID>
    ) -> Self {
        let windowStartedAt = periodStart(endingAt: generatedAt)
        let recentEvents = events.filter {
            $0.occurredAt >= windowStartedAt && $0.occurredAt <= generatedAt
        }
        let completedByDictation = latestEventsByDictation(
            recentEvents.filter { $0.name == "dictation.completed" }
        )
        let completionDurations = completedByDictation.values.compactMap {
            event -> Double? in
            guard let duration = event.metrics["total_seconds"],
                  duration.isFinite,
                  duration >= 0
            else {
                return nil
            }
            return duration
        }
        let recoveryIDs = Set(
            recentEvents.compactMap { event -> UUID? in
                guard event.name == "transcription.completed",
                      let dictationID = event.dictationID,
                      ["merged", "full_retry_recovered"].contains(
                          event.attributes["tail_outcome"]
                      )
                else {
                    return nil
                }
                return dictationID
            }
        )

        return self.init(
            windowStartedAt: windowStartedAt,
            generatedAt: generatedAt,
            completedDictationCount: completedByDictation.count,
            failureEventCount: recentEvents.filter { $0.severity == .error }.count,
            medianCompletionSeconds: median(completionDurations),
            tailRecoveryDictationCount: recoveryIDs.count,
            correctedReferenceCount: labeledTranscriptIDs.count,
            pairedRecordingCount: labeledTranscriptIDs
                .intersection(retainedRecordingIDs)
                .count
        )
    }

    public static func periodStart(endingAt date: Date) -> Date {
        date.addingTimeInterval(-Double(periodDays) * 86_400)
    }

    private static func latestEventsByDictation(
        _ events: [OperationalDiagnosticEvent]
    ) -> [UUID: OperationalDiagnosticEvent] {
        events.reduce(into: [:]) { latest, event in
            guard let dictationID = event.dictationID else { return }
            guard let current = latest[dictationID] else {
                latest[dictationID] = event
                return
            }
            if event.occurredAt > current.occurredAt
                || (
                    event.occurredAt == current.occurredAt
                        && event.id.uuidString > current.id.uuidString
                )
            {
                latest[dictationID] = event
            }
        }
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }
}
