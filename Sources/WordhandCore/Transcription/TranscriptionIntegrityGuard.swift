import Foundation

public enum TranscriptionIntegrityIssue: Hashable, Sendable {
    case leadingConditioningArtifact
    case activeAudioAfterUnpunctuatedEnding
}

public enum TranscriptionIntegrityGuard {
    public static func issues(
        in text: String,
        conditionedTerms: [String],
        audio: [Float],
        sampleRate: Int
    ) -> Set<TranscriptionIntegrityIssue> {
        var result = Set<TranscriptionIntegrityIssue>()
        if hasLeadingConditioningArtifact(
            text,
            conditionedTerms: conditionedTerms
        ) {
            result.insert(.leadingConditioningArtifact)
        }
        if !hasTerminalPunctuation(text),
           hasActiveTail(audio, sampleRate: sampleRate)
        {
            result.insert(.activeAudioAfterUnpunctuatedEnding)
        }
        return result
    }

    public static func select(
        primary: String,
        retry: String,
        issues: Set<TranscriptionIntegrityIssue>,
        conditionedTerms: [String]
    ) -> String {
        let primaryWordCount = wordCount(primary)
        let retryWordCount = wordCount(retry)

        if issues.contains(.leadingConditioningArtifact),
           !hasLeadingConditioningArtifact(
               retry,
               conditionedTerms: conditionedTerms
           ),
           retryWordCount >= max(1, primaryWordCount - 4),
           lexicallyAligned(
               reference: bodyAfterLeadingDelimiter(primary) ?? primary,
               candidate: retry
           )
        {
            return retry
        }

        if issues.contains(.activeAudioAfterUnpunctuatedEnding) {
            let materiallyLonger = retryWordCount >= primaryWordCount + 2
            let equallyComplete =
                hasTerminalPunctuation(retry)
                && retryWordCount >= primaryWordCount
            if (materiallyLonger || equallyComplete),
               lexicallyAligned(reference: primary, candidate: retry)
            {
                return retry
            }
        }

        return primary
    }

    private static func hasLeadingConditioningArtifact(
        _ text: String,
        conditionedTerms: [String]
    ) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        guard let boundary = leadingDelimiterRange(in: trimmed)?.lowerBound else {
            return false
        }

        let prefix = String(trimmed[..<boundary])
        let normalizedPrefix = normalizedIdentifier(prefix)
        guard normalizedPrefix.count >= 6 else { return false }

        return conditionedTerms.contains { term in
            let normalizedTerm = normalizedIdentifier(term)
            guard normalizedTerm.count > normalizedPrefix.count else {
                return false
            }
            let minimumPrefixLength = max(6, normalizedTerm.count / 2)
            return normalizedPrefix.count >= minimumPrefixLength
                && normalizedTerm.hasPrefix(normalizedPrefix)
        }
    }

    private static func hasTerminalPunctuation(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return true }
        return ".!?…)]}\"”’'".contains(last)
    }

    private static func hasActiveTail(
        _ audio: [Float],
        sampleRate: Int
    ) -> Bool {
        guard sampleRate > 0, !audio.isEmpty else { return false }
        let tailCount = min(audio.count, sampleRate * 2)
        guard tailCount > 0 else { return false }
        let tail = audio.suffix(tailCount)
        var sumOfSquares: Double = 0
        var peak: Float = 0
        for sample in tail {
            sumOfSquares += Double(sample * sample)
            peak = max(peak, abs(sample))
        }
        let rms = sqrt(sumOfSquares / Double(tailCount))
        return rms >= 0.003 || peak >= 0.02
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    private static func bodyAfterLeadingDelimiter(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = leadingDelimiterRange(in: trimmed) else { return nil }
        return String(trimmed[range.upperBound...])
    }

    private static func leadingDelimiterRange(
        in text: String
    ) -> Range<String.Index>? {
        ["- ", "— ", ": "]
            .compactMap { text.range(of: $0) }
            .min { $0.lowerBound < $1.lowerBound }
    }

    private static func lexicallyAligned(
        reference: String,
        candidate: String
    ) -> Bool {
        let referenceWords = normalizedWords(reference)
        let candidateWords = normalizedWords(candidate)
        guard !referenceWords.isEmpty, !candidateWords.isEmpty else {
            return false
        }

        var candidateCounts = Dictionary(
            candidateWords.map { ($0, 1) },
            uniquingKeysWith: +
        )
        let sharedCount = referenceWords.reduce(into: 0) { count, word in
            guard let available = candidateCounts[word], available > 0 else {
                return
            }
            count += 1
            candidateCounts[word] = available - 1
        }
        return Double(sharedCount) / Double(referenceWords.count) >= 0.7
    }

    private static func normalizedWords(_ value: String) -> [String] {
        value
            .split(whereSeparator: \.isWhitespace)
            .map { normalizedIdentifier(String($0)) }
            .filter { !$0.isEmpty }
    }

    private static func normalizedIdentifier(_ value: String) -> String {
        value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .unicodeScalars
            .filter(CharacterSet.alphanumerics.contains)
            .map(String.init)
            .joined()
    }
}
