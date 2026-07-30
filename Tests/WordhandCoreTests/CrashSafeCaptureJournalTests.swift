import Foundation
import Testing
@testable import WordhandCore

@Suite
struct CrashSafeCaptureJournalTests {
    @Test
    func recoversEveryAcknowledgedSampleBitForBitAfterReopen() throws {
        let fixture = TemporaryCaptureJournal()
        defer { fixture.remove() }
        let id = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let chunks: [[Float]] = [
            [-1, -0.0, 0.125],
            [Float(bitPattern: 0x3f7f_ffff), 42.5],
            [0, -0.75, 1],
        ]

        try fixture.journal.beginCapture(
            id: id,
            createdAt: createdAt,
            sampleRate: 16_000
        )
        for chunk in chunks {
            try fixture.journal.append(chunk)
        }
        try fixture.journal.finishCapture()

        let reopened = CrashSafeCaptureJournal(directoryURL: fixture.directory)
        let recovered = try #require(reopened.recoverableCaptures().only)
        let expected = chunks.flatMap { $0 }
        #expect(recovered.id == id)
        #expect(recovered.createdAt == createdAt)
        #expect(recovered.sampleRate == 16_000)
        #expect(recovered.samples.map(\.bitPattern) == expected.map(\.bitPattern))
        #expect(recovered.samples.first?.bitPattern == expected.first?.bitPattern)
        #expect(recovered.samples.last?.bitPattern == expected.last?.bitPattern)
    }

    @Test
    func ignoresATornFinalFrameAndKeepsEveryEarlierFrame() throws {
        let fixture = TemporaryCaptureJournal()
        defer { fixture.remove() }
        let id = UUID()
        try fixture.journal.beginCapture(
            id: id,
            createdAt: Date(),
            sampleRate: 16_000
        )
        try fixture.journal.append([0.1, 0.2, 0.3])
        try fixture.journal.append([0.4, 0.5])
        try fixture.journal.finishCapture()

        let url = fixture.journal.audioURL(for: id)
        var data = try Data(contentsOf: url)
        data.removeLast(3)
        try data.write(to: url)

        let recovered = try #require(fixture.journal.recoverableCaptures().only)
        let expected: [Float] = [0.1, 0.2, 0.3]
        #expect(recovered.samples.map(\.bitPattern) == expected.map(\.bitPattern))
    }

