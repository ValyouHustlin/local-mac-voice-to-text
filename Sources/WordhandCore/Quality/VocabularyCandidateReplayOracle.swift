import Foundation

public enum VocabularyReplayCandidateKind: String, Codable, Sendable {
    case canonicalTerm
    case pronunciationAlias
}

public enum VocabularyCandidateReplayVerdict: String, Codable, Sendable {
    case proved
    case rejected
    case inconclusive
}

public struct VocabularyCandidateReplayObservation:
    Codable,
    Equatable,
    Sendable
{
    public let recordingID: String
    public let audioSHA256: String
    public let repetition: Int
    public let isSupporting: Bool
    public let candidateKind: VocabularyReplayCandidateKind
    public let baselineQuality: TranscriptionQualityScore
    public let candidateQuality: TranscriptionQualityScore
    public let baselineNormalizedSHA256: String
    public let candidateNormalizedSHA256: String
    public let baselineContainsCandidate: Bool
    public let candidateContainsCandidate: Bool
    public let baselineContainsSpokenForm: Bool
    public let protectedSpanRegression: Bool
    public let baselineDuration: TimeInterval
    public let candidateDuration: TimeInterval

    public init(
        recordingID: String,
        audioSHA256: String,
        repetition: Int,
        isSupporting: Bool,
        candidateKind: VocabularyReplayCandidateKind = .canonicalTerm,
        baselineQuality: TranscriptionQualityScore,
        candidateQuality: TranscriptionQualityScore,
        baselineNormalizedSHA256: String,
        candidateNormalizedSHA256: String,
        baselineContainsCandidate: Bool,
        candidateContainsCandidate: Bool,
        baselineContainsSpokenForm: Bool = false,
        protectedSpanRegression: Bool,
        baselineDuration: TimeInterval,
        candidateDuration: TimeInterval
    ) {
        self.recordingID = recordingID
        self.audioSHA256 = audioSHA256
        self.repetition = repetition
        self.isSupporting = isSupporting
        self.candidateKind = candidateKind
        self.baselineQuality = baselineQuality
        self.candidateQuality = candidateQuality
        self.baselineNormalizedSHA256 = baselineNormalizedSHA256
        self.candidateNormalizedSHA256 = candidateNormalizedSHA256
        self.baselineContainsCandidate = baselineContainsCandidate
        self.candidateContainsCandidate = candidateContainsCandidate
        self.baselineContainsSpokenForm = baselineContainsSpokenForm
        self.protectedSpanRegression = protectedSpanRegression
        self.baselineDuration = baselineDuration
        self.candidateDuration = candidateDuration
    }
}

public struct VocabularyCandidateReplayDecision:
    Codable,
    Equatable,
    Sendable
{
    public let verdict: VocabularyCandidateReplayVerdict
    public let reasons: [String]
    public let supportingRecordingCount: Int
    public let corpusRecordingCount: Int
    public let repetitionCount: Int
    public let baselineWordEditDistance: Int
    public let candidateWordEditDistance: Int
    public let baselineCharacterEditDistance: Int
    public let candidateCharacterEditDistance: Int
    public let baselineExactMatchCount: Int
    public let candidateExactMatchCount: Int
    public let baselineDuration: TimeInterval
    public let candidateDuration: TimeInterval

    public init(
        verdict: VocabularyCandidateReplayVerdict,
        reasons: [String],
        supportingRecordingCount: Int,
        corpusRecordingCount: Int,
        repetitionCount: Int,
        baselineWordEditDistance: Int,
        candidateWordEditDistance: Int,
        baselineCharacterEditDistance: Int,
        candidateCharacterEditDistance: Int,
        baselineExactMatchCount: Int,
        candidateExactMatchCount: Int,
        baselineDuration: TimeInterval,
        candidateDuration: TimeInterval
    ) {
        self.verdict = verdict
        self.reasons = reasons
        self.supportingRecordingCount = supportingRecordingCount
        self.corpusRecordingCount = corpusRecordingCount
        self.repetitionCount = repetitionCount
        self.baselineWordEditDistance = baselineWordEditDistance
        self.candidateWordEditDistance = candidateWordEditDistance
        self.baselineCharacterEditDistance = baselineCharacterEditDistance
        self.candidateCharacterEditDistance = candidateCharacterEditDistance
        self.baselineExactMatchCount = baselineExactMatchCount
        self.candidateExactMatchCount = candidateExactMatchCount
        self.baselineDuration = baselineDuration
        self.candidateDuration = candidateDuration
    }
}

