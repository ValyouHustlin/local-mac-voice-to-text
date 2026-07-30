import Foundation
import Testing
@testable import WordhandCore

@Suite
struct OperationalDiagnosticsStoreTests {
    @Test
    func storesOwnerOnlyStructuredEventsWithoutTranscriptFields() throws {
        let fixture = DiagnosticsFixture()
        defer { fixture.remove() }
        let sessionID = UUID()
        let dictationID = UUID()
        let store = try OperationalDiagnosticsStore(
            directoryURL: fixture.directory,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        try store.append(OperationalDiagnosticEvent(
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
            severity: .info,
            name: "transcription.completed",
            sessionID: sessionID,
            dictationID: dictationID,
            metrics: [
                "audio_seconds": 65.09,
                "transcription_seconds": 10.04,
            ],
            attributes: [
                "model_id": "whisper-large-v3-turbo",
                "tail_outcome": "full_retry_recovered",
            ]
        ))

        let events = try store.events()
        let event = try #require(events.first)
        #expect(events.count == 1)
        #expect(event.sessionID == sessionID)
        #expect(event.dictationID == dictationID)
        #expect(event.metrics["audio_seconds"] == 65.09)

        let files = try FileManager.default.contentsOfDirectory(
            at: fixture.directory,
            includingPropertiesForKeys: nil
        )
        let log = try #require(files.first(where: { $0.pathExtension == "jsonl" }))
        let encoded = try String(contentsOf: log, encoding: .utf8)
        #expect(!encoded.contains("raw_text"))
        #expect(!encoded.contains("processed_text"))
        #expect(!encoded.contains("\"text\""))
        #expect(try permissions(at: fixture.directory) == 0o700)
        #expect(try permissions(at: log) == 0o600)
    }

    @Test
    func rejectsTranscriptOrAudioPayloadAttributes() throws {
        let fixture = DiagnosticsFixture()
        defer { fixture.remove() }
        let store = try OperationalDiagnosticsStore(
            directoryURL: fixture.directory
        )
        let event = OperationalDiagnosticEvent(
            severity: .info,
            name: "invalid.test",
            sessionID: UUID(),
            attributes: ["text": "private transcript"]
        )

        #expect(throws: OperationalDiagnosticsError.privatePayloadKey("text")) {
            try store.append(event)
        }
        #expect(try store.events().isEmpty)
    }

    @Test
    func prunesFilesOutsideNinetyDayRetention() throws {
        let fixture = DiagnosticsFixture()
        defer { fixture.remove() }
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = try OperationalDiagnosticsStore(
            directoryURL: fixture.directory,
            retentionDays: 90,
            now: { now }
        )

        try store.append(event(at: now.addingTimeInterval(-91 * 86_400)))
        now = now.addingTimeInterval(91 * 86_400)
        try store.append(event(at: now))

        let events = try store.events()
        #expect(events.count == 1)
        #expect(events.first?.occurredAt == now)
    }

