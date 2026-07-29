import Foundation

/// A platform-neutral local benchmark record for comparing transcription engines.
///
/// Audio files stay in each platform's private application container. This
/// schema intentionally stores only the relative file name, never a remote URL.
public struct TranscriptionObservation: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: UUID
    public let createdAt: Date
    public let engineID: String
    public let localeIdentifier: String
    public let rawText: String
    public let processedText: String
    public let audioFileName: String
    public let audioDuration: TimeInterval
    public let transcriptionDuration: TimeInterval
    public let thermalStateBefore: String?
    public let thermalStateAfter: String?
    public let peakResidentMemoryBytes: UInt64?

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        id: UUID = UUID(),
        createdAt: Date = Date(),
        engineID: String,
        localeIdentifier: String,
        rawText: String,
        processedText: String,
        audioFileName: String,
        audioDuration: TimeInterval,
        transcriptionDuration: TimeInterval,
        thermalStateBefore: String? = nil,
        thermalStateAfter: String? = nil,
        peakResidentMemoryBytes: UInt64? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.createdAt = createdAt
        self.engineID = engineID
        self.localeIdentifier = localeIdentifier
        self.rawText = rawText
        self.processedText = processedText
        self.audioFileName = audioFileName
        self.audioDuration = audioDuration
        self.transcriptionDuration = transcriptionDuration
        self.thermalStateBefore = thermalStateBefore
        self.thermalStateAfter = thermalStateAfter
        self.peakResidentMemoryBytes = peakResidentMemoryBytes
    }
}
