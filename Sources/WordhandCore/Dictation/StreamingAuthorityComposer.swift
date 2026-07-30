import Foundation

public struct StreamingAuthorityRelease: Equatable, Sendable {
    public var sessionID: String
    public var finalSampleCount: Int
    public var stablePrefixAudioSHA256: String

    public init(
        sessionID: String,
        finalSampleCount: Int,
        stablePrefixAudioSHA256: String
    ) {
        self.sessionID = sessionID
        self.finalSampleCount = finalSampleCount
        self.stablePrefixAudioSHA256 = stablePrefixAudioSHA256
    }
}

public struct StableStreamingPrefix: Equatable, Sendable {
    public var sessionID: String
    public var text: String
    public var coveredThroughSample: Int
    public var snapshotSampleCount: Int
    public var audioSHA256: String

    public init(
        sessionID: String,
        text: String,
        coveredThroughSample: Int,
        snapshotSampleCount: Int,
        audioSHA256: String
    ) {
        self.sessionID = sessionID
        self.text = text
        self.coveredThroughSample = coveredThroughSample
        self.snapshotSampleCount = snapshotSampleCount
        self.audioSHA256 = audioSHA256
    }
}

public struct StreamingSuffixDecode: Equatable, Sendable {
    public var sessionID: String
    public var text: String
    public var startSample: Int
    public var endSample: Int

    public init(
        sessionID: String,
        text: String,
        startSample: Int,
        endSample: Int
    ) {
        self.sessionID = sessionID
        self.text = text
        self.startSample = startSample
        self.endSample = endSample
    }
}

public enum StreamingSuffixOutcome: Equatable, Sendable {
    case decoded(StreamingSuffixDecode)
    case failed(sessionID: String)

    fileprivate var sessionID: String {
        switch self {
        case .decoded(let decode): decode.sessionID
        case .failed(let sessionID): sessionID
        }
    }
}

public struct StreamingAuthorityCompositionRequest: Equatable, Sendable {
    public var release: StreamingAuthorityRelease
    public var stablePrefix: StableStreamingPrefix
    public var suffix: StreamingSuffixOutcome
    public var minimumOverlapWords: Int

    public init(
        release: StreamingAuthorityRelease,
        stablePrefix: StableStreamingPrefix,
        suffix: StreamingSuffixOutcome,
        minimumOverlapWords: Int = 6
    ) {
        self.release = release
        self.stablePrefix = stablePrefix
        self.suffix = suffix
        self.minimumOverlapWords = minimumOverlapWords
    }
}

public enum StreamingCompositionIntegrityVerdict: Equatable, Sendable {
    case verified
    case diverged
}

public enum StreamingCompositionFallbackReason: String, Equatable, Sendable {
    case staleSession
    case prefixAudioMismatch
    case invalidAudioCoverage
    case suffixDecodeFailed
    case insufficientOverlap
    case ambiguousOverlap
    case integrityDiverged
}

public struct VerifiedStreamingComposition: Equatable, Sendable {
    public let text: String
    public let overlapWordCount: Int
    public let reusedSampleCount: Int
    public let suffixStartSample: Int
    public let suffixSampleCount: Int

    public init(
        text: String,
        overlapWordCount: Int,
        reusedSampleCount: Int,
        suffixStartSample: Int,
        suffixSampleCount: Int
    ) {
        self.text = text
        self.overlapWordCount = overlapWordCount
        self.reusedSampleCount = reusedSampleCount
        self.suffixStartSample = suffixStartSample
        self.suffixSampleCount = suffixSampleCount
    }
}

public enum StreamingAuthorityCompositionDecision: Equatable, Sendable {
    case verified(VerifiedStreamingComposition)
    case requiresFullBuffer(StreamingCompositionFallbackReason)
}

