import Foundation

public enum TranscriptionIntegrityIssue: Hashable, Sendable {
    case leadingConditioningArtifact
    case activeAudioAfterDecodedEnding
}

public enum TailRecoveryDecision: Equatable, Sendable {
    case covered
    case merged(String)
    case requiresFullRetry
}

public enum TranscriptionIntegrityGuard {
    public static func issues(
        in text: String,
        conditionedTerms: [String],
        audio: [Float],
        sampleRate: Int,
        lastDecodedSecond: TimeInterval? = nil
    ) -> Set<TranscriptionIntegrityIssue> {
        var result = Set<TranscriptionIntegrityIssue>()
        if hasLeadingConditioningArtifact(
            text,
            conditionedTerms: conditionedTerms
        ) {
            result.insert(.leadingConditioningArtifact)
        }

        // Whisper can report a segment boundary at the end of a model window
        // even when its text stopped early. Never let timing suppress the
        // observed unfinished-text safeguard.
        if !hasTerminalPunctuation(text),
           hasActiveTail(audio, sampleRate: sampleRate)
        {
            result.insert(.activeAudioAfterDecodedEnding)
        } else if let lastDecodedSecond, lastDecodedSecond > 0,
                  hasSustainedActivityAfterDecodedEnding(
                      audio,
                      sampleRate: sampleRate,
                      lastDecodedSecond: lastDecodedSecond
                  )
        {
            // Timing adds coverage for a decoder that produced plausible
            // punctuation before later speech; it is never the sole reason to
            // consider an unpunctuated ending complete.
            result.insert(.activeAudioAfterDecodedEnding)
        }
        return result
    }

    /// Long-form Whisper decodes can omit late speech while still reporting a
    /// final segment boundary at the end of the audio. Require an independent
    /// tail decode whenever a recording is long enough and contains sustained
    /// activity in its final window, regardless of the decoder timestamps.
    public static func needsIndependentTailAudit(
        audio: [Float],
        sampleRate: Int
    ) -> Bool {
        guard sampleRate > 0,
              audio.count >= sampleRate * minimumTailAuditDurationSeconds
        else {
            return false
        }
        let tailCount = min(
            audio.count,
            sampleRate * tailAuditWindowSeconds
        )
        return hasSustainedActivity(
            audio.suffix(tailCount),
            windowSize: max(1, Int(0.05 * Double(sampleRate)))
        )
    }

    public static func select(
        primary: String,
        retry: String,
        issues: Set<TranscriptionIntegrityIssue>,
        conditionedTerms: [String],
        requireMateriallyLongerTail: Bool = false
    ) -> String {
        let primaryWordCount = wordCount(primary)
        let retryWordCount = wordCount(retry)

        if issues.contains(.leadingConditioningArtifact),
           !hasLeadingConditioningArtifact(
               retry,
               conditionedTerms: conditionedTerms
           ),
           retryWordCount >= max(1, primaryWordCount - 4),
           lexicallyAligned(
               reference: bodyAfterLeadingDelimiter(primary) ?? primary,
               candidate: retry
           )
        {
            return retry
        }

        if issues.contains(.activeAudioAfterDecodedEnding) {
            let materiallyLonger = retryWordCount >= primaryWordCount + 2
            let equallyComplete =
                hasTerminalPunctuation(retry)
                && retryWordCount >= primaryWordCount
            let acceptablyComplete =
                materiallyLonger
                || (!requireMateriallyLongerTail && equallyComplete)
            if acceptablyComplete,
               lexicallyAligned(reference: primary, candidate: retry)
            {
                return retry
            }
        }

        return primary
    }

    /// Joins a short, prompt-free decode of the recording tail onto the
    /// authoritative primary result. A four-word exact normalized overlap is
    /// required so unrelated recovery text cannot be appended.
    public static func mergeTail(
        primary: String,
        recovery: String,
        minimumOverlapWords: Int = 4
    ) -> String? {
        guard case .merged(let merged) = reconcileTail(
            primary: primary,
            recovery: recovery,
            minimumOverlapWords: minimumOverlapWords
        ) else {
            return nil
        }
        return merged
    }

