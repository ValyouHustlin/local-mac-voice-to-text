import Foundation

public struct VocabularySuggestion: Equatable, Identifiable, Sendable {
    public let id: String
    public let canonicalTerm: String
    public let supportCount: Int
    public let supportingTranscriptIDs: [UUID]
    public let latestSupportingTranscriptID: UUID

    public init(
        id: String,
        canonicalTerm: String,
        supportingTranscriptIDs: [UUID],
        latestSupportingTranscriptID: UUID
    ) {
        self.id = id
        self.canonicalTerm = canonicalTerm
        supportCount = supportingTranscriptIDs.count
        self.supportingTranscriptIDs = supportingTranscriptIDs
        self.latestSupportingTranscriptID = latestSupportingTranscriptID
    }
}

/// Finds conservative, user-reviewable vocabulary opportunities from local
/// evidence. It never changes dictionary or history state.
public enum VocabularySuggestionOracle {
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
    ) -> [VocabularySuggestion] {
        let uniqueRecords = Dictionary(grouping: records, by: \.id).compactMap {
            _, duplicates in duplicates.max(by: recordPrecedence)
        }
        let evidenceRows: [Evidence] = uniqueRecords.compactMap { record in
            makeEvidence(
                from: record,
                hasRetainedRecording: retainedRecordingIDs.contains(record.id)
            )
        }
        let replacementsBySource = Dictionary(grouping: evidenceRows, by: \.sourceKey)
            .mapValues { Set($0.map(\.canonicalKey)) }
        let conflictedSources = Set(
            replacementsBySource.compactMap { source, replacements in
                replacements.count > 1 ? source : nil
            }
        )
        let existingCanonicalTerms: Set<String> = Set(existingEntries.compactMap {
            entry -> String? in
            let spoken = normalizedPhrase(entry.spokenForm)
            let replacement = normalizedPhrase(entry.replacement)
            guard entry.isEnabled, spoken == replacement else { return nil }
            return replacement
        })

        return Dictionary(grouping: evidenceRows, by: \.canonicalKey)
            .compactMap { canonicalKey, group -> (VocabularySuggestion, Date)? in
                let supported = group.filter {
                    !conflictedSources.contains($0.sourceKey)
                }.sorted(by: evidenceOrder)
                guard supported.count >= minimumSupport,
                      !existingCanonicalTerms.contains(canonicalKey),
                      let latest = supported.last
                else {
                    return nil
                }
                let ids = supported.map(\.recordID)
                return (
                    VocabularySuggestion(
                        id: "v1|\(canonicalKey)",
                        canonicalTerm: latest.canonicalTerm,
                        supportingTranscriptIDs: ids,
                        latestSupportingTranscriptID: latest.recordID
                    ),
                    latest.createdAt
                )
            }
            .sorted {
                if $0.0.supportCount != $1.0.supportCount {
                    return $0.0.supportCount > $1.0.supportCount
                }
                if $0.1 != $1.1 {
                    return $0.1 > $1.1
                }
                return $0.0.canonicalTerm.localizedCaseInsensitiveCompare(
                    $1.0.canonicalTerm
                ) == .orderedAscending
            }
            .map(\.0)
    }

    private static func makeEvidence(
        from record: TranscriptRecord,
        hasRetainedRecording: Bool
    ) -> Evidence? {
        guard hasRetainedRecording,
              let reference = record.referenceText?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !reference.isEmpty
        else {
            return nil
        }

        let sourceTokens = tokens(in: record.text)
        let referenceTokens = tokens(in: reference)
        guard !sourceTokens.isEmpty, !referenceTokens.isEmpty else { return nil }

        var prefixCount = 0
        while prefixCount < min(sourceTokens.count, referenceTokens.count),
              sourceTokens[prefixCount].normalized
                == referenceTokens[prefixCount].normalized
        {
            prefixCount += 1
        }

        var suffixCount = 0
        while suffixCount < sourceTokens.count - prefixCount,
              suffixCount < referenceTokens.count - prefixCount,
              sourceTokens[sourceTokens.count - suffixCount - 1].normalized
                == referenceTokens[referenceTokens.count - suffixCount - 1].normalized
        {
            suffixCount += 1
        }

        let sourceChange = Array(
            sourceTokens[prefixCount..<(sourceTokens.count - suffixCount)]
        )
        let referenceChange = Array(
            referenceTokens[prefixCount..<(referenceTokens.count - suffixCount)]
        )
        guard (1...maximumChangedTokens).contains(sourceChange.count),
              (1...maximumChangedTokens).contains(referenceChange.count)
        else {
            return nil
        }

        let sourceKey = sourceChange.map(\.normalized).joined(separator: " ")
        let canonicalKey = referenceChange.map(\.normalized).joined(separator: " ")
        guard sourceKey != canonicalKey,
              rawRecognitionContains(sourceChange, in: record.rawText),
              safeLexicalChange(
                  source: sourceChange,
                  replacement: referenceChange,
                  replacementStartsAt: prefixCount
              )
        else {
            return nil
        }

        guard let canonicalTerm = exactPhrase(
            referenceChange,
            in: reference
        ) else {
            return nil
        }

        return Evidence(
            recordID: record.id,
            createdAt: record.createdAt,
            sourceKey: sourceKey,
            canonicalKey: canonicalKey,
            canonicalTerm: canonicalTerm
        )
    }

    private static func safeLexicalChange(
        source: [Token],
        replacement: [Token],
        replacementStartsAt: Int
    ) -> Bool {
        let allWords = source.map(\.normalized) + replacement.map(\.normalized)
        guard allWords.allSatisfy({ !$0.isEmpty }),
              protectedWords.isDisjoint(with: allWords),
              !allWords.contains(where: { $0.contains(where: \.isNumber) })
        else {
            return false
        }

        let sourceCompact = source.map(\.normalized).joined()
        let replacementCompact = replacement.map(\.normalized).joined()
        guard replacementCompact.count >= 3, replacementCompact.count <= 48 else {
            return false
        }
        let replacementText = replacement.map(\.value).joined(separator: " ")
        if hasDistinctiveOrthography(replacementText) {
            return true
        }
        if replacementStartsAt > 0,
           source.allSatisfy({ $0.value == $0.value.lowercased() }),
           replacement.contains(where: isCapitalized)
        {
            return true
        }

        guard source.count > 1,
              replacement.count == 1,
              replacementCompact.count <= 5
        else {
            return false
        }
        let distance = editDistance(Array(sourceCompact), Array(replacementCompact))
        let denominator = max(sourceCompact.count, replacementCompact.count)
        return denominator > 0 && Double(distance) / Double(denominator) <= 0.4
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

    private static func isCapitalized(_ token: Token) -> Bool {
        guard let first = token.value.first, first.isUppercase else { return false }
        return token.value.dropFirst().contains(where: \.isLowercase)
    }

    private static func rawRecognitionContains(
        _ changedSource: [Token],
        in rawText: String
    ) -> Bool {
        let rawTokens = tokens(in: rawText).map(\.normalized)
        let needle = changedSource.map(\.normalized)
        guard rawTokens.count >= needle.count else { return false }
        for offset in 0...(rawTokens.count - needle.count)
        where Array(rawTokens[offset..<(offset + needle.count)]) == needle
        {
            return true
        }
        return false
    }

    private static func tokens(in value: String) -> [Token] {
        let pattern = #"[A-Za-z0-9]+(?:[.'’+#&/_-][A-Za-z0-9]+)*"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.matches(in: value, range: range).compactMap { match in
            guard let tokenRange = Range(match.range, in: value) else { return nil }
            let token = String(value[tokenRange])
            return Token(
                value: token,
                normalized: normalizedWord(token),
                range: match.range
            )
        }
    }

    private static func exactPhrase(
        _ phraseTokens: [Token],
        in source: String
    ) -> String? {
        guard let first = phraseTokens.first, let last = phraseTokens.last else {
            return nil
        }
        let sourceNSString = source as NSString
        for (left, right) in zip(phraseTokens, phraseTokens.dropFirst()) {
            let gapStart = NSMaxRange(left.range)
            let gapLength = right.range.location - gapStart
            guard gapLength >= 0 else { return nil }
            let gap = sourceNSString.substring(
                with: NSRange(location: gapStart, length: gapLength)
            )
            guard gap.allSatisfy(\.isWhitespace) else { return nil }
        }
        let range = NSRange(
            location: first.range.location,
            length: NSMaxRange(last.range) - first.range.location
        )
        return sourceNSString.substring(with: range)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedPhrase(_ value: String) -> String {
        tokens(in: value).map(\.normalized).joined(separator: " ")
    }

    private static func normalizedWord(_ value: String) -> String {
        value.replacingOccurrences(of: "’", with: "'").folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
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

    private static func evidenceOrder(_ lhs: Evidence, _ rhs: Evidence) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.recordID.uuidString < rhs.recordID.uuidString
    }

    private static func recordPrecedence(
        _ lhs: TranscriptRecord,
        _ rhs: TranscriptRecord
    ) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        let lhsSignature = [
            lhs.rawText,
            lhs.text,
            lhs.referenceText ?? "",
            lhs.modelID,
        ].joined(separator: "\u{0}")
        let rhsSignature = [
            rhs.rawText,
            rhs.text,
            rhs.referenceText ?? "",
            rhs.modelID,
        ].joined(separator: "\u{0}")
        return lhsSignature < rhsSignature
    }

    private struct Token {
        let value: String
        let normalized: String
        let range: NSRange
    }

    private struct Evidence {
        let recordID: UUID
        let createdAt: Date
        let sourceKey: String
        let canonicalKey: String
        let canonicalTerm: String
    }
}
