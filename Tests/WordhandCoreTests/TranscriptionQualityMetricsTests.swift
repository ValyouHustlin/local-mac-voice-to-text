import Testing
@testable import WordhandCore

@Suite
struct TranscriptionQualityMetricsTests {
    @Test
    func ignoresCapitalizationAndSentencePunctuation() {
        let score = TranscriptionQualityMetrics.score(
            reference: "Valyou builds Wordhand.",
            hypothesis: "valyou builds wordhand"
        )

        #expect(score?.wordEditDistance == 0)
        #expect(score?.characterEditDistance == 0)
        #expect(score?.isNormalizedExactMatch == true)
    }

    @Test
    func countsAWrongProductNameAsAWordAndSpellingError() {
        let score = TranscriptionQualityMetrics.score(
            reference: "Valyou builds Wordhand",
            hypothesis: "Value builds Wordhand"
        )

        #expect(score?.wordEditDistance == 1)
        #expect(score?.referenceWordCount == 3)
        #expect(score?.characterEditDistance == 3)
        #expect(score?.isNormalizedExactMatch == false)
    }

    @Test
    func preservesMeaningfulApostrophesAndHyphens() {
        let apostrophe = TranscriptionQualityMetrics.score(
            reference: "We'll ship it",
            hypothesis: "Well ship it"
        )
        let hyphen = TranscriptionQualityMetrics.score(
            reference: "Aaron Browne-Moore",
            hypothesis: "Aaron Browne Moore"
        )

        #expect(apostrophe?.wordEditDistance == 1)
        #expect(apostrophe?.characterEditDistance == 1)
        #expect(hyphen?.wordEditDistance == 2)
        #expect(hyphen?.characterEditDistance == 1)
    }

    @Test
    func aggregateUsesCorpusTotalsInsteadOfAveragingPercentages() {
        let short = TranscriptionQualityMetrics.score(
            reference: "one",
            hypothesis: "wrong"
        )!
        let long = TranscriptionQualityMetrics.score(
            reference: "two three four five",
            hypothesis: "two three four five"
        )!

        let aggregate = TranscriptionQualityAggregate(scores: [short, long])

        #expect(aggregate.sampleCount == 2)
        #expect(aggregate.exactMatchCount == 1)
        #expect(aggregate.wordEditDistance == 1)
        #expect(aggregate.referenceWordCount == 5)
        #expect(aggregate.wordErrorRate == 0.2)
    }

    @Test
    func emptyReferenceCannotCreateAQualityScore() {
        #expect(
            TranscriptionQualityMetrics.score(
                reference: " ... ",
                hypothesis: "hallucinated text"
            ) == nil
        )
    }
}
