import Foundation

public struct RecoveredAudioCapture: Equatable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let sampleRate: Int
    public let samples: [Float]

    public init(id: UUID, createdAt: Date, sampleRate: Int, samples: [Float]) {
        self.id = id
        self.createdAt = createdAt
        self.sampleRate = sampleRate
        self.samples = samples
    }
}

public enum CrashSafeCaptureJournalError: Error, Equatable {
    case captureAlreadyActive
    case captureNotActive
    case invalidSampleRate(Int)
    case corruptManifest
}

/// An append-only local audio journal. Each converted microphone chunk is
/// framed independently so restart recovery can ignore a torn final write
/// without losing any earlier complete chunk.
public final class CrashSafeCaptureJournal: @unchecked Sendable {
    public let directoryURL: URL

    private struct Manifest: Codable {
        let version: Int
        let id: UUID
        let createdAt: Date
        let sampleRate: Int
    }

    private struct ActiveCapture {
        let id: UUID
        let handle: FileHandle
        var sequence: UInt64
    }

    private static let manifestVersion = 1
    private static let frameMagic: UInt32 = 0x5748_4331 // "WHC1"
    private static let frameHeaderBytes = 4 + 8 + 4 + 8

    private let fileManager: FileManager
    private let writeFrame: (FileHandle, Data) throws -> Void
    private let lock = NSLock()
    private var active: ActiveCapture?

