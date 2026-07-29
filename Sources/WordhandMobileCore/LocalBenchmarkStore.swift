import Foundation
import WordhandCore

public struct LocalBenchmarkStore: Sendable {
    public static let observationsDirectoryName = "Observations"
    public static let audioDirectoryName = "Audio"

    public let rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    public var audioDirectory: URL {
        rootDirectory.appendingPathComponent(Self.audioDirectoryName, isDirectory: true)
    }

    public func audioFileURL(id: UUID) throws -> URL {
        try FileManager.default.createDirectory(
            at: audioDirectory,
            withIntermediateDirectories: true
        )
        return audioDirectory.appendingPathComponent("\(id.uuidString).caf")
    }

    public func save(_ observation: TranscriptionObservation) throws {
        let directory = rootDirectory.appendingPathComponent(
            Self.observationsDirectoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = directory.appendingPathComponent("\(observation.id.uuidString).json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(observation).write(
            to: url,
            options: [.atomic, .completeFileProtection]
        )
    }

    public func loadAll() throws -> [TranscriptionObservation] {
        let directory = rootDirectory.appendingPathComponent(
            Self.observationsDirectoryName,
            isDirectory: true
        )
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "json" }
        .map { try decoder.decode(TranscriptionObservation.self, from: Data(contentsOf: $0)) }
        .sorted { $0.createdAt > $1.createdAt }
    }
}
