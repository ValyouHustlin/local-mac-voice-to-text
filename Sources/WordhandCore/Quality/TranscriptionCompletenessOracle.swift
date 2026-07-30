import Foundation

public enum ProtectedTranscriptCategory: String, Codable, CaseIterable, Sendable {
    case beginning
    case ending
    case number
    case negation
    case technicalTerm
    case dictionarySpelling
}

public enum ProtectedTranscriptPlacement: String, Codable, Sendable {
    case prefix
    case suffix
    case anywhere
}

public struct ProtectedTranscriptSpan: Codable, Equatable, Sendable {
    public let id: String
    public let category: ProtectedTranscriptCategory
    public let acceptedForms: [String]
    public let placement: ProtectedTranscriptPlacement
    public let expectedOccurrences: Int

    public init(
        id: String? = nil,
        category: ProtectedTranscriptCategory,
        acceptedForms: [String],
        placement: ProtectedTranscriptPlacement? = nil,
        expectedOccurrences: Int = 1
    ) {
        self.id = id ?? category.rawValue
        self.category = category
        self.acceptedForms = acceptedForms
        let defaultPlacement: ProtectedTranscriptPlacement = switch category {
        case .beginning: .prefix
        case .ending: .suffix
        case .number, .negation, .technicalTerm, .dictionarySpelling: .anywhere
        }
        self.placement = placement ?? defaultPlacement
        self.expectedOccurrences = expectedOccurrences
    }
}

public struct TranscriptionCompletenessFixture: Codable, Equatable, Sendable {
    public let id: String
    public let reference: String
    public let audioSHA256: String?
    public let sampleCount: Int?
    public let sampleRate: Int?
    public let vocabularyTerms: [String]
    public let protectedSpans: [ProtectedTranscriptSpan]

    public init(
        id: String,
        reference: String,
        audioSHA256: String? = nil,
        sampleCount: Int? = nil,
        sampleRate: Int? = nil,
        vocabularyTerms: [String] = [],
        protectedSpans: [ProtectedTranscriptSpan]
    ) {
        self.id = id
        self.reference = reference
        self.audioSHA256 = audioSHA256
        self.sampleCount = sampleCount
        self.sampleRate = sampleRate
        self.vocabularyTerms = vocabularyTerms
        self.protectedSpans = protectedSpans
    }

    public func validationIssues(
        requireAudioIdentity: Bool = false
    ) -> [String] {
        var issues: [String] = []
        if id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append("fixture id is empty")
        }
        if reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append("fixture reference is empty")
        }
        let presentCategories = Set(protectedSpans.map(\.category))
        for category in ProtectedTranscriptCategory.allCases
        where !presentCategories.contains(category) {
            issues.append("missing protected category: \(category.rawValue)")
        }
        let ids = protectedSpans.map(\.id)
        if Set(ids).count != ids.count {
            issues.append("protected span ids must be unique")
        }
        for span in protectedSpans {
            let requiredPlacement: ProtectedTranscriptPlacement = switch span.category {
            case .beginning: .prefix
            case .ending: .suffix
            case .number, .negation, .technicalTerm, .dictionarySpelling: .anywhere
            }
            if span.placement != requiredPlacement {
                issues.append(
                    "protected span \(span.id) has invalid placement for "
                        + span.category.rawValue
                )
            }
            if span.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append("protected span id is empty")
            }
            if span.acceptedForms.isEmpty || span.acceptedForms.contains(where: {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }) {
                issues.append("protected span \(span.id) has an empty accepted form")
            }
            if span.expectedOccurrences < 1 {
                issues.append("protected span \(span.id) has invalid occurrence count")
            }
        }
        for result in TranscriptionCompletenessOracle.protectedResults(
            protectedSpans,
            in: reference
        ) where !result.passed {
            issues.append(
                "reference does not satisfy protected span \(result.id)"
            )
        }
        if requireAudioIdentity {
            if audioSHA256?.count != 64 {
                issues.append("audio SHA-256 is missing or malformed")
            }
            if sampleCount.map({ $0 > 0 }) != true {
                issues.append("sample count is missing or invalid")
            }
            if sampleRate.map({ $0 > 0 }) != true {
                issues.append("sample rate is missing or invalid")
            }
        }
        return issues
    }
}

public struct ProtectedTranscriptResult: Codable, Equatable, Sendable {
    public let id: String
    public let category: ProtectedTranscriptCategory
    public let acceptedForms: [String]
    public let placement: ProtectedTranscriptPlacement
    public let expectedOccurrences: Int
    public let matchedOccurrenceCount: Int
    public let matchedForm: String?
    public let passed: Bool
}

