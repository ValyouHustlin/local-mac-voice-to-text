import Foundation

public struct DictionaryMatcher: Sendable {
    private let entries: [DictionaryEntry]

    public init(entries: [DictionaryEntry]) {
        self.entries = entries
            .filter { $0.isEnabled && !$0.spokenForm.isEmpty }
            .sorted {
                if $0.spokenForm.count == $1.spokenForm.count {
                    return $0.createdAt < $1.createdAt
                }
                return $0.spokenForm.count > $1.spokenForm.count
            }
    }

    public func apply(to text: String) -> String {
        guard !entries.isEmpty, !text.isEmpty else { return text }

        let patterns = entries.map { entry in
            let escaped = NSRegularExpression.escapedPattern(for: entry.spokenForm)
            let body: String
            switch entry.matchMode {
            case .word:
                body = #"(?<![\p{L}\p{N}_])\#(escaped)(?![\p{L}\p{N}_])"#
            case .phrase:
                body = escaped
            }
            return (
                entry: entry,
                expression: try? NSRegularExpression(
                    pattern: body,
                    options: entry.isCaseSensitive ? [] : [.caseInsensitive]
                )
            )
        }

        let original = text as NSString
        var matches: [(range: NSRange, replacement: String, priority: Int)] = []

        for (priority, item) in patterns.enumerated() {
            guard let expression = item.expression else { continue }
            let range = NSRange(location: 0, length: original.length)
            expression.enumerateMatches(in: text, range: range) { match, _, _ in
                guard let match else { return }
                matches.append((match.range, item.entry.replacement, priority))
            }
        }

        matches.sort {
            if $0.range.location == $1.range.location {
                if $0.range.length == $1.range.length {
                    return $0.priority < $1.priority
                }
                return $0.range.length > $1.range.length
            }
            return $0.range.location < $1.range.location
        }

        var accepted: [(range: NSRange, replacement: String)] = []
        var occupiedUntil = 0
        for match in matches {
            guard match.range.location >= occupiedUntil else { continue }
            accepted.append((match.range, match.replacement))
            occupiedUntil = match.range.location + match.range.length
        }

        let result = NSMutableString(string: text)
        for match in accepted.reversed() {
            result.replaceCharacters(in: match.range, with: match.replacement)
        }
        return result as String
    }
}
