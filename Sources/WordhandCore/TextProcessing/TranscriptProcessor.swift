import Foundation

public struct TranscriptProcessor: TranscriptProcessing, Sendable {
    private let dictionary: DictionaryMatcher
    private let formattingProfile: TranscriptFormattingProfile

    public init(
        dictionaryEntries: [DictionaryEntry] = [],
        formattingProfile: TranscriptFormattingProfile = .verbatim
    ) {
        dictionary = DictionaryMatcher(entries: dictionaryEntries)
        self.formattingProfile = formattingProfile
    }

    public func process(_ text: String, target: TranscriptTarget = .unknown) async -> String {
        let cleaned = dictionary.apply(to: Self.sanitize(text))
        switch formattingProfile.resolved(for: target) {
        case .verbatim:
            return cleaned
        case .automatic:
            return cleaned
        case .polished, .aiPrompt:
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

    public static func polish(_ text: String) -> String {
        var output = text.replacingOccurrences(
            of: #"(?i)^\s*(?:(?:um+|uh+|erm)[,\s]+)+"#,
            with: "",
            options: .regularExpression
        )
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
}