public struct TranscriptionAuthorityComparison: Codable, Equatable, Sendable {
    public let fixtureID: String
    public let baselineQuality: TranscriptionQualityScore
    public let candidateQuality: TranscriptionQualityScore
    public let baselineProtected: [ProtectedTranscriptResult]
    public let candidateProtected: [ProtectedTranscriptResult]
    public let candidatePassesCompletenessGate: Bool
    public let rejectionReasons: [String]
}

public enum TranscriptionCompletenessOracle {
    public static func compare(
        fixture: TranscriptionCompletenessFixture,
        baseline: String,
        candidate: String
    ) -> TranscriptionAuthorityComparison? {
        guard fixture.validationIssues().isEmpty else { return nil }
        guard let baselineQuality = TranscriptionQualityMetrics.score(
            reference: fixture.reference,
            hypothesis: baseline
        ), let candidateQuality = TranscriptionQualityMetrics.score(
            reference: fixture.reference,
            hypothesis: candidate
        ) else {
            return nil
        }

        let baselineProtected = protectedResults(
            fixture.protectedSpans,
            in: baseline
        )
        let candidateProtected = protectedResults(
            fixture.protectedSpans,
            in: candidate
        )
        var rejectionReasons: [String] = candidateProtected.compactMap { result in
            guard !result.passed else { return nil }
            return "protected_\(result.id)_occurrence_mismatch"
        }
        if candidateQuality.wordErrorRate > baselineQuality.wordErrorRate {
            rejectionReasons.append("word_error_regression")
        }
        if candidateQuality.characterErrorRate
            > baselineQuality.characterErrorRate
        {
            rejectionReasons.append("spelling_error_regression")
        }

        return TranscriptionAuthorityComparison(
            fixtureID: fixture.id,
            baselineQuality: baselineQuality,
            candidateQuality: candidateQuality,
            baselineProtected: baselineProtected,
            candidateProtected: candidateProtected,
            candidatePassesCompletenessGate: rejectionReasons.isEmpty,
            rejectionReasons: rejectionReasons
        )
    }

    static func protectedResults(
        _ spans: [ProtectedTranscriptSpan],
        in transcript: String
    ) -> [ProtectedTranscriptResult] {
        let transcriptTokens = tokens(transcript)
        return spans.map { span in
            var seenForms = Set<[String]>()
            let forms = span.acceptedForms.compactMap { form -> (String, [String])? in
                let expected = tokens(form)
                guard !expected.isEmpty, seenForms.insert(expected).inserted else {
                    return nil
                }
                return (form, expected)
            }
            let matches: [(form: String, count: Int)] = forms.map {
                form, expected in
                (
                    form: form,
                    count: occurrenceCount(
                        of: expected,
                        in: transcriptTokens,
                        placement: span.placement
                    )
                )
            }
            let matchedOccurrenceCount = matches.reduce(0) { $0 + $1.count }
            let match = matches.first { $0.count > 0 }?.form
            return ProtectedTranscriptResult(
                id: span.id,
                category: span.category,
                acceptedForms: span.acceptedForms,
                placement: span.placement,
                expectedOccurrences: span.expectedOccurrences,
                matchedOccurrenceCount: matchedOccurrenceCount,
                matchedForm: match,
                passed: matchedOccurrenceCount == span.expectedOccurrences
            )
        }
    }

    private static func occurrenceCount(
        of expected: [String],
        in transcript: [String],
        placement: ProtectedTranscriptPlacement
    ) -> Int {
        guard !expected.isEmpty, expected.count <= transcript.count else {
            return 0
        }
        switch placement {
        case .prefix:
            return transcript.starts(with: expected) ? 1 : 0
        case .suffix:
            return transcript.suffix(expected.count).elementsEqual(expected) ? 1 : 0
        case .anywhere:
            return transcript.occurrenceCount(of: expected)
        }
    }

    private static func tokens(_ text: String) -> [String] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return tokenExpression.matches(in: text, range: range).compactMap {
            match in
            guard let range = Range(match.range, in: text) else { return nil }
            return String(text[range])
                .folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: Locale(identifier: "en_US_POSIX")
                )
                .replacingOccurrences(of: "’", with: "'")
                .replacingOccurrences(of: "‐", with: "-")
                .replacingOccurrences(of: "‑", with: "-")
        }
    }

    private static let tokenExpression = try! NSRegularExpression(
        pattern: #"\p{N}+(?:[.,]\p{N}+)*%?|[\p{L}\p{N}]+(?:['’‐‑-][\p{L}\p{N}]+)*"#
    )
}

private extension Array where Element: Equatable {
    func occurrenceCount(of subsequence: [Element]) -> Int {
        guard !subsequence.isEmpty, subsequence.count <= count else {
            return 0
        }
        var matches = 0
        for start in 0...(count - subsequence.count) {
            if self[start..<(start + subsequence.count)]
                .elementsEqual(subsequence)
            {
                matches += 1
            }
        }
        return matches
    }
}
