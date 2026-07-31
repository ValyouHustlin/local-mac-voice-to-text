import ArgumentParser
import CryptoKit
import Foundation
import WhisperKit
import WordhandCore

extension Models {
    struct TailWindowCompare: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "tail-window-compare",
            abstract: """
            Compare fixed 20s and 30s tail audits on identical local audio.
            """
        )

        @Argument(help: "Path to a retained local audio file.")
        var audioPath: String

        @Option(
            name: .long,
            help: "Protected completeness fixture for promotion evidence."
        )
        var fixture: String?

        @Flag(
            name: .long,
            help: "Use a read-only snapshot of the current local dictionary."
        )
        var userDictionary: Bool = false

        @Option(name: .long, help: "Model id. Defaults to the recommended model.")
        var model: String?

        @Option(name: .long, help: "Balanced paired runs: 2, 4, 6, 8, or 10.")
        var iterations: Int = 4

        @Flag(name: .long, help: "Emit the transcript-free JSON report.")
        var json: Bool = false

        func validate() throws {
            guard (2...10).contains(iterations),
                  iterations.isMultiple(of: 2)
            else {
                throw ValidationError(
                    "--iterations must be an even number from 2 through 10."
                )
            }
            guard (fixture != nil) != userDictionary else {
                throw ValidationError(
                    "Choose exactly one evidence source: --fixture or "
                        + "--user-dictionary."
                )
            }
        }

        func run() throws {
            let modelID = model ?? ModelRegistry.recommended()?.id
            guard let modelID,
                  let selectedModel = ModelRegistry.find(modelID)
            else {
                throw ValidationError("unknown model: \(model ?? "none")")
            }
            guard let engineID = selectedModel.whisperKitID,
                  WhisperModelStorage.localModelFolder(
                      modelID: engineID,
                      downloadBase: WhisperModelStorage.defaultDownloadBase()
                  ) != nil
            else {
                throw ValidationError(
                    "\(selectedModel.id) is not completely cached; this "
                        + "comparison never downloads a model."
                )
            }

            let audioURL = URL(
                fileURLWithPath:
                    NSString(string: audioPath).expandingTildeInPath
            )
            let audioData = try Data(contentsOf: audioURL)
            let audioSHA256 = Self.sha256(audioData)
            let audio = try AudioProcessor.loadAudioAsFloatArray(
                fromPath: audioURL.path
            )
            guard audio.count > 30 * Int(AudioCapture.targetSampleRate) else {
                throw ValidationError(
                    "audio must exceed 30 seconds for this comparison"
                )
            }

            let fixtureEvidence: TailWindowFixtureEvidence?
            let vocabularyEntries: [DictionaryEntry]
            if let fixture {
                let fixtureURL = URL(
                    fileURLWithPath:
                        NSString(string: fixture).expandingTildeInPath
                )
                let fixtureData = try Data(contentsOf: fixtureURL)
                let decoded = try JSONDecoder().decode(
                    TranscriptionCompletenessFixture.self,
                    from: fixtureData
                )
                let issues = decoded.validationIssues(
                    requireAudioIdentity: true
                )
                guard issues.isEmpty else {
                    throw ValidationError(issues.joined(separator: "; "))
                }
                guard decoded.audioSHA256 == audioSHA256,
                      decoded.sampleCount == audio.count,
                      decoded.sampleRate == Int(AudioCapture.targetSampleRate)
                else {
                    throw ValidationError(
                        "audio identity does not match the fixture"
                    )
                }
                fixtureEvidence = TailWindowFixtureEvidence(
                    fixture: decoded,
                    sha256: Self.sha256(fixtureData)
                )
                vocabularyEntries = decoded.vocabularyTerms.map {
                    DictionaryEntry(spokenForm: $0, replacement: $0)
                }
            } else {
                fixtureEvidence = nil
                vocabularyEntries = try Self.readOnlyDictionarySnapshot()
            }
            let vocabulary = DictionaryVocabularySource(
                entries: vocabularyEntries
            )
            let promptSnapshot = vocabulary.promptSnapshot()
            let vocabularyEncoder = JSONEncoder()
            vocabularyEncoder.outputFormatting = [.sortedKeys]
            let vocabularyData = try vocabularyEncoder.encode(
                TailWindowVocabularyFingerprint(
                    canonicalTerms: promptSnapshot.canonicalTerms,
                    pronunciationAssociations:
                        promptSnapshot.pronunciationAssociations.map {
                            TailWindowPronunciationFingerprint(
                                spokenForm: $0.spokenForm,
                                canonicalTerm: $0.canonicalTerm
                            )
                        }
                )
            )

            let transcriber = WhisperKitTranscriber(
                model: selectedModel,
                vocabulary: vocabulary
            )
            let box = TailWindowCompareResultBox()
            let semaphore = DispatchSemaphore(value: 0)
            let iterationCount = iterations
            Task.detached {
                do {
                    try await transcriber.warmUpRequiringCachedModel()
                    _ = try await transcriber.compareTailAuditWindows(
                        audio: audio,
                        orderedWindowSeconds: [20, 30]
                    )
                    _ = try await transcriber.compareTailAuditWindows(
                        audio: audio,
                        orderedWindowSeconds: [30, 20]
                    )
                    var runs: [TailAuditWindowRunEvidence] = []
                    var protectedPasses: [Bool] = []
                    for offset in 0..<iterationCount {
                        let iteration = offset + 1
                        let baselineFirst = !iteration.isMultiple(of: 2)
                        let pair = try await transcriber
                            .compareTailAuditWindows(
                                audio: audio,
                                orderedWindowSeconds:
                                    baselineFirst ? [20, 30] : [30, 20]
                            )
                        guard let baseline = pair.arms[20],
                              let candidate = pair.arms[30]
                        else {
                            throw TailWindowCompareError.missingArm
                        }
                        let baselineText = baseline.transcript
                            .trimmingCharacters(
                                in: .whitespacesAndNewlines
                            )
                        let candidateText = candidate.transcript
                            .trimmingCharacters(
                                in: .whitespacesAndNewlines
                            )
                        runs.append(
                            TailAuditWindowRunEvidence(
                                iteration: iteration,
                                order: baselineFirst
                                    ? "baseline-candidate"
                                    : "candidate-baseline",
                                baselineTranscriptSHA256: Self.sha256(
                                    Data(baselineText.utf8)
                                ),
                                candidateTranscriptSHA256: Self.sha256(
                                    Data(candidateText.utf8)
                                ),
                                baselineStopToFinalSeconds:
                                    baseline.modeledStopToFinalSeconds,
                                candidateStopToFinalSeconds:
                                    candidate.modeledStopToFinalSeconds,
                                baselineFullRetryPerformed:
                                    baseline.fullRetryPerformed,
                                candidateFullRetryPerformed:
                                    candidate.fullRetryPerformed,
                                baselineTailOutcome:
                                    baseline.tailOutcome,
                                candidateTailOutcome:
                                    candidate.tailOutcome
                            )
                        )
                        if let fixtureEvidence,
                           let comparison =
                               TranscriptionCompletenessOracle.compare(
                                   fixture: fixtureEvidence.fixture,
                                   baseline: baselineText,
                                   candidate: candidateText
                               )
                        {
                            protectedPasses.append(
                                comparison.candidatePassesCompletenessGate
                            )
                        } else {
                            protectedPasses.append(false)
                        }
                    }
                    box.store(.success(TailWindowCompareRuns(
                        runs: runs,
                        protectedCompletenessPassed:
                            fixtureEvidence != nil
                            && protectedPasses.allSatisfy(\.self)
                    )))
                } catch {
                    box.store(.failure(error))
                }
                semaphore.signal()
            }
            semaphore.wait()
            let result = try box.load().get()
            let decision = TailAuditWindowComparisonOracle.evaluate(
                baselineWindowSeconds: 20,
                candidateWindowSeconds: 30,
                protectedCompletenessPassed:
                    result.protectedCompletenessPassed,
                runs: result.runs
            )
            let report = TailWindowCompareReport(
                schemaVersion: 1,
                modelID: selectedModel.id,
                baselineImplementationID: "tail-audit-window-20s-v1",
                candidateImplementationID: "tail-audit-window-30s-v1",
                decoderConfigurationID: "wordhand-english-default-v1",
                audioSHA256: audioSHA256,
                fixtureSHA256: fixtureEvidence?.sha256,
                vocabularySHA256: Self.sha256(
                    vocabularyData
                ),
                sampleCount: audio.count,
                sampleRate: AudioCapture.targetSampleRate,
                audioDurationSeconds:
                    Double(audio.count) / AudioCapture.targetSampleRate,
                baselineWindowSeconds: 20,
                candidateWindowSeconds: 30,
                iterations: result.runs.count,
                protectedCompletenessPassed:
                    result.protectedCompletenessPassed,
                decision: decision,
                runs: result.runs
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            guard let encoded = String(data: data, encoding: .utf8) else {
                throw TailWindowCompareError.encodingFailed
            }
            if json {
                print(encoded)
            } else {
                print(
                    "20s/30s tail-window promotion gate: "
                        + (
                            decision.candidatePassesPromotionGate
                                ? "PASS" : "REJECT"
                        )
                )
                print(
                    "full retries: "
                        + "\(decision.baselineFullRetryCount) → "
                        + "\(decision.candidateFullRetryCount)"
                )
                print(
                    String(
                        format: "modeled median stop-to-final: %.3fs → %.3fs",
                        decision.baselineMedianStopToFinalSeconds,
                        decision.candidateMedianStopToFinalSeconds
                    )
                )
                print(encoded)
            }
            guard decision.candidatePassesPromotionGate else {
                throw ExitCode.failure
            }
        }

        private static func readOnlyDictionarySnapshot() throws
            -> [DictionaryEntry]
        {
            let url = DictionaryStore.defaultFileURL()
            guard FileManager.default.fileExists(atPath: url.path) else {
                return []
            }
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            return try decoder.decode(
                DictionaryDocument.self,
                from: data
            ).validated().entries
        }

        private static func sha256(_ data: Data) -> String {
            SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
        }
    }
}

