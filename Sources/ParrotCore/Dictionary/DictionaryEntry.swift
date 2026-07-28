import Foundation

public struct DictionaryEntry: Codable, Equatable, Identifiable, Sendable {
    public enum MatchMode: String, Codable, Sendable {
        case word
        case phrase
    }

    public let id: UUID
    public var spokenForm: String
    public var replacement: String
    public var matchMode: MatchMode
    public var isCaseSensitive: Bool
    public var isEnabled: Bool
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        spokenForm: String,
        replacement: String,
        matchMode: MatchMode = .phrase,
        isCaseSensitive: Bool = false,
        isEnabled: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.spokenForm = spokenForm
        self.replacement = replacement
        self.matchMode = matchMode
        self.isCaseSensitive = isCaseSensitive
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
