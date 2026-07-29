import Foundation

public struct TranscriptProcessor: TranscriptProcessing, Sendable {
    private let dictionary: DictionaryMatcher

    public init(dictionaryEntries: [DictionaryEntry] = []) {
        dictionary = DictionaryMatcher(entries: dictionaryEntries)
    }

    public func process(_ text: String) -> String {
        dictionary.apply(to: Self.sanitize(text))
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
}
