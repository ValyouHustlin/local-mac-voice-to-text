import Foundation

public struct SpokenLayoutCommandPlan: Equatable, Sendable {
    fileprivate struct Replacement: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case line
            case paragraph

            var separator: String {
                switch self {
                case .line: "\n"
                case .paragraph: "\n\n"
                }
            }
        }

        let token: String
        let kind: Kind
        let precedingAnchor: [String]
        let followingAnchor: [String]
    }

    public let protectedText: String
    fileprivate let replacements: [Replacement]
    fileprivate let literalLayoutMarkers: [String: Int]

    public var commandCount: Int {
        replacements.count
    }

    public func preservesCommands(in candidate: String) -> Bool {
        guard !replacements.isEmpty else { return true }
        var tokenRanges: [Range<String.Index>] = []
        for replacement in replacements {
            let ranges = Self.ranges(
                matching: Self.boundedPattern(for: replacement.token),
                in: candidate
            )
            guard ranges.count == 1,
                  let range = ranges.first
            else {
                return false
            }
            guard tokenRanges.last?.lowerBound ?? candidate.startIndex
                < range.lowerBound
            else {
                return false
            }
            tokenRanges.append(range)
        }
        for (index, replacement) in replacements.enumerated() {
            let range = tokenRanges[index]
            let precedingStart = index == 0
                ? candidate.startIndex
                : tokenRanges[index - 1].upperBound
            let followingEnd = index + 1 == tokenRanges.count
                ? candidate.endIndex
                : tokenRanges[index + 1].lowerBound
            let precedingWords = Self.words(
                in: String(candidate[precedingStart..<range.lowerBound])
            )
            let followingWords = Self.words(
                in: String(candidate[range.upperBound..<followingEnd])
            )
            guard precedingWords.suffix(replacement.precedingAnchor.count)
                == replacement.precedingAnchor[...],
                  followingWords.prefix(replacement.followingAnchor.count)
                    == replacement.followingAnchor[...]
            else {
                return false
            }
        }
        var expectedMarkers = literalLayoutMarkers
        for replacement in replacements {
            expectedMarkers[replacement.token.lowercased(), default: 0] += 1
        }
        return Self.reservedMarkers(in: candidate) == expectedMarkers
    }

    public func render(_ candidate: String) -> String {
        guard !replacements.isEmpty else { return candidate }
        let selected = preservesCommands(in: candidate)
            ? candidate
            : protectedText
        let output = restoringExpectedTokens(in: selected)
        guard Self.reservedMarkers(in: output) == literalLayoutMarkers else {
            return restoringExpectedTokens(in: protectedText)
        }
        return output
    }

    private func restoringExpectedTokens(in text: String) -> String {
        var output = text
        for replacement in replacements {
            let capitalizablePattern =
                Self.boundedPattern(for: replacement.token)
                + #"[.,;:!?]?[ \t\r\n]*([a-z])"#
            if let expression = try? NSRegularExpression(
                pattern: capitalizablePattern
            ) {
                let mutable = NSMutableString(string: output)
                let fullRange = NSRange(
                    output.startIndex..<output.endIndex,
                    in: output
                )
                if let match = expression.firstMatch(
                    in: output,
                    range: fullRange
                ) {
                    let letterRange = match.range(at: 1)
                    mutable.replaceCharacters(
                        in: letterRange,
                        with: mutable.substring(with: letterRange).uppercased()
                    )
                    output = mutable as String
                }
            }
            let pattern =
                #"[ \t]*(?:\n[ \t]*)*"# + Self.boundedPattern(
                    for: replacement.token
                ) + #"[.,;:!?]?[ \t]*(?:\n[ \t]*)*"#
            output = output.replacingOccurrences(
                of: pattern,
                with: replacement.kind.separator,
                options: .regularExpression
            )
        }
        return output
    }

    private static func boundedPattern(for token: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: token)
        return #"(?<![\p{L}\p{N}_])"# + escaped + #"(?![\p{L}\p{N}_])"#
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

    fileprivate static func reservedMarkers(in text: String) -> [String: Int] {
        let pattern =
            #"(?i)(?<![\p{L}\p{N}_])WORDHAND_LAYOUT[\p{L}\p{N}_-]*"#
        var counts: [String: Int] = [:]
        for range in ranges(matching: pattern, in: text) {
            counts[String(text[range]).lowercased(), default: 0] += 1
        }
        return counts
    }

    fileprivate static func words(in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(
            pattern: #"[\p{L}\p{N}][\p{L}\p{N}'’.-]*"#
        ) else {
            return []
        }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: fullRange).compactMap {
            Range($0.range, in: text).map {
                String(text[$0])
                    .trimmingCharacters(
                        in: CharacterSet(charactersIn: ".'’-")
                    )
                    .folding(
                        options: [.caseInsensitive, .diacriticInsensitive],
                        locale: Locale(identifier: "en_US_POSIX")
                    )
            }
        }
    }

}

