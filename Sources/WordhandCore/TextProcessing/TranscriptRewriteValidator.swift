import Foundation

/// Rejects local model rewrites that may have dropped high-risk dictated
/// details. Rejection falls back to deterministic cleanup rather than letting
/// a fluent rewrite silently change the user's request.
public enum TranscriptRewriteValidator {
    private static let tokenTrimCharacters = CharacterSet(
        charactersIn: "\"'`“”‘’()[]{}<>,;:!?"
    )
    private static let negations: Set<String> = [
        "no", "not", "never", "without", "cannot",
        "can't", "cant", "don't", "dont", "won't", "wont",
        "shouldn't", "shouldnt", "wouldn't", "wouldnt",
        "mustn't", "mustnt", "isn't", "isnt", "aren't", "arent",
    ]
    private static let meaningMarkers: Set<String> = [
        "i", "i'm", "i'll", "i've",
        "we", "we're", "we'll", "we've",
        "my", "our", "you", "your",
        "need", "needs", "needed", "want", "wants", "wanted",
        "must", "should", "could", "would", "may", "might",
        "plan", "plans", "planned", "ask", "asks", "asked",
        "think", "believe", "guess", "seem", "seems",
        "likely", "probably", "maybe", "perhaps",
    ]

    public static func isAcceptable(candidate: String, original: String) -> Bool {
        let candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return false }

        let originalWords = words(in: original)
        let candidateWords = words(in: candidate)
        let ratio = Double(candidateWords.count) / Double(max(1, originalWords.count))
        guard (0.55...1.65).contains(ratio) else { return false }

        let candidateFolded = candidate.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        for token in protectedTokens(in: original) {
            let folded = token.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            guard candidateFolded.contains(folded) else { return false }
        }

        let candidateMeaningMarkers = Set(
            candidateWords.map { $0.lowercased() }
        ).intersection(meaningMarkers)
        guard requiredMeaningMarkers(in: original).isSubset(
            of: candidateMeaningMarkers
        ) else {
            return false
        }

        let originalNegations = originalWords.count(where: isNegation)
        let candidateNegations = candidateWords.count(where: isNegation)
        return candidateNegations >= originalNegations
    }

    public static func requiredMeaningMarkers(in text: String) -> Set<String> {
        Set(words(in: text).map { $0.lowercased() }).intersection(meaningMarkers)
    }

    private static func words(in text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map {
            String($0).trimmingCharacters(in: tokenTrimCharacters)
        }
    }

    private static func protectedTokens(in text: String) -> Set<String> {
        Set(words(in: text).filter { token in
            guard token.count >= 2 else { return false }
            if token.unicodeScalars.contains(where: CharacterSet.decimalDigits.contains) {
                return true
            }
            if token.contains("/") || token.contains("\\") || token.contains("@")
                || token.contains("_")
            {
                return true
            }
            if token.dropLast().contains(".") { return true }

            let letters = token.unicodeScalars.filter(CharacterSet.letters.contains)
            return letters.count >= 2
                && letters.allSatisfy { CharacterSet.uppercaseLetters.contains($0) }
        })
    }

    private static func isNegation(_ token: String) -> Bool {
        negations.contains(token.lowercased())
    }
}