    /// Determines whether an independently decoded tail is already represented,
    /// can be appended safely, or proves that the complete recording needs a
    /// prompt-free retry.
    public static func reconcileTail(
        primary: String,
        recovery: String,
        minimumOverlapWords: Int = 4
    ) -> TailRecoveryDecision {
        guard minimumOverlapWords > 0 else {
            return .requiresFullRetry
        }
        let primaryWords = rangedWords(primary)
        let recoveryWords = rangedWords(recovery)
        let maximumOverlap = min(primaryWords.count, recoveryWords.count)
        guard maximumOverlap >= minimumOverlapWords else {
            return .requiresFullRetry
        }

        for overlapCount in stride(
            from: maximumOverlap,
            through: minimumOverlapWords,
            by: -1
        ) {
            let primaryStart = primaryWords.count - overlapCount
            let maximumRecoveryStart = recoveryWords.count - overlapCount
            guard maximumRecoveryStart >= 0 else { continue }

            let matchingStarts = (0...maximumRecoveryStart).filter {
                recoveryStart in
                (0..<overlapCount).allSatisfy { offset in
                    primaryWords[primaryStart + offset].normalized
                        == recoveryWords[recoveryStart + offset].normalized
                }
            }
            guard !matchingStarts.isEmpty else { continue }
            guard matchingStarts.count == 1,
                  let recoveryStart = matchingStarts.first
            else {
                return .requiresFullRetry
            }

            let recoveryEnd = recoveryStart + overlapCount
            if recoveryEnd == recoveryWords.count {
                return recoveryStart == 0 ? .covered : .requiresFullRetry
            }
            let matchedWord = recoveryWords[
                recoveryEnd - 1
            ]
            var remainder = String(
                recovery[matchedWord.range.upperBound...]
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !remainder.isEmpty else { continue }

            let prefix = primary.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !prefix.isEmpty else { return .merged(recovery) }

            if let prefixLast = prefix.last,
               let remainderFirst = remainder.first,
               isPunctuation(prefixLast),
               isPunctuation(remainderFirst),
               prefixLast == remainderFirst
            {
                remainder.removeFirst()
                remainder = remainder.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                guard !remainder.isEmpty else { return .covered }
                return .merged(prefix + " " + remainder)
            }

            let separator = remainder.first.map {
                isPunctuation($0) ? "" : " "
            } ?? ""
            return .merged(prefix + separator + remainder)
        }
        return .requiresFullRetry
    }

    private static func hasLeadingConditioningArtifact(
        _ text: String,
        conditionedTerms: [String]
    ) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        guard let boundary = leadingDelimiterRange(in: trimmed)?.lowerBound else {
            return false
        }

        let prefix = String(trimmed[..<boundary])
        let normalizedPrefix = normalizedIdentifier(prefix)
        guard normalizedPrefix.count >= 6 else { return false }

        return conditionedTerms.contains { term in
            let normalizedTerm = normalizedIdentifier(term)
            guard normalizedTerm.count > normalizedPrefix.count else {
                return false
            }
            let minimumPrefixLength = max(6, normalizedTerm.count / 2)
            return normalizedPrefix.count >= minimumPrefixLength
                && normalizedTerm.hasPrefix(normalizedPrefix)
        }
    }