public enum VocabularyCandidateReplayOracle {
    public static func assess<Observations: Collection>(
        observations: Observations,
        requiredRepetitions: Int
    ) -> VocabularyCandidateReplayDecision
    where Observations.Element == VocabularyCandidateReplayObservation {
        let values = Array(observations)
        let records = Dictionary(grouping: values, by: \.recordingID)
        let supportingRecords = records.filter {
            $0.value.first?.isSupporting == true
        }
        var inconclusive: [String] = []
        var rejected: [String] = []

        if requiredRepetitions != 4 && requiredRepetitions != 6 {
            inconclusive.append("invalid_repetition_requirement")
        }
        if supportingRecords.count < 2
            || Set(supportingRecords.values.compactMap {
                $0.first?.audioSHA256
            }).count < 2
        {
            inconclusive.append("insufficient_supporting_recordings")
        }
        if records.count <= supportingRecords.count {
            inconclusive.append("missing_non_supporting_corpus")
        }
        if values.isEmpty {
            inconclusive.append("empty_corpus")
        }

        let expectedRepetitions = Set(0..<max(requiredRepetitions, 0))
        for (_, recordValues) in records {
            guard let first = recordValues.first else { continue }
            if first.recordingID.isEmpty
                || !StreamingAudioIdentity.isCanonicalSHA256(first.audioSHA256)
                || recordValues.contains(where: {
                    $0.audioSHA256 != first.audioSHA256
                        || $0.isSupporting != first.isSupporting
                        || $0.candidateKind != first.candidateKind
                        || !StreamingAudioIdentity.isCanonicalSHA256(
                            $0.baselineNormalizedSHA256
                        )
                        || !StreamingAudioIdentity.isCanonicalSHA256(
                            $0.candidateNormalizedSHA256
                        )
                        || $0.baselineDuration < 0
                        || $0.candidateDuration < 0
                        || $0.baselineQuality.referenceWordCount
                            != $0.candidateQuality.referenceWordCount
                        || $0.baselineQuality.referenceCharacterCount
                            != $0.candidateQuality.referenceCharacterCount
                })
                || Set(recordValues.map(\.repetition)) != expectedRepetitions
                || recordValues.count != expectedRepetitions.count
            {
                inconclusive.append("invalid_or_incomplete_recording_evidence")
                break
            }
        }

        let supportValues = values.filter(\.isSupporting)
        let candidateKinds = Set(values.map(\.candidateKind))
        if candidateKinds.count != 1 {
            inconclusive.append("mixed_candidate_kinds")
        }
        if supportValues.contains(where: { !$0.candidateContainsCandidate }) {
            rejected.append("candidate_missing_from_support")
        }
        if !supportValues.contains(where: { !$0.baselineContainsCandidate }) {
            rejected.append("baseline_already_contains_candidate")
        }
        let requiredWins = (requiredRepetitions * 2 + 2) / 3
        if candidateKinds == [.pronunciationAlias] {
            for (_, recordValues) in supportingRecords {
                if recordValues.count(where: \.baselineContainsSpokenForm)
                    < requiredWins
                {
                    rejected.append("alias_source_not_repeatably_observed")
                    break
                }
            }
        }
        for (_, recordValues) in supportingRecords {
            let strictWins = recordValues.count(where: {
                $0.candidateQuality.wordEditDistance
                    < $0.baselineQuality.wordEditDistance
                    && $0.candidateQuality.characterEditDistance
                        < $0.baselineQuality.characterEditDistance
            })
            if strictWins < requiredWins {
                rejected.append("support_not_repeatably_improved")
                break
            }
        }
        if values.contains(where: \.protectedSpanRegression) {
            rejected.append("protected_span_regression")
        }
        if values.contains(where: {
            $0.candidateQuality.wordEditDistance
                > $0.baselineQuality.wordEditDistance
        }) {
            rejected.append("corpus_word_regression")
        }
        if values.contains(where: {
            $0.candidateQuality.characterEditDistance
                > $0.baselineQuality.characterEditDistance
        }) {
            rejected.append("corpus_character_regression")
        }
        if values.contains(where: {
            $0.candidateQuality == $0.baselineQuality
                && $0.candidateNormalizedSHA256
                    != $0.baselineNormalizedSHA256
        }) {
            rejected.append("metric_tie_changed_corpus_text")
        }

        let baselineWord = values.reduce(0) {
            $0 + $1.baselineQuality.wordEditDistance
        }
        let candidateWord = values.reduce(0) {
            $0 + $1.candidateQuality.wordEditDistance
        }
        let baselineCharacter = values.reduce(0) {
            $0 + $1.baselineQuality.characterEditDistance
        }
        let candidateCharacter = values.reduce(0) {
            $0 + $1.candidateQuality.characterEditDistance
        }
        let baselineExact = values.count(where: {
            $0.baselineQuality.isNormalizedExactMatch
        })
        let candidateExact = values.count(where: {
            $0.candidateQuality.isNormalizedExactMatch
        })
        let baselineDuration = values.reduce(0) { $0 + $1.baselineDuration }
        let candidateDuration = values.reduce(0) { $0 + $1.candidateDuration }

        let supportBaselineWord = supportValues.reduce(0) {
            $0 + $1.baselineQuality.wordEditDistance
        }
        let supportCandidateWord = supportValues.reduce(0) {
            $0 + $1.candidateQuality.wordEditDistance
        }
        let supportBaselineCharacter = supportValues.reduce(0) {
            $0 + $1.baselineQuality.characterEditDistance
        }
        let supportCandidateCharacter = supportValues.reduce(0) {
            $0 + $1.candidateQuality.characterEditDistance
        }
        if supportCandidateWord >= supportBaselineWord
            || supportCandidateCharacter >= supportBaselineCharacter
        {
            rejected.append("no_strict_supporting_improvement")
        }
        if candidateWord > baselineWord {
            rejected.append("aggregate_word_regression")
        }
        if candidateCharacter > baselineCharacter {
            rejected.append("aggregate_character_regression")
        }
        if candidateExact < baselineExact {
            rejected.append("exact_match_regression")
        }
        if candidateDuration - baselineDuration > 0.100
            && candidateDuration > baselineDuration * 1.05
        {
            rejected.append("latency_regression")
        }

        let structuralReasons = Array(Set(inconclusive)).sorted()
        let rejectionReasons = Array(Set(rejected)).sorted()
        let verdict: VocabularyCandidateReplayVerdict
        let reasons: [String]
        if !structuralReasons.isEmpty {
            verdict = .inconclusive
            reasons = structuralReasons
        } else if !rejectionReasons.isEmpty {
            verdict = .rejected
            reasons = rejectionReasons
        } else {
            verdict = .proved
            reasons = []
        }

        return VocabularyCandidateReplayDecision(
            verdict: verdict,
            reasons: reasons,
            supportingRecordingCount: supportingRecords.count,
            corpusRecordingCount: records.count,
            repetitionCount: requiredRepetitions,
            baselineWordEditDistance: baselineWord,
            candidateWordEditDistance: candidateWord,
            baselineCharacterEditDistance: baselineCharacter,
            candidateCharacterEditDistance: candidateCharacter,
            baselineExactMatchCount: baselineExact,
            candidateExactMatchCount: candidateExact,
            baselineDuration: baselineDuration,
            candidateDuration: candidateDuration
        )
    }
}
