import Foundation

public struct QualityAudioSample: Equatable, Sendable {
    public let transcriptID: UUID
    public let createdAt: Date
    public let samples: [Float]
    public let sampleRate: Int

    public init(
        transcriptID: UUID,
        createdAt: Date,
        samples: [Float],
        sampleRate: Int
    ) {
        self.transcriptID = transcriptID
        self.createdAt = createdAt
        self.samples = samples
        self.sampleRate = sampleRate
    }
}

public enum QualityAudioArchiveError: Error, Equatable {
    case invalidSampleRate(Int)
    case recordingTooLarge
}

/// A private, local corpus for evaluating transcription mistakes. Files are
/// keyed to transcript-history UUIDs so audio and text can be compared without
/// duplicating transcript content into another database.
public final class LocalQualityAudioArchive: @unchecked Sendable {
    public let directoryURL: URL

    private let fileManager: FileManager
    private let lock = NSLock()
    private var deletedTranscriptIDs = Set<UUID>()
    private var deleteAllCutoff: Date?

    public init(
        directoryURL: URL = LocalQualityAudioArchive.defaultDirectoryURL(),
        fileManager: FileManager = .default
    ) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
    }

    public static func defaultDirectoryURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        ApplicationData.defaultDirectory(homeDirectory: homeDirectory)
            .appendingPathComponent("Quality Recordings", isDirectory: true)
    }

    @discardableResult
    public func store(_ sample: QualityAudioSample) throws -> URL? {
        try lock.withLock {
            guard !deletedTranscriptIDs.contains(sample.transcriptID),
                  deleteAllCutoff.map({ sample.createdAt > $0 }) ?? true
            else {
                return nil
            }
            guard sample.sampleRate > 0 else {
                throw QualityAudioArchiveError.invalidSampleRate(sample.sampleRate)
            }
            guard sample.samples.count <= (Int(UInt32.max) - 44) / 2 else {
                throw QualityAudioArchiveError.recordingTooLarge
            }

            try prepareDirectory()
            let url = fileURL(for: sample.transcriptID)
            let data = Self.wavData(
                samples: sample.samples,
                sampleRate: sample.sampleRate
            )
            try data.write(to: url, options: [.atomic])
            try fileManager.setAttributes(
                [
                    .posixPermissions: 0o600,
                    .modificationDate: sample.createdAt,
                ],
                ofItemAtPath: url.path
            )
            return url
        }
    }

    public func ensureDirectory() throws {
        try lock.withLock {
            try prepareDirectory()
        }
    }

    public func prune(olderThan cutoff: Date) throws {
        try lock.withLock {
            guard fileManager.fileExists(atPath: directoryURL.path) else { return }
            for url in try recordingURLs() {
                let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
                guard let modifiedAt = values.contentModificationDate,
                      modifiedAt < cutoff
                else {
                    continue
                }
                try fileManager.removeItem(at: url)
            }
        }
    }

    public func delete(transcriptID: UUID) throws {
        try lock.withLock {
            deletedTranscriptIDs.insert(transcriptID)
            let url = fileURL(for: transcriptID)
            guard fileManager.fileExists(atPath: url.path) else { return }
            try fileManager.removeItem(at: url)
        }
    }

    public func deleteAll(cutoff: Date = Date()) throws {
        try lock.withLock {
            deletedTranscriptIDs.removeAll(keepingCapacity: true)
            deleteAllCutoff = cutoff
            guard fileManager.fileExists(atPath: directoryURL.path) else { return }
            for url in try recordingURLs() {
                try fileManager.removeItem(at: url)
            }
        }
    }

    public func recordingCount() throws -> Int {
        try lock.withLock {
            guard fileManager.fileExists(atPath: directoryURL.path) else { return 0 }
            return try recordingURLs().count
        }
    }

    public func fileURL(for transcriptID: UUID) -> URL {
        directoryURL.appendingPathComponent(
            transcriptID.uuidString.lowercased() + ".wav"
        )
    }

    private func prepareDirectory() throws {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )
    }

    private func recordingURLs() throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension.lowercased() == "wav" }
    }

    private static func wavData(samples: [Float], sampleRate: Int) -> Data {
        let dataSize = samples.count * 2
        var data = Data(capacity: 44 + dataSize)
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(littleEndian: UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.append(littleEndian: UInt32(16))
        data.append(littleEndian: UInt16(1))
        data.append(littleEndian: UInt16(1))
        data.append(littleEndian: UInt32(sampleRate))
        data.append(littleEndian: UInt32(sampleRate * 2))
        data.append(littleEndian: UInt16(2))
        data.append(littleEndian: UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        data.append(littleEndian: UInt32(dataSize))
        for value in samples {
            let clamped = max(-1, min(1, value))
            data.append(littleEndian: UInt16(bitPattern: Int16(clamped * 32_767)))
        }
        return data
    }
}

private extension Data {
    mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        var encoded = value.littleEndian
        Swift.withUnsafeBytes(of: &encoded) { bytes in
            append(contentsOf: bytes)
        }
    }
}