private struct TailWindowFixtureEvidence: Sendable {
    let fixture: TranscriptionCompletenessFixture
    let sha256: String
}

private struct TailWindowVocabularyFingerprint: Codable {
    let canonicalTerms: [String]
    let pronunciationAssociations: [TailWindowPronunciationFingerprint]
}

private struct TailWindowPronunciationFingerprint: Codable {
    let spokenForm: String
    let canonicalTerm: String
}

private struct TailWindowCompareRuns: Sendable {
    let runs: [TailAuditWindowRunEvidence]
    let protectedCompletenessPassed: Bool
}

struct TailWindowCompareReport: Codable, Sendable {
    let schemaVersion: Int
    let modelID: String
    let baselineImplementationID: String
    let candidateImplementationID: String
    let decoderConfigurationID: String
    let audioSHA256: String
    let fixtureSHA256: String?
    let vocabularySHA256: String
    let sampleCount: Int
    let sampleRate: Double
    let audioDurationSeconds: TimeInterval
    let baselineWindowSeconds: Int
    let candidateWindowSeconds: Int
    let iterations: Int
    let protectedCompletenessPassed: Bool
    let decision: TailAuditWindowComparisonDecision
    let runs: [TailAuditWindowRunEvidence]
}

private final class TailWindowCompareResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<TailWindowCompareRuns, Error>?

    func store(_ result: Result<TailWindowCompareRuns, Error>) {
        lock.withLock {
            self.result = result
        }
    }

    func load() -> Result<TailWindowCompareRuns, Error> {
        lock.withLock {
            result ?? .failure(TailWindowCompareError.missingResult)
        }
    }
}

private enum TailWindowCompareError: Error {
    case missingArm
    case encodingFailed
    case missingResult
}
