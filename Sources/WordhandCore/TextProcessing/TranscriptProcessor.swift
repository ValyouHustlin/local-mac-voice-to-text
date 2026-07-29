import Foundation

public struct TranscriptProcessor: TranscriptProcessing, Sendable {
    private let dictionary: DictionaryMatcher
    private let formattingProfile: TranscriptFormattingProfile?

    public init(
        dictionaryEntries: [DictionaryEntry] = [],
        formattingProfile: TranscriptFormattingProfile? = nil
    ) {
        dictionary = DictionaryMatcher(entries: dictionaryEntries)
        self.formattingProfile = formattingProfile
    }

    public func process(_ text: String, target: TranscriptTarget = .unknown) async -> String {
        let withoutFillers = Self.removeSpeechFillers(
            dictionary.apply(to: Self.sanitize(text))
        )
        let cleaned = SpokenCorrectionEngine.apply(to: withoutFillers)
        guard let formattingProfile else { return cleaned }
        switch formattingProfile {
        case .casual, .formatted, .professional, .aiCommunication:
            return Self.polish(cleaned)
        }
    }

    public static func sanitize(_ text: String) -> String {
        let namedNonSpeech = [
            #"\[(?:blank_audio|music|applause|laughter|silence|noise|background noise)\]"#,
            #"\((?:silence|music|music playing|applause|laughter|noise|background noise)\)"#,
            #"\*(?:silence|music|music playing|applause|laughter|noise|background noise)\*"#,
            #"<\|[^|]*\|>"#,
        ]

        var output = text
        for pattern in namedNonSpeech {
            output = output.replacingOccurrences(
                of: pattern,
                with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        output = output.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes unambiguous hesitation sounds wherever they occur while
    /// preserving words that merely contain the same letters. Dictionary
    /// substitutions run first so a user-defined meaning for a token wins.
    public static func removeSpeechFillers(_ text: String) -> String {
        var output = text.replacingOccurrences(
            of: #"(?i)^\s*(?:(?:um+|uh+|erm+|hmm+)(?![\p{L}\p{N}-])\s*[,.;:!?…—–-]*\s*)+"#,
            with: "",
            options: .regularExpression
        )
        output = output.replacingOccurrences(
            of: #"(?i)(?<=[.!?])\s+(?:um+|uh+|erm+|hmm+)(?![\p{L}\p{N}-])\s*[.!?]+\s*"#,
            with: " ",
            options: .regularExpression
        )
        output = output.replacingOccurrences(
            of: #"(?i)(?:[,;:]|\.{2,}|[—–])?\s*(?<![\p{L}\p{N}-])(?:um+|uh+|erm+|hmm+)(?![\p{L}\p{N}-])\s*(?:[,;:]|\.{2,}|[—–])?"#,
            with: " ",
            options: .regularExpression
        )
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

    public static func polish(_ text: String) -> String {
        var output = removeSpeechFillers(text)
        output = output.replacingOccurrences(
            of: #"(?i)\s+(?:and\s+)?then\s+"#,
            with: ". Then ",
            options: .regularExpression
        )
        output = output.replacingOccurrences(
            of: #"\s+([,.;:!?])"#,
            with: "$1",
            options: .regularExpression
        )
        output = output.replacingOccurrences(
            of: #"\.{2,}"#,
            with: ".",
            options: .regularExpression
        )
        output = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return output }

        output.replaceSubrange(
            output.startIndex...output.startIndex,
            with: String(output[output.startIndex]).uppercased()
        )
        if !output.hasSuffix(".")
            && !output.hasSuffix("!")
            && !output.hasSuffix("?")
            && !output.hasSuffix(":")
        {
            output.append(".")
        }
        return output
    }

    public static func structureForAI(_ text: String) -> String {
        guard !text.contains("\n") else { return text }
        let separated = text.replacingOccurrences(
            of: #"(?<=[.!?])\s+"#,
            with: "\n",
            options: .regularExpression
        )
        let sentences = separated
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard sentences.count >= 3 else { return text }
        return sentences.map { "- \($0)" }.joined(separator: "\n")
    }

    public static func professionalize(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"(?i)^\s*(?:okay[, ]+so[, ]*|okay[, ]+|so[, ]+)"#,
            with: "",
            options: .regularExpression
        )
    }
}
