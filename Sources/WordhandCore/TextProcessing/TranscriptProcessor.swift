import Foundation

public struct TranscriptProcessor: ReportingTranscriptProcessing, Sendable {
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
        await processResult(text, target: target).text
    }

    public func processResult(
        _ text: String,
        target: TranscriptTarget = .unknown
    ) async -> TranscriptProcessingResult {
        let withoutFillers = Self.removeSpeechFillers(
            dictionary.apply(to: Self.sanitize(text))
        )
        let cleaned = SpokenCorrectionEngine.apply(to: withoutFillers)
        let replacement = SpokenReplacementCommandEngine.apply(to: cleaned)
        if case .rejected = replacement.outcome {
            return TranscriptProcessingResult(
                text: replacement.text,
                notices: notices(for: replacement.outcome)
            )
        }
        let layout = SpokenLayoutCommandEngine.protect(replacement.text)
        guard let formattingProfile else {
            return TranscriptProcessingResult(
                text: layout.render(layout.protectedText),
                notices: notices(for: replacement.outcome)
            )
        }
        let formatted: String
        switch formattingProfile {
        case .casual, .formatted, .professional, .aiCommunication:
            formatted = Self.polish(layout.protectedText)
        }
        return TranscriptProcessingResult(
            text: layout.render(formatted),
            notices: notices(for: replacement.outcome)
        )
    }

    private func notices(
        for outcome: SpokenReplacementCommandOutcome
    ) -> [TranscriptProcessingNotice] {
        guard case .rejected(let reason) = outcome else { return [] }
        return [.spokenReplacementRejected(reason)]
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
            of: #"(?i)\b(https?):[\\/]+(?=[\p{L}\p{N}])"#,
            with: "$1://",
            options: .regularExpression
        )
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
        var output = removePostSentenceFillersBeforeLowercaseWord(text)
        output = output.replacingOccurrences(
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

    private static func removePostSentenceFillersBeforeLowercaseWord(
        _ text: String
    ) -> String {
        let pattern =
            #"(?i)(?<=[.!?])\s+"#
            + #"(?:(?:um+|uh+|erm+|hmm+)(?![\p{L}\p{N}-])"#
            + #"\s*[,.;:!?…—–-]*\s*)+(?<next>\p{Ll})"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return text
        }

        let mutable = NSMutableString(string: text)
        let matches = expression.matches(
            in: text,
            range: NSRange(location: 0, length: mutable.length)
        )
        for match in matches.reversed() {
            let nextRange = match.range(withName: "next")
            guard nextRange.location != NSNotFound else { continue }
            let next = mutable.substring(with: nextRange).uppercased()
            mutable.replaceCharacters(in: match.range, with: " " + next)
        }
        return mutable as String
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
        // The on-device rewriter has the semantic context needed to choose
        // paragraphs, bullets, numbered steps, or lightweight sections.
        // A sentence-count heuristic cannot make that decision safely.
        text
    }

    public static func professionalize(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"(?i)^\s*(?:okay[, ]+so[, ]*|okay[, ]+|so[, ]+)"#,
            with: "",
            options: .regularExpression
        )
    }
}
