import Foundation

public struct TranscriptionQualityScore: Codable, Equatable, Sendable {
    public let wordEditDistance: Int
    public let referenceWordCount: Int
    public let characterEditDistance: Int
    public let referenceCharacterCount: Int
    public let isNormalizedExactMatch: Bool

    public var wordErrorRate: Double {
        Self.rate(errors: wordEditDistance, referenceUnits: referenceWordCount)
    }

    public var characterErrorRate: Double {
        Self.rate(
            errors: characterEditDistance,
            referenceUnits: referenceCharacterCount
        )
    }

    private static func rate(errors: Int, referenceUnits: Int) -> Double {
        guard referenceUnits > 0 else { return 0 }
        return Double(errors) / Double(referenceUnits)
    }
}

public struct TranscriptionQualityAggregate: Codable, Equatable, Sendable {
    public let sampleCount: Int
    public let exactMatchCount: Int
    public let wordEditDistance: Int
    public let referenceWordCount: Int
    public let characterEditDistance: Int
    public let referenceCharacterCount: Int

    public init(scores: [TranscriptionQualityScore]) {
        sampleCount = scores.count
        exactMatchCount = scores.count(where: \.isNormalizedExactMatch)
        wordEditDistance = scores.reduce(0) { $0 + $1.wordEditDistance }
        referenceWordCount = scores.reduce(0) { $0 + $1.referenceWordCount }
        characterEditDistance = scores.reduce(0) {
            $0 + $1.characterEditDistance
        }
        referenceCharacterCount = scores.reduce(0) {
            $0 + $1.referenceCharacterCount
        }
    }

    public var wordErrorRate: Double {
        guard referenceWordCount > 0 else { return 0 }
        return Double(wordEditDistance) / Double(referenceWordCount)
    }

    public var characterErrorRate: Double {
        guard referenceCharacterCount > 0 else { return 0 }
        return Double(characterEditDistance) / Double(referenceCharacterCount)
    }
}

public enum TranscriptionQualityMetrics {
    public static func score(
        reference: String,
        hypothesis: String
    ) -> TranscriptionQualityScore? {
        let referenceWords = normalizedWords(reference)
        guard !referenceWords.isEmpty else { return nil }
        let hypothesisWords = normalizedWords(hypothesis)
        let referenceCharacters = Array(referenceWords.joined())
        let hypothesisCharacters = Array(hypothesisWords.joined())

        return TranscriptionQualityScore(
            wordEditDistance: editDistance(
                referenceWords,
                hypothesisWords
            ),
            referenceWordCount: referenceWords.count,
            characterEditDistance: editDistance(
                referenceCharacters,
                hypothesisCharacters
            ),
            referenceCharacterCount: referenceCharacters.count,
            isNormalizedExactMatch: referenceWords == hypothesisWords
        )
    }

    private static func normalizedWords(_ text: String) -> [String] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return wordExpression.matches(in: text, range: range).compactMap {
            match in
            guard let range = Range(match.range, in: text) else { return nil }
            return normalizeToken(String(text[range]))
        }
    }

    private static func normalizeToken(_ token: String) -> String {
        token
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‐", with: "-")
            .replacingOccurrences(of: "‑", with: "-")
    }

    private static func editDistance<Element: Equatable>(
        _ reference: [Element],
        _ hypothesis: [Element]
    ) -> Int {
        if reference.isEmpty { return hypothesis.count }
        if hypothesis.isEmpty { return reference.count }

        var previous = Array(0...hypothesis.count)
        for (referenceOffset, referenceUnit) in reference.enumerated() {
            var current = Array(repeating: 0, count: hypothesis.count + 1)
            current[0] = referenceOffset + 1
            for (hypothesisOffset, hypothesisUnit) in hypothesis.enumerated() {
                let substitutionCost = referenceUnit == hypothesisUnit ? 0 : 1
                current[hypothesisOffset + 1] = min(
                    previous[hypothesisOffset + 1] + 1,
                    current[hypothesisOffset] + 1,
                    previous[hypothesisOffset] + substitutionCost
                )
            }
            previous = current
        }
        return previous[hypothesis.count]
    }

    private static let wordExpression = try! NSRegularExpression(
        pattern: #"[\p{L}\p{N}]+(?:['’‐‑-][\p{L}\p{N}]+)*"#
    )
}