/// Protects only explicit, standalone layout commands inside a dictation.
///
/// Requiring the reserved "command new …" namespace plus meaningful content
/// on both sides avoids treating ordinary phrases such as "start a new
/// paragraph" or "new line item" as editing instructions. Opaque tokens and
/// neighboring word anchors keep requested boundaries stable through local
/// style formatting.
public enum SpokenLayoutCommandEngine {
    public static func protect(_ text: String) -> SpokenLayoutCommandPlan {
        let pattern =
            #"(?i)([.!?,;:])[ \t]+"#
            + #"(command[ \t]+new[ \t]+line|command[ \t]+new[ \t]+paragraph)"#
            + #"[ \t]*[.,;:][ \t]+(?=\S)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return SpokenLayoutCommandPlan(
                protectedText: text,
                replacements: [],
                literalLayoutMarkers: [:]
            )
        }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = expression.matches(in: text, range: fullRange).filter {
            guard let range = Range($0.range, in: text) else { return false }
            return !isInsideQuotation(at: range.lowerBound, in: text)
        }
        guard !matches.isEmpty else {
            return SpokenLayoutCommandPlan(
                protectedText: text,
                replacements: [],
                literalLayoutMarkers: [:]
            )
        }

        let nonce = firstUnusedNonce(in: text)
        let replacements = matches.enumerated().compactMap {
            index, match -> SpokenLayoutCommandPlan.Replacement? in
            guard let fullMatchRange = Range(match.range, in: text),
                  let commandRange = Range(match.range(at: 2), in: text)
            else {
                return nil
            }
            let precedingStart: String.Index
            if index == 0 {
                precedingStart = text.startIndex
            } else {
                guard let previousRange = Range(matches[index - 1].range, in: text) else {
                    return nil
                }
                precedingStart = previousRange.upperBound
            }
            let followingEnd: String.Index
            if index + 1 == matches.count {
                followingEnd = text.endIndex
            } else {
                guard let nextRange = Range(matches[index + 1].range, in: text) else {
                    return nil
                }
                followingEnd = nextRange.lowerBound
            }
            let precedingWords = SpokenLayoutCommandPlan.words(
                in: String(text[precedingStart..<fullMatchRange.lowerBound])
            )
            let followingWords = SpokenLayoutCommandPlan.words(
                in: String(text[fullMatchRange.upperBound..<followingEnd])
            )
            guard !precedingWords.isEmpty, !followingWords.isEmpty else {
                return nil
            }
            let command = text[commandRange].lowercased()
            let kind: SpokenLayoutCommandPlan.Replacement.Kind =
                command.contains("paragraph") ? .paragraph : .line
                return SpokenLayoutCommandPlan.Replacement(
                token: "WORDHAND_LAYOUT_\(nonce)_\(index)",
                kind: kind,
                precedingAnchor: Array(precedingWords.suffix(4)),
                followingAnchor: Array(followingWords.prefix(4))
            )
        }
        guard replacements.count == matches.count else {
            return SpokenLayoutCommandPlan(
                protectedText: text,
                replacements: [],
                literalLayoutMarkers: [:]
            )
        }

        let mutable = NSMutableString(string: text)
        for (match, replacement) in zip(matches, replacements).reversed() {
            guard let punctuationRange = Range(match.range(at: 1), in: text) else {
                continue
            }
            let decodedSeparator = String(text[punctuationRange])
            let retainedPunctuation = ".!?".contains(decodedSeparator)
                ? decodedSeparator
                : ""
            mutable.replaceCharacters(
                in: match.range,
                with: "\(retainedPunctuation) \(replacement.token) "
            )
        }
        return SpokenLayoutCommandPlan(
            protectedText: mutable as String,
            replacements: replacements,
            literalLayoutMarkers:
                SpokenLayoutCommandPlan.reservedMarkers(in: text)
        )
    }

    private static func firstUnusedNonce(in text: String) -> String {
        let pattern = #"(?i)WORDHAND_LAYOUT_([0]+)_"#
        var occupied = Set<String>()
        if let expression = try? NSRegularExpression(pattern: pattern) {
            let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in expression.matches(in: text, range: fullRange) {
                if let range = Range(match.range(at: 1), in: text) {
                    occupied.insert(String(text[range]))
                }
            }
        }
        var nonce = "0"
        while occupied.contains(nonce) {
            nonce.append("0")
        }
        return nonce
    }

    private static func isInsideQuotation(
        at index: String.Index,
        in text: String
    ) -> Bool {
        let prefix = text[..<index]
        let curlyOpen = prefix.count(where: { $0 == "“" })
        let curlyClose = prefix.count(where: { $0 == "”" })
        if curlyOpen > curlyClose {
            return true
        }
        let straightQuotes = prefix.count(where: { $0 == "\"" })
        return straightQuotes.isMultiple(of: 2) == false
    }
}
