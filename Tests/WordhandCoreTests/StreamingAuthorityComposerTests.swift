import Foundation
import Testing
@testable import WordhandCore

@Suite
struct StreamingAuthorityComposerTests {
    @Test
    func composesOnlyAfterOneUniqueSixWordOverlap() {
        let decision = StreamingAuthorityComposer.compose(
            request(
                prefix: """
                Boundary alpha opens. The complete audio buffer remains authoritative.
                """,
                suffix: """
                Earlier context. The complete audio buffer remains authoritative. \
                Keep every final word.
                """
            ),
            integrity: { _ in .verified }
        )

        #expect(decision == .verified(VerifiedStreamingComposition(
            text: """
            Boundary alpha opens. The complete audio buffer remains authoritative. \
            Keep every final word.
            """,
            overlapWordCount: 6,
            reusedSampleCount: 400,
            suffixStartSample: 400,
            suffixSampleCount: 1_200
        )))
    }

    @Test
    func repeatedOverlapRequiresFullBufferFallback() {
        let phrase = "The complete audio buffer remains authoritative."
        let decision = StreamingAuthorityComposer.compose(
            request(
                prefix: "Boundary alpha opens. \(phrase)",
                suffix: """
                \(phrase) Preserve the middle instruction. \(phrase) \
                Boundary quartz closes.
                """
            ),
            integrity: { _ in .verified }
        )

        #expect(decision == .requiresFullBuffer(.ambiguousOverlap))
    }

    @Test
    func repeatedOverlapInsideStablePrefixAlsoRequiresFallback() {
        let phrase = "The complete audio buffer remains authoritative."
        let decision = StreamingAuthorityComposer.compose(
            request(
                prefix: """
                \(phrase) Preserve the middle instruction. \(phrase)
                """,
                suffix: "\(phrase) Boundary quartz closes."
            ),
            integrity: { _ in .verified }
        )

        #expect(decision == .requiresFullBuffer(.ambiguousOverlap))
    }

    @Test
    func longerUniqueContextCanDisambiguateARepeatedShortPhrase() {
        let decision = StreamingAuthorityComposer.compose(
            request(
                prefix: """
                Boundary alpha opens. The complete audio buffer remains \
                authoritative. Preserve this section. Release join: the complete \
                audio buffer remains authoritative.
                """,
                suffix: """
                The complete audio buffer remains authoritative. Preserve this \
                section. Release join, the complete audio buffer remains \
                authoritative. Boundary quartz closes.
                """
            ),
            integrity: { _ in .verified }
        )

        guard case .verified(let composition) = decision else {
            Issue.record("expected a verified composition")
            return
        }
        #expect(composition.overlapWordCount >= 8)
        #expect(composition.text.hasSuffix("Boundary quartz closes."))
        #expect(
            composition.text.components(
                separatedBy: "Preserve this section."
            ).count == 2
        )
    }

    @Test
    func punctuationAndCaseDoNotPreventAUniqueJoin() {
        let decision = StreamingAuthorityComposer.compose(
            request(
                prefix: "Keep Every Spoken Word Safely Intact!",
                suffix: """
                Earlier context; keep every spoken word safely intact. \
                Then preserve the ending.
                """
            ),
            integrity: { _ in .verified }
        )

        guard case .verified(let composition) = decision else {
            Issue.record("expected a verified composition")
            return
        }
        #expect(
            composition.text
                == "Keep Every Spoken Word Safely Intact! Then preserve the ending."
        )
        #expect(composition.overlapWordCount == 6)
    }

    @Test
    func fiveWordOverlapIsInsufficient() {
        let decision = StreamingAuthorityComposer.compose(
            request(
                prefix: "Keep every spoken word safely.",
                suffix: "Keep every spoken word safely. Preserve the ending."
            ),
            integrity: { _ in .verified }
        )

        #expect(decision == .requiresFullBuffer(.insufficientOverlap))
    }

    @Test
    func callerCannotLowerTheSixWordSafetyFloor() {
        var value = request(
            prefix: "Keep every spoken word safely.",
            suffix: "Keep every spoken word safely. Preserve the ending."
        )
        value.minimumOverlapWords = 1

        #expect(
            StreamingAuthorityComposer.compose(
                value,
                integrity: { _ in .verified }
            ) == .requiresFullBuffer(.insufficientOverlap)
        )
    }

    @Test
    func releasedPrefixIdentityMustMatchExactly() {
        var value = request()
        value.release = StreamingAuthorityRelease(
            sessionID: value.release.sessionID,
            finalSampleCount: value.release.finalSampleCount,
            stablePrefixAudioSHA256: String(repeating: "b", count: 64)
        )

        #expect(
            StreamingAuthorityComposer.compose(
                value,
                integrity: { _ in .verified }
            ) == .requiresFullBuffer(.prefixAudioMismatch)
        )
    }

    @Test
    func malformedMatchingPrefixIdentitiesStillFailClosed() {
        var value = request()
        value.release.stablePrefixAudioSHA256 = "matching-prefix"
        value.stablePrefix.audioSHA256 = "matching-prefix"

        #expect(
            StreamingAuthorityComposer.compose(
                value,
                integrity: { _ in .verified }
            ) == .requiresFullBuffer(.prefixAudioMismatch)
        )
    }

    @Test
    func lateSuffixFromAnotherSessionIsRejected() {
        var value = request()
        value.suffix = .decoded(StreamingSuffixDecode(
            sessionID: "older-session",
            text: suffixText,
            startSample: 400,
            endSample: 1_600
        ))

        #expect(
            StreamingAuthorityComposer.compose(
                value,
                integrity: { _ in .verified }
            ) == .requiresFullBuffer(.staleSession)
        )
    }

    @Test
    func invalidSuffixCoverageIsRejected() {
        var value = request()
        value.suffix = .decoded(StreamingSuffixDecode(
            sessionID: sessionID,
            text: suffixText,
            startSample: 1_100,
            endSample: 1_500
        ))

        #expect(
            StreamingAuthorityComposer.compose(
                value,
                integrity: { _ in .verified }
            ) == .requiresFullBuffer(.invalidAudioCoverage)
        )
    }

    @Test
    func suffixDecodeFailureIsExplicit() {
        var value = request()
        value.suffix = .failed(sessionID: sessionID)

        #expect(
            StreamingAuthorityComposer.compose(
                value,
                integrity: { _ in .verified }
            ) == .requiresFullBuffer(.suffixDecodeFailed)
        )
    }

    @Test
    func integrityDivergenceCannotBecomeAuthoritative() {
        let decision = StreamingAuthorityComposer.compose(
            request(),
            integrity: { _ in .diverged }
        )

        #expect(decision == .requiresFullBuffer(.integrityDiverged))
    }

    @Test
    func retainedAmbiguityFixtureForcesFallbackAtRepeatedAnchor() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Fixtures/english-ambiguous-overlap-v1.json"
            )
        let fixture = try JSONDecoder().decode(
            TranscriptionCompletenessFixture.self,
            from: Data(contentsOf: fixtureURL)
        )
        let anchor = "the complete audio buffer remains authoritative"
        let firstRange = try #require(
            fixture.reference.range(
                of: anchor,
                options: [.caseInsensitive]
            )
        )
        let prefix = String(fixture.reference[...firstRange.upperBound])
        let suffix = String(fixture.reference[firstRange.lowerBound...])

        let decision = StreamingAuthorityComposer.compose(
            request(prefix: prefix, suffix: suffix),
            integrity: { _ in .verified }
        )

        #expect(fixture.validationIssues(requireAudioIdentity: true).isEmpty)
        #expect(decision == .requiresFullBuffer(.ambiguousOverlap))
    }

    private let sessionID = "current-session"
    private let prefixText =
        "Boundary alpha opens. The complete audio buffer remains authoritative."
    private let suffixText = """
        Earlier context. The complete audio buffer remains authoritative. \
        Boundary quartz closes.
        """
    private let prefixSHA256 = String(repeating: "a", count: 64)

    private func request(
        prefix: String? = nil,
        suffix: String? = nil
    ) -> StreamingAuthorityCompositionRequest {
        StreamingAuthorityCompositionRequest(
            release: StreamingAuthorityRelease(
                sessionID: sessionID,
                finalSampleCount: 1_600,
                stablePrefixAudioSHA256: prefixSHA256
            ),
            stablePrefix: StableStreamingPrefix(
                sessionID: sessionID,
                text: prefix ?? prefixText,
                coveredThroughSample: 1_000,
                snapshotSampleCount: 1_200,
                audioSHA256: prefixSHA256
            ),
            suffix: .decoded(StreamingSuffixDecode(
                sessionID: sessionID,
                text: suffix ?? suffixText,
                startSample: 400,
                endSample: 1_600
            ))
        )
    }
}