    private static func hasTerminalPunctuation(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return true }
        return ".!?…)]}\"”’'".contains(last)
    }

    private static func hasActiveTail(
        _ audio: [Float],
        sampleRate: Int
    ) -> Bool {
        guard sampleRate > 0, !audio.isEmpty else { return false }
        let tailCount = min(audio.count, sampleRate * 2)
        guard tailCount > 0 else { return false }
        let tail = audio.suffix(tailCount)
        var sumOfSquares: Double = 0
        var peak: Float = 0
        for sample in tail {
            sumOfSquares += Double(sample * sample)
            peak = max(peak, abs(sample))
        }
        let rms = sqrt(sumOfSquares / Double(tailCount))
        return rms >= 0.003 || peak >= 0.02
    }

    private static func hasSustainedActivityAfterDecodedEnding(
        _ audio: [Float],
        sampleRate: Int,
        lastDecodedSecond: TimeInterval
    ) -> Bool {
        guard sampleRate > 0, !audio.isEmpty, lastDecodedSecond.isFinite else {
            return false
        }

        // Whisper segment boundaries are not sample-accurate. Leave 180 ms of
        // tolerance after the reported boundary and ignore the final 80 ms
        // capture tail that Wordhand intentionally records after key release.
        let toleranceSamples = Int(0.18 * Double(sampleRate))
        let captureTailSamples = Int(0.08 * Double(sampleRate))
        let decodedEndSample = max(
            0,
            Int(lastDecodedSecond * Double(sampleRate))
        )
        let analysisStart = min(
            audio.count,
            decodedEndSample + toleranceSamples
        )
        let analysisEnd = max(
            analysisStart,
            audio.count - captureTailSamples
        )

        let windowSize = max(1, Int(0.05 * Double(sampleRate)))
        guard analysisEnd - analysisStart >= windowSize * 2 else {
            return false
        }

        var consecutiveActiveWindows = 0
        var windowStart = analysisStart
        while windowStart < analysisEnd {
            let windowEnd = min(windowStart + windowSize, analysisEnd)
            let window = audio[windowStart..<windowEnd]
            var sumOfSquares: Double = 0
            var peak: Float = 0
            for sample in window {
                sumOfSquares += Double(sample * sample)
                peak = max(peak, abs(sample))
            }
            let rms = sqrt(sumOfSquares / Double(window.count))
            let active = rms >= 0.004 && peak >= 0.02
            if active {
                consecutiveActiveWindows += 1
                if consecutiveActiveWindows >= 2 {
                    return true
                }
            } else {
                consecutiveActiveWindows = 0
            }
            windowStart = windowEnd
        }
        return false
    }

    private static func hasSustainedActivity<Audio: Collection>(
        _ audio: Audio,
        windowSize: Int
    ) -> Bool where Audio.Element == Float {
        guard windowSize > 0 else { return false }
        guard audio.count >= windowSize * 2 else { return false }

        var consecutiveActiveWindows = 0
        var window: [Float] = []
        window.reserveCapacity(windowSize)
        for sample in audio {
            window.append(sample)
            guard window.count == windowSize else { continue }

            var sumOfSquares: Double = 0
            var peak: Float = 0
            for value in window {
                sumOfSquares += Double(value * value)
                peak = max(peak, abs(value))
            }
            let rms = sqrt(sumOfSquares / Double(window.count))
            if rms >= 0.004 && peak >= 0.02 {
                consecutiveActiveWindows += 1
                if consecutiveActiveWindows >= 2 {
                    return true
                }
            } else {
                consecutiveActiveWindows = 0
            }
            window.removeAll(keepingCapacity: true)
        }
        return false
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    private static func bodyAfterLeadingDelimiter(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = leadingDelimiterRange(in: trimmed) else { return nil }
        return String(trimmed[range.upperBound...])
    }

    private static func leadingDelimiterRange(
        in text: String
    ) -> Range<String.Index>? {
        ["- ", "— ", ": "]
            .compactMap { text.range(of: $0) }
            .min { $0.lowerBound < $1.lowerBound }
    }

    private static func lexicallyAligned(
        reference: String,
        candidate: String
    ) -> Bool {
        let referenceWords = normalizedWords(reference)
        let candidateWords = normalizedWords(candidate)
        guard !referenceWords.isEmpty, !candidateWords.isEmpty else {
            return false
        }

        var candidateCounts = Dictionary(
            candidateWords.map { ($0, 1) },
            uniquingKeysWith: +
        )
        let sharedCount = referenceWords.reduce(into: 0) { count, word in
            guard let available = candidateCounts[word], available > 0 else {
                return
            }
            count += 1
            candidateCounts[word] = available - 1
        }
        return Double(sharedCount) / Double(referenceWords.count) >= 0.7
    }

    private static func normalizedWords(_ value: String) -> [String] {
        value
            .split(whereSeparator: \.isWhitespace)
            .map { normalizedIdentifier(String($0)) }
            .filter { !$0.isEmpty }
    }

    private struct RangedWord {
        let normalized: String
        let range: Range<String.Index>
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

    private static let punctuationCharacters = CharacterSet.punctuationCharacters

    private static func isPunctuation(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy(punctuationCharacters.contains)
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

    private static let minimumTailAuditDurationSeconds = 30
    private static let tailAuditWindowSeconds = 20
}
