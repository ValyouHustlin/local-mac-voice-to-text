import Foundation

public struct PronunciationAliasSuggestion:
    Equatable,
    Identifiable,
    Sendable
{
    public let id: String
    public let heardForm: String
    public let canonicalTerm: String
    public let supportingTranscriptIDs: [UUID]
    public let latestSupportingTranscriptID: UUID

    public var supportCount: Int {
        supportingTranscriptIDs.count
    }

    public init(
        id: String,
        heardForm: String,
        canonicalTerm: String,
        supportingTranscriptIDs: [UUID],
        latestSupportingTranscriptID: UUID
    ) {
        self.id = id
        self.heardForm = heardForm
        self.canonicalTerm = canonicalTerm
        self.supportingTranscriptIDs = supportingTranscriptIDs
        self.latestSupportingTranscriptID = latestSupportingTranscriptID
    }
}

/// Finds repeated, explicit heard-form to canonical-form evidence. It never
/// mutates History or Dictionary and does not claim that the alias helps
/// decoding; retained-audio causal replay is a separate promotion gate.
public enum PronunciationAliasSuggestionOracle {
    private static let minimumSupport = 2
    private static let maximumChangedTokens = 4
    private static let protectedWords: Set<String> = [
        "can", "can't", "cannot", "could", "couldn't", "do", "don't",
        "must", "mustn't", "never", "no", "not", "should", "shouldn't",
        "will", "won't", "would", "wouldn't",
    ]

    public static func suggestions(
        records: [TranscriptRecord],
        retainedRecordingIDs: Set<UUID>,
        existingEntries: [DictionaryEntry]
    ) -> [PronunciationAliasSuggestion] {
        let canonicalTerms = existingEntries.compactMap {
            entry -> CanonicalTerm? in
            let spoken = normalizedPhrase(entry.spokenForm)
            let replacement = normalizedPhrase(entry.replacement)
            guard entry.isEnabled, spoken == replacement else { return nil }
            let termTokens = tokens(entry.replacement)
            guard !termTokens.isEmpty else { return nil }
            return CanonicalTerm(
                value: entry.replacement,
                key: replacement,
                tokens: termTokens
            )
        }
        let existingSpokenForms = Set(existingEntries.compactMap {
            $0.isEnabled ? normalizedPhrase($0.spokenForm) : nil
        })
        let uniqueRecords = Dictionary(grouping: records, by: \.id).compactMap {
            _, duplicates in duplicates.max {
                if $0.createdAt != $1.createdAt {
                    return $0.createdAt < $1.createdAt
                }
                return $0.id.uuidString < $1.id.uuidString
            }
        }
        let evidence = uniqueRecords.compactMap {
            makeEvidence(
                $0,
                retained: retainedRecordingIDs.contains($0.id),
                canonicalTerms: canonicalTerms
            )
        }
        let canonicalBySource = Dictionary(grouping: evidence, by: \.heardKey)
            .mapValues { Set($0.map(\.canonicalKey)) }

        return Dictionary(grouping: evidence) {
            "\($0.heardKey)|\($0.canonicalKey)"
        }.compactMap { key, group -> (PronunciationAliasSuggestion, Date)? in
            let supported = group.sorted {
                if $0.createdAt != $1.createdAt {
                    return $0.createdAt < $1.createdAt
                }
                return $0.recordID.uuidString < $1.recordID.uuidString
            }
            guard supported.count >= minimumSupport,
                  let latest = supported.last,
                  !existingSpokenForms.contains(latest.heardKey),
                  canonicalBySource[latest.heardKey]?.count == 1
            else {
                return nil
            }
            return (
                PronunciationAliasSuggestion(
                    id: "v1|\(key)",
                    heardForm: latest.heardForm,
                    canonicalTerm: latest.canonicalTerm,
                    supportingTranscriptIDs: supported.map(\.recordID),
                    latestSupportingTranscriptID: latest.recordID
                ),
                latest.createdAt
            )
        }.sorted {
            if $0.0.supportCount != $1.0.supportCount {
                return $0.0.supportCount > $1.0.supportCount
            }
            if $0.1 != $1.1 {
                return $0.1 > $1.1
            }
            return $0.0.id < $1.0.id
        }.map(\.0)
    }