    @Test
    func reportAggregatesHealthLatencyAndTailRecovery() throws {
        let fixture = DiagnosticsFixture()
        defer { fixture.remove() }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = try OperationalDiagnosticsStore(
            directoryURL: fixture.directory,
            now: { now }
        )
        let sessionID = UUID()
        let dictationID = UUID()

        for event in [
            OperationalDiagnosticEvent(
                occurredAt: now,
                severity: .info,
                name: "dictation.started",
                sessionID: sessionID,
                dictationID: dictationID
            ),
            OperationalDiagnosticEvent(
                occurredAt: now,
                severity: .info,
                name: "capture.completed",
                sessionID: sessionID,
                dictationID: dictationID,
                metrics: ["audio_seconds": 60]
            ),
            OperationalDiagnosticEvent(
                occurredAt: now,
                severity: .info,
                name: "transcription.completed",
                sessionID: sessionID,
                dictationID: dictationID,
                metrics: ["transcription_seconds": 4, "audio_seconds": 60],
                attributes: ["tail_outcome": "full_retry_recovered"]
            ),
            OperationalDiagnosticEvent(
                occurredAt: now,
                severity: .error,
                name: "insertion.failed",
                sessionID: sessionID,
                dictationID: dictationID,
                attributes: ["reason": "no_observed_change"]
            ),
        ] {
            try store.append(event)
        }

        let report = try store.report()
        #expect(report.eventCount == 4)
        #expect(report.sessionCount == 1)
        #expect(report.dictationCount == 1)
        #expect(report.completedDictationCount == 0)
        #expect(report.transcriptionCount == 1)
        #expect(report.failureCount == 1)
        #expect(report.tailRecoveryCount == 1)
        #expect(report.averageTranscriptionSeconds == 4)
        #expect(report.averageAudioSeconds == 60)
        #expect(report.medianTranscriptionSeconds == 4)
        #expect(report.p95TranscriptionSeconds == 4)
        #expect(report.failuresByName["insertion.failed"] == 1)
        #expect(report.tailOutcomes["full_retry_recovered"] == 1)
        #expect(report.models.isEmpty)
    }

    @Test
    func storageCeilingRemovesTheOldestDailyFileFirst() throws {
        let fixture = DiagnosticsFixture()
        defer { fixture.remove() }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = try OperationalDiagnosticsStore(
            directoryURL: fixture.directory,
            maximumBytes: 300,
            now: { now }
        )
        let old = event(at: now.addingTimeInterval(-86_400))
        let current = event(at: now)

        try store.append(old)
        try store.append(current)

        let events = try store.events()
        #expect(events.map(\.id) == [current.id])
    }

    @Test
    func storageCeilingTrimsOldestLinesWithinTheCurrentDay() throws {
        let fixture = DiagnosticsFixture()
        defer { fixture.remove() }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = try OperationalDiagnosticsStore(
            directoryURL: fixture.directory,
            maximumBytes: 420,
            now: { now }
        )
        let first = event(at: now)
        let second = event(at: now.addingTimeInterval(1))
        let latest = event(at: now.addingTimeInterval(2))

        try store.append(first)
        try store.append(second)
        try store.append(latest)

        let storage = try store.storageReport()
        #expect(storage.totalBytes <= 420)
        #expect(try store.events().last?.id == latest.id)
    }

    @Test
    func corruptLineDoesNotHideHealthyEventsFromReport() throws {
        let fixture = DiagnosticsFixture()
        defer { fixture.remove() }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = try OperationalDiagnosticsStore(
            directoryURL: fixture.directory,
            now: { now }
        )
        try store.append(event(at: now))
        let file = try #require(
            FileManager.default.contentsOfDirectory(
                at: fixture.directory,
                includingPropertiesForKeys: nil
            ).first(where: { $0.pathExtension == "jsonl" })
        )
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{not-json}\n".utf8))
        try handle.close()

        let report = try store.report()

        #expect(report.eventCount == 1)
        #expect(report.malformedLineCount == 1)
    }

    @Test
    func exportCannotOverwriteTheLiveDailyLog() throws {
        let fixture = DiagnosticsFixture()
        defer { fixture.remove() }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = try OperationalDiagnosticsStore(
            directoryURL: fixture.directory,
            now: { now }
        )
        try store.append(event(at: now))
        let liveFile = try #require(
            FileManager.default.contentsOfDirectory(
                at: fixture.directory,
                includingPropertiesForKeys: nil
            ).first(where: { $0.pathExtension == "jsonl" })
        )

        #expect(throws: OperationalDiagnosticsError.exportOverwritesStore) {
            try store.export(to: liveFile)
        }
        #expect(try store.events().count == 1)
    }

    private func event(at date: Date) -> OperationalDiagnosticEvent {
        OperationalDiagnosticEvent(
            occurredAt: date,
            severity: .info,
            name: "app.launched",
            sessionID: UUID()
        )
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}

private struct DiagnosticsFixture {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "wordhand-diagnostics-\(UUID().uuidString)",
            isDirectory: true
        )

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
