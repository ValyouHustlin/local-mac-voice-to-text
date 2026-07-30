import Testing
@testable import WordhandCore

@Suite
struct VocabularyCandidateReplayOracleTests {
    @Test
    func provesOnlyRepeatableSourceImprovementWithoutCorpusRegression() throws {
        let observations = try makeProofObservations()

        let decision = VocabularyCandidateReplayOracle.assess(
            observations: observations,
            requiredRepetitions: 4
        )

        #expect(decision.verdict == .proved)
        #expect(decision.reasons.isEmpty)
        #expect(decision.supportingRecordingCount == 2)
        #expect(decision.corpusRecordingCount == 3)
        #expect(decision.baselineWordEditDistance == 16)
        #expect(decision.candidateWordEditDistance == 0)
    }

    @Test
    func corpusRegressionRejectsARepeatableSourceWin() throws {
        var observations = try makeProofObservations()
        observations[2] = try observation(
            id: "control",
            audio: String(repeating: "c", count: 64),
            repetition: 0,
            supporting: false,
            baseline: "ordinary control sentence",
            candidate: "ordinary sentence"
        )

        let decision = VocabularyCandidateReplayOracle.assess(
            observations: observations,
            requiredRepetitions: 4
        )

        #expect(decision.verdict == .rejected)
        #expect(decision.reasons.contains("corpus_word_regression"))
    }

    @Test
    func missingIndependentEvidenceIsInconclusive() throws {
        let observations = try makeProofObservations().filter {
            $0.recordingID != "support-b"
        }

        let decision = VocabularyCandidateReplayOracle.assess(
            observations: observations,
            requiredRepetitions: 4
        )

        #expect(decision.verdict == .inconclusive)
        #expect(decision.reasons.contains("insufficient_supporting_recordings"))
    }

    @Test
    func protectedLossRejectsEvenWhenAggregateMetricsImprove() throws {
        var observations = try makeProofObservations()
        observations[0] = VocabularyCandidateReplayObservation(
            recordingID: observations[0].recordingID,
            audioSHA256: observations[0].audioSHA256,
            repetition: observations[0].repetition,
            isSupporting: true,
            baselineQuality: observations[0].baselineQuality,
            candidateQuality: observations[0].candidateQuality,
            baselineNormalizedSHA256: observations[0].baselineNormalizedSHA256,
            candidateNormalizedSHA256: observations[0].candidateNormalizedSHA256,
            baselineContainsCandidate: false,
            candidateContainsCandidate: true,
            protectedSpanRegression: true,
            baselineDuration: 1,
            candidateDuration: 1
        )

        let decision = VocabularyCandidateReplayOracle.assess(
            observations: observations,
            requiredRepetitions: 4
        )

        #expect(decision.verdict == .rejected)
        #expect(decision.reasons.contains("protected_span_regression"))
    }

    @Test
    func verdictDoesNotDependOnInputOrder() throws {
        let observations = try makeProofObservations()
        let forward = VocabularyCandidateReplayOracle.assess(
            observations: observations,
            requiredRepetitions: 4
        )
        let reversed = VocabularyCandidateReplayOracle.assess(
            observations: observations.reversed(),
            requiredRepetitions: 4
        )

        #expect(forward == reversed)
    }

    @Test
    func metricTiedChangedTextRejectsOnASupportingRecording() throws {
        var observations = try makeProofObservations()
        let original = observations[0]
        observations[0] = VocabularyCandidateReplayObservation(
            recordingID: original.recordingID,
            audioSHA256: original.audioSHA256,
            repetition: original.repetition,
            isSupporting: original.isSupporting,
            baselineQuality: original.baselineQuality,
            candidateQuality: original.baselineQuality,
            baselineNormalizedSHA256: original.baselineNormalizedSHA256,
            candidateNormalizedSHA256: String(repeating: "f", count: 64),
            baselineContainsCandidate: false,
            candidateContainsCandidate: true,
            protectedSpanRegression: false,
            baselineDuration: 1,
            candidateDuration: 1
        )

        let decision = VocabularyCandidateReplayOracle.assess(
            observations: observations,
            requiredRepetitions: 4
        )

        #expect(decision.verdict == .rejected)
        #expect(decision.reasons.contains("metric_tie_changed_corpus_text"))
    }

    @Test
    func pronunciationAliasRequiresObservedSourceAndProvesDecodeImprovement()
        throws
    {
        let observations = try aliasObservations()

        let decision = VocabularyCandidateReplayOracle.assess(
            observations: observations,
            requiredRepetitions: 4
        )

        #expect(decision.verdict == .proved)
        #expect(decision.reasons.isEmpty)
    }

    @Test
    func pronunciationAliasWithoutRepeatableSourceEvidenceRejects() throws {
        var observations = try aliasObservations()
        for index in observations.indices
        where observations[index].recordingID == "support-a"
            && observations[index].repetition > 1
        {
            let original = observations[index]
            observations[index] = VocabularyCandidateReplayObservation(
                recordingID: original.recordingID,
                audioSHA256: original.audioSHA256,
                repetition: original.repetition,
                isSupporting: true,
                candidateKind: .pronunciationAlias,
                baselineQuality: original.baselineQuality,
                candidateQuality: original.candidateQuality,
                baselineNormalizedSHA256: original.baselineNormalizedSHA256,
                candidateNormalizedSHA256: original.candidateNormalizedSHA256,
                baselineContainsCandidate: false,
                candidateContainsCandidate: true,
                baselineContainsSpokenForm: false,
                protectedSpanRegression: false,
                baselineDuration: 1,
                candidateDuration: 1
            )
        }

        let decision = VocabularyCandidateReplayOracle.assess(
            observations: observations,
            requiredRepetitions: 4
        )

        #expect(decision.verdict == .rejected)
        #expect(decision.reasons.contains("alias_source_not_repeatably_observed"))
    }

