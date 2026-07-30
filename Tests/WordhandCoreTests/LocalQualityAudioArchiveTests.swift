import Foundation
import Testing
@testable import WordhandCore

@Suite
struct LocalQualityAudioArchiveTests {
    @Test
    func publicSettingsDefaultToNotRetainingAudio() {
        let settings = AppSettings()

        #expect(!settings.qualityAudioRetentionEnabled)
        #expect(settings.qualityAudioRetentionDays == 7)
    }

    @Test
    func storesOwnerOnlyWavPairedToTranscriptID() throws {
        let fixture = TemporaryQualityArchive()
        defer { fixture.remove() }
        let transcriptID = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)

        let storedURL = try fixture.archive.store(QualityAudioSample(
            transcriptID: transcriptID,
            createdAt: createdAt,
            samples: [-1, -0.5, 0, 0.5, 1],
            sampleRate: 16_000
        ))
        let url = try #require(storedURL)

        #expect(url.lastPathComponent == transcriptID.uuidString.lowercased() + ".wav")
        let data = try Data(contentsOf: url)
        #expect(String(data: data.prefix(4), encoding: .ascii) == "RIFF")
        #expect(String(data: data[8..<12], encoding: .ascii) == "WAVE")
        #expect(data.count == 54)
        let directoryMode = try posixPermissions(at: fixture.directory)
        let fileMode = try posixPermissions(at: url)
        #expect(directoryMode == 0o700)
        #expect(fileMode == 0o600)
    }

    @Test
    func prunesOnlyRecordingsOlderThanCutoff() throws {
        let fixture = TemporaryQualityArchive()
        defer { fixture.remove() }
        let oldID = UUID()
        let currentID = UUID()
        _ = try fixture.archive.store(QualityAudioSample(
            transcriptID: oldID,
            createdAt: Date(timeIntervalSince1970: 100),
            samples: [0],
            sampleRate: 16_000
        ))
        _ = try fixture.archive.store(QualityAudioSample(
            transcriptID: currentID,
            createdAt: Date(timeIntervalSince1970: 300),
            samples: [0],
            sampleRate: 16_000
        ))

        try fixture.archive.prune(olderThan: Date(timeIntervalSince1970: 200))

        #expect(!FileManager.default.fileExists(
            atPath: fixture.archive.fileURL(for: oldID).path
        ))
        #expect(FileManager.default.fileExists(
            atPath: fixture.archive.fileURL(for: currentID).path
        ))
    }

    @Test
    func deletionWinsIfAnArchiveWriteArrivesLate() throws {
        let fixture = TemporaryQualityArchive()
        defer { fixture.remove() }
        let transcriptID = UUID()
        let createdAt = Date(timeIntervalSince1970: 100)

        try fixture.archive.delete(transcriptID: transcriptID)
        let singleResult = try fixture.archive.store(QualityAudioSample(
            transcriptID: transcriptID,
            createdAt: createdAt,
            samples: [0],
            sampleRate: 16_000
        ))
        try fixture.archive.deleteAll(cutoff: Date(timeIntervalSince1970: 200))
        let clearResult = try fixture.archive.store(QualityAudioSample(
            transcriptID: UUID(),
            createdAt: createdAt,
            samples: [0],
            sampleRate: 16_000
        ))

        #expect(singleResult == nil)
        #expect(clearResult == nil)
        #expect(try fixture.archive.recordingCount() == 0)
    }

    @Test
    func storageLimitRemovesOldestRecordingsFirst() throws {
        let fixture = TemporaryQualityArchive()
        defer { fixture.remove() }
        let oldestID = UUID()
        let middleID = UUID()
        let newestID = UUID()
        for (id, timestamp) in [
            (oldestID, 100.0),
            (middleID, 200.0),
            (newestID, 300.0),
        ] {
            _ = try fixture.archive.store(QualityAudioSample(
                transcriptID: id,
                createdAt: Date(timeIntervalSince1970: timestamp),
                samples: [0],
                sampleRate: 16_000
            ))
        }

        let report = try fixture.archive.enforceMaximumBytes(92)

        #expect(report.recordingCount == 2)
        #expect(report.totalBytes == 92)
        #expect(report.removedCount == 1)
        let stored = try fixture.archive.storageReport()
        #expect(stored.recordingCount == report.recordingCount)
        #expect(stored.totalBytes == report.totalBytes)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.archive.fileURL(for: oldestID).path
        ))
        #expect(FileManager.default.fileExists(
            atPath: fixture.archive.fileURL(for: middleID).path
        ))
        #expect(FileManager.default.fileExists(
            atPath: fixture.archive.fileURL(for: newestID).path
        ))
    }

    private func posixPermissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}

private struct TemporaryQualityArchive {
    let directory: URL
    let archive: LocalQualityAudioArchive

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wordhand-quality-\(UUID().uuidString)")
        archive = LocalQualityAudioArchive(directoryURL: directory)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
