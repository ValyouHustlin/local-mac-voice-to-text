import ArgumentParser
import CryptoKit
import Foundation
import WhisperKit
import WordhandCore

extension Models {
    struct AuthorityCompare: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "authority-compare",
            abstract: """
            Compare full-buffer and rolling-final transcription on identical local audio.
            """
        )

        @Argument(help: "Path to a retained local audio file.")
        var audioPath: String

        @Option(name: .long, help: "Path to a completeness fixture JSON file.")
        var fixture: String

        @Option(name: .long, help: "Model id. Defaults to the recommended model.")
        var model: String?

        @Option(name: .long, help: "Balanced paired runs: 2, 4, 6, 8, or 10.")
        var iterations: Int = 4

        @Flag(name: .long, help: "Emit only the machine-readable JSON report.")
        var json: Bool = false

        func validate() throws {
            guard (2...10).contains(iterations), iterations.isMultiple(of: 2) else {
                throw ValidationError("--iterations must be an even number from 2 through 10.")
            }
        }

        func run() throws {
            let modelID = model ?? ModelRegistry.recommended()?.id
            guard let modelID, let selectedModel = ModelRegistry.find(modelID) else {
                throw ValidationError("unknown model: \(model ?? "none")")
            }
            guard let engineID = selectedModel.whisperKitID,
                  WhisperModelStorage.localModelFolder(
                      modelID: engineID,
                      downloadBase: WhisperModelStorage.defaultDownloadBase()
                  ) != nil
            else {
                throw ValidationError(
                    "\(selectedModel.id) is not completely cached. Run "
                        + "`wordhand models download \(selectedModel.id)` first; "
                        + "authority comparison never downloads a model."
                )
            }

            let audioURL = URL(
                fileURLWithPath: NSString(string: audioPath).expandingTildeInPath
            )
            let fixtureURL = URL(
                fileURLWithPath: NSString(string: fixture).expandingTildeInPath
            )
            let fixtureData = try Data(contentsOf: fixtureURL)
            let fixture = try JSONDecoder().decode(
                TranscriptionCompletenessFixture.self,
                from: fixtureData
            )
            let audioData = try Data(contentsOf: audioURL)
            let audioSHA256 = Self.sha256(audioData)
            let fixtureIssues = fixture.validationIssues(requireAudioIdentity: true)
            guard fixtureIssues.isEmpty else {
                throw ValidationError(fixtureIssues.joined(separator: "; "))
            }
            guard fixture.audioSHA256 == audioSHA256 else {
                throw ValidationError("audio SHA-256 does not match fixture")
            }
            let audio = try AudioProcessor.loadAudioAsFloatArray(
                fromPath: audioURL.path
            )
            guard !audio.isEmpty else {
                throw ValidationError("audio file contained no samples")
            }
            guard fixture.sampleCount == audio.count else {
                throw ValidationError("decoded sample count does not match fixture")
            }
            guard fixture.sampleRate == Int(AudioCapture.targetSampleRate) else {
                throw ValidationError("decoded sample rate does not match fixture")
            }

            let vocabulary = DictionaryVocabularySource(
                entries: fixture.vocabularyTerms.map {
                    DictionaryEntry(spokenForm: $0, replacement: $0)
                }
            )
            let transcriber = WhisperKitTranscriber(
                model: selectedModel,
                vocabulary: vocabulary
            )
            let box = AuthorityCompareResultBox()
            let semaphore = DispatchSemaphore(value: 0)
            let iterationCount = iterations
            Task.detached {
                do {
                    try await transcriber.warmUpRequiringCachedModel()
                    _ = try await Self.runBaseline(
                        transcriber: transcriber,
                        audio: audio
                    )
                    _ = try await Self.runCandidate(
                        transcriber: transcriber,
                        audio: audio
                    )
                    var pairedRuns: [AuthorityCompareRun] = []
                    for iteration in 0..<iterationCount {
                        let baselineFirst = iteration.isMultiple(of: 2)
                        let baseline: AuthorityTranscriptRun
                        let candidate: AuthorityTranscriptRun
                        if baselineFirst {
                            baseline = try await Self.runBaseline(
                                transcriber: transcriber,
                                audio: audio
                            )
                            candidate = try await Self.runCandidate(
                                transcriber: transcriber,
                                audio: audio
                            )
                        } else {
                            candidate = try await Self.runCandidate(
                                transcriber: transcriber,
                                audio: audio
                            )
                            baseline = try await Self.runBaseline(
                                transcriber: transcriber,
                                audio: audio
                            )
                        }
                        guard let comparison = TranscriptionCompletenessOracle.compare(
                            fixture: fixture,
                            baseline: baseline.transcript,
                            candidate: candidate.transcript
                        ) else {
                            throw AuthorityCompareError.emptyReference
                        }
                        pairedRuns.append(AuthorityCompareRun(
                            iteration: iteration + 1,
                            order: baselineFirst ? "baseline-candidate" : "candidate-baseline",
                            baseline: baseline,
                            candidate: candidate,
                            comparison: comparison
                        ))
                    }
                    box.store(.success(pairedRuns))
                } catch {
                    box.store(.failure(error))
                }
                semaphore.signal()
            }
            semaphore.wait()
            let runs = try box.load().get()

            let baselineTimes = runs.map(\.baseline.stopToFinalSeconds)
            let candidateTimes = runs.map(\.candidate.stopToFinalSeconds)
            let report = AuthorityCompareReport(
                fixtureID: fixture.id,
                modelID: selectedModel.id,
                baselineImplementationID: "full-buffer-authoritative-v1",
                candidateImplementationID:
                    "cumulative-prefix-overlap-final-v1",
                decoderConfigurationID: "wordhand-english-default-v1",
                audioSHA256: audioSHA256,
                fixtureSHA256: Self.sha256(fixtureData),
                vocabularySHA256: Self.sha256(
                    Data(fixture.vocabularyTerms.joined(separator: "\u{0}").utf8)
                ),
                sampleCount: audio.count,
                sampleRate: AudioCapture.targetSampleRate,
                audioDurationSeconds:
                    Double(audio.count) / AudioCapture.targetSampleRate,
                vocabularyTerms: fixture.vocabularyTerms,
                iterations: runs.count,
                baselineMedianStopToFinalSeconds: Self.percentile(
                    baselineTimes,
                    percentile: 0.5
                ),
                baselineP95StopToFinalSeconds: Self.percentile(
                    baselineTimes,
                    percentile: 0.95
                ),
                candidateMedianStopToFinalSeconds: Self.percentile(
                    candidateTimes,
                    percentile: 0.5
                ),
                candidateP95StopToFinalSeconds: Self.percentile(
                    candidateTimes,
                    percentile: 0.95
                ),
                everyComparisonPassed:
                    runs.allSatisfy {
                        $0.comparison.candidatePassesCompletenessGate
                    },
                runs: runs
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let reportData = try encoder.encode(report)
            guard let reportJSON = String(data: reportData, encoding: .utf8) else {
                throw AuthorityCompareError.encodingFailed
            }

            if json {
                print(reportJSON)
            } else {
                print("fixture: \(report.fixtureID)")
                print("model: \(report.modelID)")
                print("candidate: \(report.candidateImplementationID)")
                print("audio sha256: \(report.audioSHA256)")
                print("fixture sha256: \(report.fixtureSHA256)")
                print(
                    String(
                        format: "audio: %.2fs (%d samples)",
                        report.audioDurationSeconds,
                        report.sampleCount
                    )
                )
                print(
                    String(
                        format: "full-buffer stop-to-final median/p95: %.3fs / %.3fs",
                        report.baselineMedianStopToFinalSeconds,
                        report.baselineP95StopToFinalSeconds
                    )
                )
                print(
                    String(
                        format: "rolling-final stop-to-final median/p95: %.3fs / %.3fs",
                        report.candidateMedianStopToFinalSeconds,
                        report.candidateP95StopToFinalSeconds
                    )
                )
                print(
                    "control equivalence gate: "
                        + (report.everyComparisonPassed ? "PASS" : "REJECT")
                )
                print("result does not authorize an incremental runtime candidate")
                print(reportJSON)
            }
            if !report.everyComparisonPassed {
                throw ExitCode.failure
            }
        }

        private static func runBaseline(
            transcriber: WhisperKitTranscriber,
            audio: [Float]
        ) async throws -> AuthorityTranscriptRun {
            let started = ProcessInfo.processInfo.systemUptime
            let transcript = try await transcriber.transcribe(audio)
            let diagnostics = await transcriber.lastRunDiagnostics()
            return AuthorityTranscriptRun(
                transcript: transcript.trimmingCharacters(in: .whitespacesAndNewlines),
                stopToFinalSeconds: ProcessInfo.processInfo.systemUptime - started,
                provenance: AuthorityRunProvenance(
                    authorityPath: "full_buffer_baseline",
                    fallbackReason: nil,
                    preReleaseDecodeCount: 0,
                    preReleaseInferenceSeconds: 0,
                    cancellationDrainSeconds: 0,
                    reusedSampleCount: 0,
                    suffixStartSample: nil,
                    suffixSampleCount: nil,
                    overlapWordCount: 0,
                    diagnostics: diagnostics
                )
            )
        }

        private static func runCandidate(
            transcriber: WhisperKitTranscriber,
            audio: [Float]
        ) async throws -> AuthorityTranscriptRun {
            await transcriber.beginStreaming(
                configuration: StreamingTranscriptionConfiguration(
                    decodeIntervalSeconds: 8,
                    correctionHorizonSegments: 8,
                    finalizationStrategy:
                        .cumulativePrefixAuthorityExperiment
                )
            )
            let chunkSize = Int(AudioCapture.targetSampleRate / 2)
            var start = 0
            while start < audio.count {
                let end = min(start + chunkSize, audio.count)
                await transcriber.appendStreamingAudio(Array(audio[start..<end]))
                start = end
                if start < audio.count {
                    try await Task.sleep(nanoseconds: 250_000_000)
                }
            }
            let started = ProcessInfo.processInfo.systemUptime
            let result = try await transcriber.finishStreaming(finalAudio: audio)
            let diagnostics = await transcriber.lastRunDiagnostics()
            return AuthorityTranscriptRun(
                transcript: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
                stopToFinalSeconds: ProcessInfo.processInfo.systemUptime - started,
                provenance: AuthorityRunProvenance(
                    authorityPath: result.authorityPath,
                    fallbackReason: result.fallbackReason,
                    preReleaseDecodeCount: result.preReleaseDecodeCount,
                    preReleaseInferenceSeconds:
                        result.preReleaseInferenceDuration,
                    cancellationDrainSeconds:
                        result.cancellationDrainDuration,
                    reusedSampleCount: result.reusedSampleCount,
                    suffixStartSample: result.suffixStartSample,
                    suffixSampleCount: result.suffixSampleCount,
                    overlapWordCount: result.overlapWordCount,
                    diagnostics: diagnostics
                )
            )
        }

        private static func sha256(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }

        private static func percentile(
            _ values: [Double],
            percentile: Double
        ) -> Double {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return 0 }
            let index = max(
                0,
                min(
                    sorted.count - 1,
                    Int(ceil(percentile * Double(sorted.count))) - 1
                )
            )
            return sorted[index]
        }
    }
}

