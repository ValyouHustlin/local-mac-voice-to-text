import Foundation

/// Resolves explicit spoken repairs before style formatting.
///
/// The engine intentionally handles only correction language with a clear
/// structural signal. Ambiguous rewrites remain available to the on-device
/// formatter, while the raw transcript remains unchanged in history.
public enum SpokenCorrectionEngine {
    private enum MarkerKind {
        case replaceTail
        case replaceSentence
    }

    private struct Marker {
        let range: Range<String.Index>
        let kind: MarkerKind
    }

    private static let markerPatterns: [(String, MarkerKind)] = [
        (
            #"(?i)(?:^|\s*[—–-]\s*|\s+)(?:(?:actually|wait)[,\s]+)?(?:scratch that|start over)(?:\s*[—–,:-]\s*|\s+)"#,
            .replaceSentence
        ),
        (
            #"(?i)(?:\s*[—–-]\s*(?:(?:wait|sorry)[,\s]+)?(?:no[,\s]+)?i\s+meant|\s+(?:(?:wait|sorry)[,\s]+|no[,\s]+)i\s+meant|(?:\s*[—–,:-]\s*|\s+)(?:make\s+that|correction))(?:\s*[:,—–-]\s*|\s+)"#,
            .replaceTail
        ),
        (
            #"(?i)(?:^|\s*[—–-]\s*|\s+)wait[,\s]+no(?:\s*[:,—–-]\s*|\s+|\s*[.!?]\s*$|$)"#,
            .replaceTail
        ),
    ]

    public static func apply(to text: String) -> String {
        var output = text
        for _ in 0..<8 {
            guard let marker = firstMarker(in: output) else { break }
            output = apply(marker, to: output)
        }
        output = removeImmediateFalseStarts(from: output)
        output = output.replacingOccurrences(
            of: #"\s+([,.;:!?])"#,
            with: "$1",
            options: .regularExpression
        )
        output = output.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstMarker(in text: String) -> Marker? {
        let candidates = markerPatterns.compactMap { pattern, kind -> Marker? in
            guard
                let range = text.range(
                    of: pattern,
                    options: .regularExpression
                )
            else {
                return nil
            }
            return Marker(range: range, kind: kind)
        }
        return candidates.min {
            if $0.range.lowerBound != $1.range.lowerBound {
                return $0.range.lowerBound < $1.range.lowerBound
            }
            return text.distance(from: $0.range.lowerBound, to: $0.range.upperBound)
                > text.distance(from: $1.range.lowerBound, to: $1.range.upperBound)
        }
    }

    private static func apply(_ marker: Marker, to text: String) -> String {
        let prefix = String(text[..<marker.range.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let remainder = String(text[marker.range.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let (replacement, suffix) = splitFirstSentence(from: remainder)
        guard !replacement.isEmpty else {
            let retained = marker.kind == .replaceSentence
                ? textBeforeCurrentSentence(in: prefix)
                : prefix
            let markerText = String(text[marker.range])
            let terminal = markerText.last.flatMap { ".!?".contains($0) ? String($0) : nil }
            let punctuated = terminal.map { retained + $0 } ?? retained
            return (punctuated + " " + suffix)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let keptPrefix: String
        switch marker.kind {
        case .replaceSentence:
            keptPrefix = textBeforeCurrentSentence(in: prefix)
        case .replaceTail:
            if replacementStartsFullClause(replacement) {
                keptPrefix = textBeforeCurrentSentence(in: prefix)
            } else {
                keptPrefix = textBeforeCorrectedTail(
                    in: prefix,
                    replacement: replacement
                )
            }
        }

        let normalizedReplacement =
            keptPrefix.isEmpty || keptPrefix.last.map { ".!?".contains($0) } == true
                ? capitalizingFirstLetter(of: replacement)
                : replacement
        return [keptPrefix, normalizedReplacement, suffix]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func splitFirstSentence(from text: String) -> (String, String) {
        guard
            let boundary = text.firstIndex(where: { ".!?".contains($0) })
        else {
            return (text, "")
        }
        let afterBoundary = text.index(after: boundary)
        return (
            String(text[..<afterBoundary]).trimmingCharacters(in: .whitespacesAndNewlines),
            String(text[afterBoundary...]).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func textBeforeCurrentSentence(in text: String) -> String {
        guard
            let boundary = text.lastIndex(where: { ".!?".contains($0) })
        else {
            return ""
        }
        return String(text[...boundary]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func textBeforeCorrectedTail(
        in text: String,
        replacement: String
    ) -> String {
        let wordPattern = #"[\p{L}\p{N}][\p{L}\p{N}'’.-]*"#
        let wordRanges = ranges(matching: wordPattern, in: text)
        guard !wordRanges.isEmpty else { return "" }

        let replacementWords = ranges(matching: wordPattern, in: replacement)
            .map { String(replacement[$0]) }
        let leadingProperWords = replacementWords
            .prefix { word in
                guard let first = word.first else { return false }
                return first.isUppercase || word.allSatisfy { !$0.isLetter || $0.isUppercase }
            }
            .count
        let desiredScope = max(1, leadingProperWords)
        let scope = min(desiredScope, max(1, wordRanges.count - 1))
        let start = wordRanges[wordRanges.count - scope].lowerBound
        return String(text[..<start])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replacementStartsFullClause(_ text: String) -> Bool {
        let words = text
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        guard words.count >= 2 else { return false }
        let subjects: Set<String> = [
            "i", "we", "you", "they", "he", "she", "it", "this", "that",
        ]
        let predicates: Set<String> = [
            "am", "are", "is", "was", "were", "will", "would", "should",
            "could", "can", "need", "needs", "want", "wants", "think",
            "thinks", "have", "has", "do", "does", "did",
        ]
        return subjects.contains(words[0]) && predicates.contains(words[1])
    }

    private static func removeImmediateFalseStarts(from text: String) -> String {
        var output = text
        let pattern =
            #"(?i)\b(i|we|you|they|he|she|it|the|a|an|to|can|could|should|would|will|want|need)(?:\s*,?\s+)\1\b"#
        for _ in 0..<4 {
            let reduced = output.replacingOccurrences(
                of: pattern,
                with: "$1",
                options: .regularExpression
            )
            guard reduced != output else { break }
            output = reduced
        }
        return output
    }

    private static func capitalizingFirstLetter(of text: String) -> String {
        guard
            let index = text.firstIndex(where: \.isLetter)
        else {
            return text
        }
        var output = text
        output.replaceSubrange(
            index...index,
            with: String(output[index]).uppercased()
        )
        return output
    }

    private static func ranges(
        matching pattern: String,
        in text: String
    ) -> [Range<String.Index>] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: fullRange).compactMap {
            Range($0.range, in: text)
        }
    }
}
