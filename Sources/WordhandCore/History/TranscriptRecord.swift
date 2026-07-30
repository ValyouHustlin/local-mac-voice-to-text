import Foundation

public struct TranscriptTarget: Equatable, Sendable {
    public var bundleIdentifier: String?
    public var applicationName: String?

    public init(bundleIdentifier: String? = nil, applicationName: String? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
    }

    public static let unknown = TranscriptTarget()
}

public enum TranscriptInsertionStatus: Equatable, Sendable {
    case pendingInsertion
    case inserted
    case insertionFailed(String)
}

public struct TranscriptRecord: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let rawText: String
    public let text: String
    public let modelID: String
    public let language: String?
    public let audioDuration: TimeInterval
    public let transcriptionDuration: TimeInterval
    public let insertionMode: InsertionMode
    public let target: TranscriptTarget
    public let status: TranscriptInsertionStatus
    public let referenceText: String?
    public let tailRecoveryOutcome: TailRecoveryOutcome

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        rawText: String,
        text: String,
        modelID: String,
        language: String? = nil,
        audioDuration: TimeInterval,
        transcriptionDuration: TimeInterval,
        insertionMode: InsertionMode,
        target: TranscriptTarget = .unknown,
        status: TranscriptInsertionStatus = .pendingInsertion,
        referenceText: String? = nil,
        tailRecoveryOutcome: TailRecoveryOutcome = .notAudited
    ) {
        self.id = id
        self.createdAt = createdAt
        self.rawText = rawText
        self.text = text
        self.modelID = modelID
        self.language = language
        self.audioDuration = audioDuration
        self.transcriptionDuration = transcriptionDuration
        self.insertionMode = insertionMode
        self.target = target
        self.status = status
        self.referenceText = referenceText
        self.tailRecoveryOutcome = tailRecoveryOutcome
    }
}

public protocol TranscriptRecording: Sendable {
    func save(_ record: TranscriptRecord) throws
    func updateStatus(id: UUID, status: TranscriptInsertionStatus) throws
}
