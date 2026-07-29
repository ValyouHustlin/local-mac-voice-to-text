import Foundation

public struct MobileTranscriptDraft: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: UUID
    public let createdAt: Date
    public let text: String

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        id: UUID = UUID(),
        createdAt: Date = Date(),
        text: String
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.createdAt = createdAt
        self.text = text
    }
}

public enum MobileTranscriptDraftError: Error, Equatable {
    case unsupportedSchema(Int)
    case emptyText
}

extension MobileTranscriptDraft {
    func validated() throws -> Self {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw MobileTranscriptDraftError.unsupportedSchema(schemaVersion)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MobileTranscriptDraftError.emptyText
        }
        return self
    }
}
