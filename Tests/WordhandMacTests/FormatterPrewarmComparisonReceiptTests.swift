import Foundation
import Testing
import WordhandCore
@testable import wordhand

@Suite(.serialized)
struct FormatterPrewarmComparisonReceiptTests {
    private struct Summary: Codable {
        let caseCount: Int
        let iterationCount: Int
        let comparisonCount: Int
        let everyOutputByteIdentical: Bool
        let candidatePreparedFirstPassCount: Int
        let candidateEligibleFirstPassCount: Int
        let baselineRewriteCount: Int
        let candidateRewriteCount: Int
        let baselineMedianSeconds: Double
        let candidateMedianSeconds: Double
        let baselineP95Seconds: Double
        let candidateP95Seconds: Double
        let medianImprovementFraction: Double
        let p95ImprovementFraction: Double
        let promoted: Bool
    }

    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment[
                "WORDHAND_FORMATTER_PREWARM_RECEIPT"
            ] == "1"
        )
    )
    func retainedLocalHistoryRequiresExactOutputAndMaterialLatencyWin() async throws {
        let environment = ProcessInfo.processInfo.environment
        let requestedCount = max(
            1,
            Int(environment["WORDHAND_FORMATTER_PREWARM_CASES"] ?? "27") ?? 27
        )
        let iterations = max(
            1,
            Int(environment["WORDHAND_FORMATTER_PREWARM_ITERATIONS"] ?? "4") ?? 4
        )
        let records = try TranscriptHistoryStore(
            fileURL: TranscriptHistoryStore.defaultFileURL()
        ).records(limit: requestedCount)
        #expect(records.count == requestedCount)

        let settings = try SettingsStore(
            fileURL: SettingsStore.defaultFileURL()
        ).load()
        let dictionaryEntries =
            (try? DictionaryStore(
                fileURL: DictionaryStore.defaultFileURL()
            ).load().entries) ?? []
        let baselineRewriter = FoundationModelTranscriptRewriter(
            preparationMode: .legacyDynamicInstructions,
            recordsRuns: true
        )
        let candidateRewriter = FoundationModelTranscriptRewriter(
            preparationMode: .stablePromptConstraints,
            recordsRuns: true
        )
        let baseline = AppAwareTranscriptProcessor(
            dictionaryProcessor: MutableTranscriptProcessor(
                dictionaryEntries: dictionaryEntries
            ),
            profile: settings.formattingProfile,
            applicationRules: settings.applicationFormattingRules,
            performanceMode: .maximum,
            rewriter: baselineRewriter
        )
        let candidate = AppAwareTranscriptProcessor(
            dictionaryProcessor: MutableTranscriptProcessor(
                dictionaryEntries: dictionaryEntries
            ),
            profile: settings.formattingProfile,
            applicationRules: settings.applicationFormattingRules,
            performanceMode: .maximum,
            rewriter: candidateRewriter
        )

        var everyOutputByteIdentical = true
        var baselineSeconds: [Double] = []
        var candidateSeconds: [Double] = []
        var candidatePreparedFirstPassCount = 0
        var candidateEligibleFirstPassCount = 0
        var baselineRewriteCount = 0
        var candidateRewriteCount = 0

        for iteration in 0..<iterations {
            for (caseIndex, record) in records.enumerated() {
                let baselineContext = baseline.context(for: record.target)
                let candidateContext = candidate.context(for: record.target)
                await baseline.prepare(context: baselineContext)
                await candidate.prepare(context: candidateContext)
                try await Task.sleep(for: .seconds(1))

                let baselineRunsBefore = await baselineRewriter.runs().count
                let candidateRunsBefore = await candidateRewriter.runs().count
                let candidateFirst = (iteration + caseIndex).isMultiple(of: 2)

                let first = candidateFirst
                    ? await Self.measure(
                        processor: candidate,
                        text: record.rawText,
                        context: candidateContext
                    )
                    : await Self.measure(
                        processor: baseline,
                        text: record.rawText,
                        context: baselineContext
                    )
                let second = candidateFirst
                    ? await Self.measure(
                        processor: baseline,
                        text: record.rawText,
                        context: baselineContext
                    )
                    : await Self.measure(
                        processor: candidate,
                        text: record.rawText,
                        context: candidateContext
                    )

                let baselineResult = candidateFirst ? second : first
                let candidateResult = candidateFirst ? first : second
                everyOutputByteIdentical =
                    everyOutputByteIdentical
                    && baselineResult.text == candidateResult.text
                baselineSeconds.append(baselineResult.seconds)
                candidateSeconds.append(candidateResult.seconds)

                let baselineRuns = await baselineRewriter.runs()
                let candidateRuns = await candidateRewriter.runs()
                let newBaselineRuns = baselineRuns.dropFirst(baselineRunsBefore)
                let newCandidateRuns = candidateRuns.dropFirst(candidateRunsBefore)
                baselineRewriteCount += newBaselineRuns.count
                candidateRewriteCount += newCandidateRuns.count
                if let firstCandidateRun = newCandidateRuns.first {
                    candidateEligibleFirstPassCount += 1
                    if firstCandidateRun.preparedSessionHit {
                        candidatePreparedFirstPassCount += 1
                    }
                }
            }
        }

        let baselineMedian = Self.percentile(baselineSeconds, fraction: 0.5)
        let candidateMedian = Self.percentile(candidateSeconds, fraction: 0.5)
        let baselineP95 = Self.percentile(baselineSeconds, fraction: 0.95)
        let candidateP95 = Self.percentile(candidateSeconds, fraction: 0.95)
        let medianImprovement = Self.improvement(
            baseline: baselineMedian,
            candidate: candidateMedian
        )
        let p95Improvement = Self.improvement(
            baseline: baselineP95,
            candidate: candidateP95
        )
        let promoted =
            everyOutputByteIdentical
            && candidatePreparedFirstPassCount == candidateEligibleFirstPassCount
            && candidateEligibleFirstPassCount == records.count * iterations
            && candidateRewriteCount <= baselineRewriteCount
            && medianImprovement >= 0.15
            && candidateP95 <= baselineP95
        let summary = Summary(
            caseCount: records.count,
            iterationCount: iterations,
            comparisonCount: baselineSeconds.count,
            everyOutputByteIdentical: everyOutputByteIdentical,
            candidatePreparedFirstPassCount: candidatePreparedFirstPassCount,
            candidateEligibleFirstPassCount: candidateEligibleFirstPassCount,
            baselineRewriteCount: baselineRewriteCount,
            candidateRewriteCount: candidateRewriteCount,
            baselineMedianSeconds: baselineMedian,
            candidateMedianSeconds: candidateMedian,
            baselineP95Seconds: baselineP95,
            candidateP95Seconds: candidateP95,
            medianImprovementFraction: medianImprovement,
            p95ImprovementFraction: p95Improvement,
            promoted: promoted
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        print(String(decoding: try encoder.encode(summary), as: UTF8.self))

        #expect(everyOutputByteIdentical)
        #expect(
            candidatePreparedFirstPassCount
                == candidateEligibleFirstPassCount
        )
        #expect(candidateEligibleFirstPassCount == records.count * iterations)
        #expect(candidateRewriteCount <= baselineRewriteCount)
        #expect(medianImprovement >= 0.15)
        #expect(candidateP95 <= baselineP95)
        #expect(promoted)
    }

    private static func measure(
        processor: AppAwareTranscriptProcessor,
        text: String,
        context: TranscriptProcessingContext
    ) async -> (text: String, seconds: Double) {
        let started = ProcessInfo.processInfo.systemUptime
        let output = await processor.process(text, context: context)
        return (
            output,
            ProcessInfo.processInfo.systemUptime - started
        )
    }

    private static func percentile(
        _ values: [Double],
        fraction: Double
    ) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = Int(
            (Double(sorted.count - 1) * fraction).rounded(.up)
        )
        return sorted[index]
    }

    private static func improvement(
        baseline: Double,
        candidate: Double
    ) -> Double {
        guard baseline > 0 else { return 0 }
        return (baseline - candidate) / baseline
    }
}