    public init(
        directoryURL: URL = CrashSafeCaptureJournal.defaultDirectoryURL(),
        fileManager: FileManager = .default
    ) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
        self.writeFrame = { handle, data in
            try handle.write(contentsOf: data)
        }
    }

    init(
        directoryURL: URL,
        fileManager: FileManager = .default,
        writeFrame: @escaping (FileHandle, Data) throws -> Void
    ) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
        self.writeFrame = writeFrame
    }

    deinit {
        try? active?.handle.close()
    }

    public static func defaultDirectoryURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        ApplicationData.defaultDirectory(homeDirectory: homeDirectory)
            .appendingPathComponent("Pending Captures", isDirectory: true)
    }

    public func beginCapture(
        id: UUID,
        createdAt: Date,
        sampleRate: Int
    ) throws {
        try lock.withLock {
            guard active == nil else {
                throw CrashSafeCaptureJournalError.captureAlreadyActive
            }
            guard sampleRate > 0 else {
                throw CrashSafeCaptureJournalError.invalidSampleRate(sampleRate)
            }
            try prepareDirectory()
            let manifest = Manifest(
                version: Self.manifestVersion,
                id: id,
                createdAt: createdAt,
                sampleRate: sampleRate
            )
            let manifestData = try JSONEncoder().encode(manifest)
            let manifestURL = self.manifestURL(for: id)
            try manifestData.write(to: manifestURL, options: [.atomic])
            try hardenFile(at: manifestURL)

            let audioURL = self.audioURL(for: id)
            guard fileManager.createFile(
                atPath: audioURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else {
                try? fileManager.removeItem(at: manifestURL)
                throw CocoaError(.fileWriteUnknown)
            }
            let handle = try FileHandle(forWritingTo: audioURL)
            active = ActiveCapture(id: id, handle: handle, sequence: 0)
        }
    }

    /// Returns only after the complete frame has been handed to the local
    /// filesystem. Process termination cannot invalidate earlier frames.
    public func append(_ samples: [Float]) throws {
        guard !samples.isEmpty else { return }
        try lock.withLock {
            guard var capture = active else {
                throw CrashSafeCaptureJournalError.captureNotActive
            }
            let payload = Self.payloadData(samples)
            var frame = Data(capacity: Self.frameHeaderBytes + payload.count)
            frame.append(littleEndian: Self.frameMagic)
            frame.append(littleEndian: capture.sequence)
            frame.append(littleEndian: UInt32(samples.count))
            frame.append(littleEndian: Self.checksum(payload))
            frame.append(payload)
            do {
                try writeFrame(capture.handle, frame)
            } catch {
                try? capture.handle.close()
                active = nil
                quarantine(manifestURL: manifestURL(for: capture.id))
                throw error
            }
            capture.sequence += 1
            active = capture
        }
    }

    /// Flushes the clean-stop boundary but deliberately leaves the journal
    /// recoverable until the matching transcript is committed to History.
    public func finishCapture() throws {
        try lock.withLock {
            guard let capture = active else { return }
            try capture.handle.synchronize()
            try capture.handle.close()
            active = nil
        }
    }

    public func discard(id: UUID) throws {
        try lock.withLock {
            if let capture = active, capture.id == id {
                try? capture.handle.close()
                active = nil
            }
            try removeIfPresent(audioURL(for: id))
            try removeIfPresent(manifestURL(for: id))
            try removeIfPresent(unreadableAudioURL(for: id))
            try removeIfPresent(unreadableManifestURL(for: id))
        }
    }

    public func recoverableCaptures() throws -> [RecoveredAudioCapture] {
        try lock.withLock {
            guard fileManager.fileExists(atPath: directoryURL.path) else {
                return []
            }
            let urls = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            let manifestURLs = urls.filter {
                $0.lastPathComponent.hasSuffix(".capture.json")
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            let activeID = active?.id

            return manifestURLs.compactMap { url in
                do {
                    let manifest = try JSONDecoder().decode(
                        Manifest.self,
                        from: Data(contentsOf: url)
                    )
                    guard manifest.version == Self.manifestVersion,
                          manifest.sampleRate > 0 else {
                        quarantine(manifestURL: url)
                        return nil
                    }
                    guard manifest.id != activeID else { return nil }
                    let samples = try recoverSamples(
                        from: audioURL(for: manifest.id)
                    )
                    guard !samples.isEmpty else {
                        quarantine(manifestURL: url)
                        return nil
                    }
                    return RecoveredAudioCapture(
                        id: manifest.id,
                        createdAt: manifest.createdAt,
                        sampleRate: manifest.sampleRate,
                        samples: samples
                    )
                } catch {
                    quarantine(manifestURL: url)
                    return nil
                }
            }.sorted { $0.createdAt < $1.createdAt }
        }
    }

    public func pruneQuarantine(olderThan cutoff: Date) throws {
        try lock.withLock {
            guard fileManager.fileExists(atPath: directoryURL.path) else {
                return
            }
            let urls = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            for url in urls where url.lastPathComponent.contains(".unreadable.") {
                let values = try url.resourceValues(
                    forKeys: [.contentModificationDateKey]
                )
                guard let modifiedAt = values.contentModificationDate,
                      modifiedAt < cutoff else {
                    continue
                }
                try fileManager.removeItem(at: url)
            }
        }
    }

    public func audioURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent(
            id.uuidString.lowercased() + ".capture"
        )
    }

    public func manifestURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent(
            id.uuidString.lowercased() + ".capture.json"
        )
    }

    public func unreadableAudioURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent(
            id.uuidString.lowercased() + ".unreadable.capture"
        )
    }

    public func unreadableManifestURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent(
            id.uuidString.lowercased() + ".unreadable.json"
        )
    }

    private func recoverSamples(from url: URL) throws -> [Float] {
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        var offset = 0
        var expectedSequence: UInt64 = 0
        var recovered: [Float] = []

        while offset + Self.frameHeaderBytes <= data.count {
            guard let magic: UInt32 = data.littleEndian(at: offset),
                  magic == Self.frameMagic,
                  let sequence: UInt64 = data.littleEndian(at: offset + 4),
                  sequence == expectedSequence,
                  let sampleCount: UInt32 = data.littleEndian(at: offset + 12),
                  let checksum: UInt64 = data.littleEndian(at: offset + 16)
            else {
                break
            }
            let payloadStart = offset + Self.frameHeaderBytes
            let payloadBytes = Int(sampleCount) * MemoryLayout<UInt32>.size
            guard payloadBytes / MemoryLayout<UInt32>.size == Int(sampleCount),
                  payloadStart + payloadBytes <= data.count
            else {
                break
            }
            let payload = data[payloadStart..<(payloadStart + payloadBytes)]
            guard Self.checksum(payload) == checksum else { break }
            recovered.reserveCapacity(recovered.count + Int(sampleCount))
            var sampleOffset = payload.startIndex
            for _ in 0..<sampleCount {
                let bits = payload[sampleOffset..<(sampleOffset + 4)]
                    .withUnsafeBytes { pointer in
                        UInt32(littleEndian: pointer.loadUnaligned(as: UInt32.self))
                    }
                recovered.append(Float(bitPattern: bits))
                sampleOffset += 4
            }
            expectedSequence += 1
            offset = payloadStart + payloadBytes
        }
        return recovered
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

    private func hardenFile(at url: URL) throws {
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private func removeIfPresent(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    private func quarantine(manifestURL: URL) {
        let suffix = ".capture.json"
        guard manifestURL.lastPathComponent.hasSuffix(suffix) else { return }
        let baseName = String(manifestURL.lastPathComponent.dropLast(suffix.count))
        let audioURL = directoryURL.appendingPathComponent(
            baseName + ".capture"
        )
        let unreadableManifest = directoryURL.appendingPathComponent(
            baseName + ".unreadable.json"
        )
        let unreadableAudio = directoryURL.appendingPathComponent(
            baseName + ".unreadable.capture"
        )
        if fileManager.fileExists(atPath: manifestURL.path),
           !fileManager.fileExists(atPath: unreadableManifest.path)
        {
            try? fileManager.moveItem(at: manifestURL, to: unreadableManifest)
        }
        if fileManager.fileExists(atPath: audioURL.path),
           !fileManager.fileExists(atPath: unreadableAudio.path)
        {
            try? fileManager.moveItem(at: audioURL, to: unreadableAudio)
        }
    }

    private static func payloadData(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 4)
        for sample in samples {
            data.append(littleEndian: sample.bitPattern)
        }
        return data
    }

    private static func checksum<T: DataProtocol>(_ data: T) -> UInt64 {
        data.reduce(UInt64(0xcbf2_9ce4_8422_2325)) { partial, byte in
            (partial ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
    }
}

private extension Data {
    mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        var encoded = value.littleEndian
        Swift.withUnsafeBytes(of: &encoded) { append(contentsOf: $0) }
    }

    func littleEndian<T: FixedWidthInteger>(at offset: Int) -> T? {
        guard offset >= 0, offset + MemoryLayout<T>.size <= count else {
            return nil
        }
        return self[offset..<(offset + MemoryLayout<T>.size)]
            .withUnsafeBytes { pointer in
                T(littleEndian: pointer.loadUnaligned(as: T.self))
            }
    }
}