    @Test
    func journalRemainsUntilHistoryCommitThenDeletesBothFiles() throws {
        let fixture = TemporaryCaptureJournal()
        defer { fixture.remove() }
        let id = UUID()
        try fixture.journal.beginCapture(
            id: id,
            createdAt: Date(),
            sampleRate: 16_000
        )
        try fixture.journal.append([0.25])
        try fixture.journal.finishCapture()

        #expect(try fixture.journal.recoverableCaptures().count == 1)
        try fixture.journal.discard(id: id)
        #expect(try fixture.journal.recoverableCaptures().isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.journal.audioURL(for: id).path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: fixture.journal.manifestURL(for: id).path
        ))
    }

    @Test
    func createsOwnerOnlyDirectoryAndFiles() throws {
        let fixture = TemporaryCaptureJournal()
        defer { fixture.remove() }
        let id = UUID()
        try fixture.journal.beginCapture(
            id: id,
            createdAt: Date(),
            sampleRate: 16_000
        )

        #expect(try permissions(at: fixture.directory) == 0o700)
        #expect(try permissions(at: fixture.journal.audioURL(for: id)) == 0o600)
        #expect(try permissions(at: fixture.journal.manifestURL(for: id)) == 0o600)
    }

    @Test
    func fourMinuteEquivalentPreservesExactBeginningEndingAndCount() throws {
        let fixture = TemporaryCaptureJournal()
        defer { fixture.remove() }
        let id = UUID()
        let totalSamples = 4 * 60 * 16_000
        // A 1,024-frame 48 kHz input tap converts to roughly 341 samples at
        // the journal's 16 kHz rate.
        let chunkSize = 341
        try fixture.journal.beginCapture(
            id: id,
            createdAt: Date(),
            sampleRate: 16_000
        )
        var written = 0
        while written < totalSamples {
            let count = min(chunkSize, totalSamples - written)
            var chunk = Array(repeating: Float(0.25), count: count)
            if written == 0 {
                chunk[0] = Float(bitPattern: 0x8000_0000)
            }
            if written + count == totalSamples {
                chunk[count - 1] = Float(bitPattern: 0x3f7f_ffff)
            }
            try fixture.journal.append(chunk)
            written += count
        }
        try fixture.journal.finishCapture()

        let recovered = try #require(fixture.journal.recoverableCaptures().only)
        #expect(recovered.samples.count == totalSamples)
        #expect(recovered.samples.first?.bitPattern == 0x8000_0000)
        #expect(recovered.samples.last?.bitPattern == 0x3f7f_ffff)
    }

    @Test
    func corruptManifestDoesNotHideAnotherHealthyCapture() throws {
        let fixture = TemporaryCaptureJournal()
        defer { fixture.remove() }
        let corruptID = UUID()
        let healthyID = UUID()

        try fixture.journal.beginCapture(
            id: corruptID,
            createdAt: Date(timeIntervalSince1970: 100),
            sampleRate: 16_000
        )
        try fixture.journal.append([0.1])
        try fixture.journal.finishCapture()
        try Data("not-json".utf8).write(
            to: fixture.journal.manifestURL(for: corruptID)
        )

        try fixture.journal.beginCapture(
            id: healthyID,
            createdAt: Date(timeIntervalSince1970: 200),
            sampleRate: 16_000
        )
        try fixture.journal.append([0.2])
        try fixture.journal.finishCapture()

        let recovered = try #require(fixture.journal.recoverableCaptures().only)
        #expect(recovered.id == healthyID)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.journal.manifestURL(for: corruptID).path
        ))
        #expect(FileManager.default.fileExists(
            atPath: fixture.journal.unreadableAudioURL(for: corruptID).path
        ))
    }

    @Test
    func tornFirstFrameIsQuarantinedInsteadOfRetriedForever() throws {
        let fixture = TemporaryCaptureJournal()
        defer { fixture.remove() }
        let id = UUID()
        try fixture.journal.beginCapture(
            id: id,
            createdAt: Date(),
            sampleRate: 16_000
        )
        try fixture.journal.append([0.1, 0.2])
        try fixture.journal.finishCapture()
        let audioURL = fixture.journal.audioURL(for: id)
        var data = try Data(contentsOf: audioURL)
        data.removeLast()
        try data.write(to: audioURL)

        #expect(try fixture.journal.recoverableCaptures().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: audioURL.path))
        #expect(FileManager.default.fileExists(
            atPath: fixture.journal.unreadableAudioURL(for: id).path
        ))
    }

    @Test
    func appendFailureQuarantinesTheSessionInsteadOfCreatingAGap() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wordhand-write-failure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var writeCount = 0
        let journal = CrashSafeCaptureJournal(directoryURL: directory) {
            handle,
            data in
            writeCount += 1
            if writeCount == 2 {
                throw FixtureWriteError.failed
            }
            try handle.write(contentsOf: data)
        }
        let id = UUID()
        try journal.beginCapture(
            id: id,
            createdAt: Date(),
            sampleRate: 16_000
        )
        try journal.append([0.1])
        #expect(throws: FixtureWriteError.failed) {
            try journal.append([0.2])
        }
        #expect(throws: CrashSafeCaptureJournalError.captureNotActive) {
            try journal.append([0.3])
        }
        #expect(try journal.recoverableCaptures().isEmpty)
        #expect(FileManager.default.fileExists(
            atPath: journal.unreadableAudioURL(for: id).path
        ))
    }

    @Test
    func startupScanExcludesTheCurrentlyActiveCapture() throws {
        let fixture = TemporaryCaptureJournal()
        defer { fixture.remove() }
        let id = UUID()
        try fixture.journal.beginCapture(
            id: id,
            createdAt: Date(),
            sampleRate: 16_000
        )
        try fixture.journal.append([0.1])

        #expect(try fixture.journal.recoverableCaptures().isEmpty)
        #expect(FileManager.default.fileExists(
            atPath: fixture.journal.manifestURL(for: id).path
        ))

        try fixture.journal.finishCapture()
        #expect(try fixture.journal.recoverableCaptures().only?.id == id)
    }

    @Test
    func quarantineExpiresAfterThirtyDayCutoff() throws {
        let fixture = TemporaryCaptureJournal()
        defer { fixture.remove() }
        let id = UUID()
        try fixture.journal.beginCapture(
            id: id,
            createdAt: Date(),
            sampleRate: 16_000
        )
        try fixture.journal.append([0.1])
        try fixture.journal.finishCapture()
        try Data("bad".utf8).write(
            to: fixture.journal.manifestURL(for: id)
        )
        #expect(try fixture.journal.recoverableCaptures().isEmpty)

        let oldDate = Date(timeIntervalSince1970: 100)
        for url in [
            fixture.journal.unreadableAudioURL(for: id),
            fixture.journal.unreadableManifestURL(for: id),
        ] {
            try FileManager.default.setAttributes(
                [.modificationDate: oldDate],
                ofItemAtPath: url.path
            )
        }
        try fixture.journal.pruneQuarantine(
            olderThan: Date(timeIntervalSince1970: 200)
        )
        #expect(!FileManager.default.fileExists(
            atPath: fixture.journal.unreadableAudioURL(for: id).path
        ))
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}

private struct TemporaryCaptureJournal {
    let directory: URL
    let journal: CrashSafeCaptureJournal

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wordhand-capture-\(UUID().uuidString)")
        journal = CrashSafeCaptureJournal(directoryURL: directory)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private extension Collection {
    var only: Element? {
        count == 1 ? first : nil
    }
}

private enum FixtureWriteError: Error {
    case failed
}
