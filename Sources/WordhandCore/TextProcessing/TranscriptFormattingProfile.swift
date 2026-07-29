import Foundation

public enum TranscriptFormattingProfile: String, Codable, CaseIterable, Sendable {
    case casual
    case formatted
    case professional
    case aiCommunication

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let storedValue = try container.decode(String.self)
        switch storedValue {
        case Self.casual.rawValue:
            self = .casual
        case Self.formatted.rawValue, "automatic", "polished":
            self = .formatted
        case Self.professional.rawValue:
            self = .professional
        case Self.aiCommunication.rawValue, "aiPrompt":
            self = .aiCommunication
        case "verbatim":
            self = .casual
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown writing style: \(storedValue)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