    private static func makeEvidence(
        _ record: TranscriptRecord,
        retained: Bool,
        canonicalTerms: [CanonicalTerm]
    ) -> Evidence? {
        guard retained,
              let reference = record.referenceText?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !reference.isEmpty
        else {
            return nil
        }
        let heardTokens = tokens(record.text)
        let canonicalTokens = tokens(reference)
        guard !heardTokens.isEmpty, !canonicalTokens.isEmpty else { return nil }

        var prefix = 0
        while prefix < min(heardTokens.count, canonicalTokens.count),
              heardTokens[prefix].normalized == canonicalTokens[prefix].normalized
        {
            prefix += 1
        }
        var suffix = 0
        while suffix < heardTokens.count - prefix,
              suffix < canonicalTokens.count - prefix,
              heardTokens[heardTokens.count - suffix - 1].normalized
                == canonicalTokens[canonicalTokens.count - suffix - 1].normalized
        {
            suffix += 1
        }
        let heardChangeEnd = heardTokens.count - suffix
        let canonicalChangeEnd = canonicalTokens.count - suffix
        let matchingCanonicalTerms = canonicalTerms.compactMap {
            term -> (CanonicalTerm, Range<Int>)? in
            let termKeys = term.tokens.map(\.normalized)
            guard termKeys.count <= canonicalTokens.count else { return nil }
            for start in 0...(canonicalTokens.count - termKeys.count) {
                let end = start + termKeys.count
                guard start <= prefix, end >= canonicalChangeEnd else {
                    continue
                }
                if Array(canonicalTokens[start..<end].map(\.normalized)) == termKeys {
                    return (term, start..<end)
                }
            }
            return nil
        }
        guard matchingCanonicalTerms.count == 1,
              let match = matchingCanonicalTerms.first
        else {
            return nil
        }
        let trailingContext = match.1.upperBound - canonicalChangeEnd
        let heardEnd = heardChangeEnd + trailingContext
        guard match.1.lowerBound <= prefix,
              heardEnd <= heardTokens.count
        else {
            return nil
        }
        let heardChange = Array(heardTokens[match.1.lowerBound..<heardEnd])
        let canonicalChange = match.0.tokens
        guard (1...maximumChangedTokens).contains(heardChange.count),
              (1...maximumChangedTokens).contains(canonicalChange.count)
        else {
            return nil
        }
        let heardKey = heardChange.map(\.normalized).joined(separator: " ")
        let canonicalKey = match.0.key
        let all = heardChange.map(\.normalized) + canonicalChange.map(\.normalized)
        guard heardKey != canonicalKey,
              protectedWords.isDisjoint(with: all),
              !all.contains(where: { $0.contains(where: \.isNumber) }),
              pronunciationPlausible(
                  heard: heardChange,
                  canonical: canonicalChange,
                  canonicalTerm: match.0.value
              ),
              contains(heardChange.map(\.normalized), in: record.rawText)
        else {
            return nil
        }
        return Evidence(
            recordID: record.id,
            createdAt: record.createdAt,
            heardKey: heardKey,
            canonicalKey: canonicalKey,
            heardForm: heardChange.map(\.value).joined(separator: " "),
            canonicalTerm: match.0.value
        )
    }

    /// This intentionally recognizes only close split/merge spellings. A plain
    /// word-for-word correction could be a semantic edit, so it cannot become
    /// a global pronunciation alias without a future explicit heard-as signal.
    private static func pronunciationPlausible(
        heard: [Token],
        canonical: [Token],
        canonicalTerm: String
    ) -> Bool {
        guard heard.count != canonical.count,
              hasDistinctiveOrthography(canonicalTerm)
        else {
            return false
        }
        let heardCompact = heard.map(\.normalized).joined()
        let canonicalCompact = canonical.map(\.normalized).joined()
        guard heardCompact.count >= 3,
              canonicalCompact.count >= 3,
              heardCompact.first == canonicalCompact.first
        else {
            return false
        }
        let distance = editDistance(
            Array(heardCompact),
            Array(canonicalCompact)
        )
        return Double(distance)
            / Double(max(heardCompact.count, canonicalCompact.count)) <= 0.45
    }

    private static func hasDistinctiveOrthography(_ value: String) -> Bool {
        if value.contains("-") || value.contains("+") || value.contains("#")
            || value.contains(".") || value.contains("&") || value.contains("/")
            || value.contains("_")
        {
            return true
        }
        let letters = value.filter(\.isLetter)
        guard !letters.isEmpty else { return false }
        if letters.count >= 2 && letters == letters.uppercased() {
            return true
        }
        return letters.dropFirst().contains(where: \.isUppercase)
    }

    private static func editDistance<Element: Equatable>(
        _ source: [Element],
        _ target: [Element]
    ) -> Int {
        if source.isEmpty { return target.count }
        if target.isEmpty { return source.count }
        var previous = Array(0...target.count)
        for (sourceOffset, sourceElement) in source.enumerated() {
            var current = Array(repeating: 0, count: target.count + 1)
            current[0] = sourceOffset + 1
            for (targetOffset, targetElement) in target.enumerated() {
                let substitution = previous[targetOffset]
                    + (sourceElement == targetElement ? 0 : 1)
                current[targetOffset + 1] = min(
                    previous[targetOffset + 1] + 1,
                    current[targetOffset] + 1,
                    substitution
                )
            }
            previous = current
        }
        return previous[target.count]
    }

    private static func contains(_ phrase: [String], in text: String) -> Bool {
        let haystack = tokens(text).map(\.normalized)
        guard !phrase.isEmpty, phrase.count <= haystack.count else { return false }
        for start in 0...(haystack.count - phrase.count)
        where Array(haystack[start..<(start + phrase.count)]) == phrase
        {
            return true
        }
        return false
    }

    private static func tokens(_ text: String) -> [Token] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return tokenExpression.matches(in: text, range: range).compactMap {
            match in
            guard let range = Range(match.range, in: text) else { return nil }
            let value = String(text[range])
            return Token(value: value, normalized: normalizedPhrase(value))
        }
    }

    private static func normalizedPhrase(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        .replacingOccurrences(of: "’", with: "'")
        .replacingOccurrences(of: "‐", with: "-")
        .replacingOccurrences(of: "‑", with: "-")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let tokenExpression = try! NSRegularExpression(
        pattern: #"[\p{L}\p{N}]+(?:[.'’+#&/_‐‑-][\p{L}\p{N}]+)*"#
    )

    private struct Token {
        let value: String
        let normalized: String
    }

    private struct CanonicalTerm {
        let value: String
        let key: String
        let tokens: [Token]
    }

    private struct Evidence {
        let recordID: UUID
        let createdAt: Date
        let heardKey: String
        let canonicalKey: String
        let heardForm: String
        let canonicalTerm: String
    }
}