private struct AuthorityTranscriptRun: Codable, Sendable {
    let transcript: String
    let stopToFinalSeconds: Double
    let provenance: AuthorityRunProvenance
}

private struct AuthorityRunProvenance: Codable, Sendable {
    let authorityPath: String
    let fallbackReason: String?
    let preReleaseDecodeCount: Int
    let preReleaseInferenceSeconds: Double
    let cancellationDrainSeconds: Double
    let reusedSampleCount: Int
    let suffixStartSample: Int?
    let suffixSampleCount: Int?
    let overlapWordCount: Int
    let diagnostics: TranscriptionRunDiagnostics
}

private struct AuthorityCompareRun: Codable, Sendable {
    let iteration: Int
    let order: String
    let baseline: AuthorityTranscriptRun
    let candidate: AuthorityTranscriptRun
    let comparison: TranscriptionAuthorityComparison
}

private struct AuthorityCompareReport: Codable, Sendable {
    let fixtureID: String
    let modelID: String
    let baselineImplementationID: String
    let candidateImplementationID: String
    let decoderConfigurationID: String
    let audioSHA256: String
    let fixtureSHA256: String
    let vocabularySHA256: String
    let sampleCount: Int
    let sampleRate: Double
    let audioDurationSeconds: Double
    let vocabularyTerms: [String]
    let iterations: Int
    let baselineMedianStopToFinalSeconds: Double
    let baselineP95StopToFinalSeconds: Double
    let candidateMedianStopToFinalSeconds: Double
    let candidateP95StopToFinalSeconds: Double
    let everyComparisonPassed: Bool
    let runs: [AuthorityCompareRun]
}

private final class AuthorityCompareResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<[AuthorityCompareRun], Error>?

    func store(_ result: Result<[AuthorityCompareRun], Error>) {
        lock.withLock {
            self.result = result
        }
    }

    func load() -> Result<[AuthorityCompareRun], Error> {
        lock.withLock {
            result ?? .failure(AuthorityCompareError.missingResult)
        }
    }
}

private enum AuthorityCompareError: Error {
    case emptyReference
    case encodingFailed
    case missingResult
}