public enum StreamingAuthorityComposer {
    public static func compose(
        _ request: StreamingAuthorityCompositionRequest,
        integrity: (String) -> StreamingCompositionIntegrityVerdict
    ) -> StreamingAuthorityCompositionDecision {
        let release = request.release
        let prefix = request.stablePrefix

        guard !release.sessionID.isEmpty,
              release.sessionID == prefix.sessionID,
              release.sessionID == request.suffix.sessionID
        else {
            return .requiresFullBuffer(.staleSession)
        }
        guard isCanonicalSHA256(release.stablePrefixAudioSHA256),
              isCanonicalSHA256(prefix.audioSHA256),
              release.stablePrefixAudioSHA256 == prefix.audioSHA256
        else {
            return .requiresFullBuffer(.prefixAudioMismatch)
        }
        guard release.finalSampleCount > 0,
              prefix.coveredThroughSample > 0,
              prefix.coveredThroughSample <= prefix.snapshotSampleCount,
              prefix.snapshotSampleCount <= release.finalSampleCount
        else {
            return .requiresFullBuffer(.invalidAudioCoverage)
        }
        guard case .decoded(let suffix) = request.suffix else {
            return .requiresFullBuffer(.suffixDecodeFailed)
        }
        guard suffix.startSample >= 0,
              suffix.startSample < prefix.coveredThroughSample,
              suffix.startSample < suffix.endSample,
              suffix.endSample == release.finalSampleCount
        else {
            return .requiresFullBuffer(.invalidAudioCoverage)
        }

        let overlap = uniqueOverlap(
            prefix: prefix.text,
            suffix: suffix.text,
            minimumWords: max(6, request.minimumOverlapWords)
        )
        switch overlap {
        case .insufficient:
            return .requiresFullBuffer(.insufficientOverlap)
        case .ambiguous:
            return .requiresFullBuffer(.ambiguousOverlap)
        case .unique(let composition, let wordCount):
            guard integrity(composition) == .verified else {
                return .requiresFullBuffer(.integrityDiverged)
            }
            return .verified(VerifiedStreamingComposition(
                text: composition,
                overlapWordCount: wordCount,
                reusedSampleCount: suffix.startSample,
                suffixStartSample: suffix.startSample,
                suffixSampleCount: suffix.endSample - suffix.startSample
            ))
        }
    }

    private static func uniqueOverlap(
        prefix: String,
        suffix: String,
        minimumWords: Int
    ) -> OverlapDecision {
        guard minimumWords > 0 else { return .insufficient }
        let prefixWords = rangedWords(prefix)
        let suffixWords = rangedWords(suffix)
        let maximumOverlap = min(prefixWords.count, suffixWords.count)
        guard maximumOverlap >= minimumWords else { return .insufficient }

        for overlapCount in stride(
            from: maximumOverlap,
            through: minimumWords,
            by: -1
        ) {
            let prefixStart = prefixWords.count - overlapCount
            let overlapWords = Array(
                prefixWords[prefixStart...].map(\.normalized)
            )
            let prefixMatches = matchingStarts(
                for: overlapWords,
                in: prefixWords
            )
            let suffixMatches = matchingStarts(
                for: overlapWords,
                in: suffixWords
            )
            guard !suffixMatches.isEmpty else { continue }
            guard prefixMatches.count == 1,
                  suffixMatches.count == 1,
                  let suffixStart = suffixMatches.first
            else {
                return .ambiguous
            }

            let suffixEnd = suffixStart + overlapCount
            let trimmedPrefix = prefix.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard suffixEnd < suffixWords.count else {
                return .unique(trimmedPrefix, overlapCount)
            }
            let matchedWord = suffixWords[suffixEnd - 1]
            var remainder = String(
                suffix[matchedWord.range.upperBound...]
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !remainder.isEmpty else {
                return .unique(trimmedPrefix, overlapCount)
            }
            if let prefixLast = trimmedPrefix.last,
               let remainderFirst = remainder.first,
               isPunctuation(prefixLast),
               isPunctuation(remainderFirst)
            {
                remainder.removeFirst()
                remainder = remainder.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            }
            guard !remainder.isEmpty else {
                return .unique(trimmedPrefix, overlapCount)
            }
            let separator = remainder.first.map {
                isPunctuation($0) ? "" : " "
            } ?? ""
            return .unique(
                trimmedPrefix + separator + remainder,
                overlapCount
            )
        }
        return .insufficient
    }

    private static func matchingStarts(
        for expected: [String],
        in words: [RangedWord]
    ) -> [Int] {
        guard !expected.isEmpty, expected.count <= words.count else {
            return []
        }
        return (0...(words.count - expected.count)).filter { start in
            expected.indices.allSatisfy { offset in
                words[start + offset].normalized == expected[offset]
            }
        }
    }

    private static func rangedWords(_ value: String) -> [RangedWord] {
        var words: [RangedWord] = []
        value.enumerateSubstrings(
            in: value.startIndex..<value.endIndex,
            options: [.byWords, .substringNotRequired]
        ) { _, range, _, _ in
            let normalized = normalizedIdentifier(String(value[range]))
            if !normalized.isEmpty {
                words.append(RangedWord(normalized: normalized, range: range))
            }
        }
        return words
    }

    private static func isCanonicalSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            ("0"..."9").contains(Character($0))
                || ("a"..."f").contains(Character($0))
        }
    }

    private static func normalizedIdentifier(_ value: String) -> String {
        value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .unicodeScalars
            .filter(CharacterSet.alphanumerics.contains)
            .map(String.init)
            .joined()
    }

    private static func isPunctuation(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy(
            CharacterSet.punctuationCharacters.contains
        )
    }

    private struct RangedWord {
        let normalized: String
        let range: Range<String.Index>
    }

    private enum OverlapDecision {
        case insufficient
        case ambiguous
        case unique(String, Int)
    }
}