    private func makeProofObservations()
        throws -> [VocabularyCandidateReplayObservation]
    {
        var result: [VocabularyCandidateReplayObservation] = []
        for repetition in 0..<4 {
            result.append(try observation(
                id: "support-a",
                audio: String(repeating: "a", count: 64),
                repetition: repetition,
                supporting: true,
                baseline: "please call brown more today",
                candidate: "please call Browne-Moore today"
            ))
            result.append(try observation(
                id: "support-b",
                audio: String(repeating: "b", count: 64),
                repetition: repetition,
                supporting: true,
                baseline: "email brown more tomorrow",
                candidate: "email Browne-Moore tomorrow"
            ))
            let controlScore = try #require(
                TranscriptionQualityMetrics.score(
                    reference: "ordinary control sentence",
                    hypothesis: "ordinary control sentence"
                )
            )
            result.append(VocabularyCandidateReplayObservation(
                recordingID: "control",
                audioSHA256: String(repeating: "c", count: 64),
                repetition: repetition,
                isSupporting: false,
                candidateKind: .canonicalTerm,
                baselineQuality: controlScore,
                candidateQuality: controlScore,
                baselineNormalizedSHA256: String(repeating: "d", count: 64),
                candidateNormalizedSHA256: String(repeating: "d", count: 64),
                baselineContainsCandidate: false,
                candidateContainsCandidate: false,
                baselineContainsSpokenForm: false,
                protectedSpanRegression: false,
                baselineDuration: 1,
                candidateDuration: 1
            ))
        }
        return result
    }

    private func aliasObservations()
        throws -> [VocabularyCandidateReplayObservation]
    {
        var result: [VocabularyCandidateReplayObservation] = []
        for repetition in 0..<4 {
            for (id, audio, prefix) in [
                ("support-a", "a", "please call"),
                ("support-b", "b", "email"),
            ] {
                let reference = "\(prefix) Aaron Browne-Moore today"
                let baseline = "\(prefix) Aaron Brown more today"
                let candidate = reference
                result.append(VocabularyCandidateReplayObservation(
                    recordingID: id,
                    audioSHA256: String(repeating: audio, count: 64),
                    repetition: repetition,
                    isSupporting: true,
                    candidateKind: .pronunciationAlias,
                    baselineQuality: try #require(
                        TranscriptionQualityMetrics.score(
                            reference: reference,
                            hypothesis: baseline
                        )
                    ),
                    candidateQuality: try #require(
                        TranscriptionQualityMetrics.score(
                            reference: reference,
                            hypothesis: candidate
                        )
                    ),
                    baselineNormalizedSHA256: String(repeating: "d", count: 64),
                    candidateNormalizedSHA256: String(repeating: "e", count: 64),
                    baselineContainsCandidate: false,
                    candidateContainsCandidate: true,
                    baselineContainsSpokenForm: true,
                    protectedSpanRegression: false,
                    baselineDuration: 1,
                    candidateDuration: 1
                ))
            }
            let controlScore = try #require(
                TranscriptionQualityMetrics.score(
                    reference: "ordinary control sentence",
                    hypothesis: "ordinary control sentence"
                )
            )
            result.append(VocabularyCandidateReplayObservation(
                recordingID: "control",
                audioSHA256: String(repeating: "c", count: 64),
                repetition: repetition,
                isSupporting: false,
                candidateKind: .pronunciationAlias,
                baselineQuality: controlScore,
                candidateQuality: controlScore,
                baselineNormalizedSHA256: String(repeating: "d", count: 64),
                candidateNormalizedSHA256: String(repeating: "d", count: 64),
                baselineContainsCandidate: false,
                candidateContainsCandidate: false,
                baselineContainsSpokenForm: false,
                protectedSpanRegression: false,
                baselineDuration: 1,
                candidateDuration: 1
            ))
        }
        return result
    }

    private func observation(
        id: String,
        audio: String,
        repetition: Int,
        supporting: Bool,
        baseline: String,
        candidate: String
    ) throws -> VocabularyCandidateReplayObservation {
        let reference = supporting
            ? (id == "support-a"
                ? "please call Browne-Moore today"
                : "email Browne-Moore tomorrow")
            : "ordinary control sentence"
        return VocabularyCandidateReplayObservation(
            recordingID: id,
            audioSHA256: audio,
            repetition: repetition,
            isSupporting: supporting,
            baselineQuality: try #require(TranscriptionQualityMetrics.score(
                reference: reference,
                hypothesis: baseline
            )),
            candidateQuality: try #require(TranscriptionQualityMetrics.score(
                reference: reference,
                hypothesis: candidate
            )),
            baselineNormalizedSHA256: String(repeating: "d", count: 64),
            candidateNormalizedSHA256: baseline == candidate
                ? String(repeating: "d", count: 64)
                : String(repeating: "e", count: 64),
            baselineContainsCandidate: false,
            candidateContainsCandidate: supporting,
            protectedSpanRegression: false,
            baselineDuration: 1,
            candidateDuration: 1
        )
    }
}
