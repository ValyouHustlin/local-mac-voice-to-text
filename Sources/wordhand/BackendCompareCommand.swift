import ArgumentParser
import CryptoKit
import Foundation
import WhisperKit
import WordhandCore

extension Models {
    struct BackendCompare: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "backend-compare",
            abstract: """
            Compare two full-buffer backends on identical retained local audio.
            """
        )

        @Argument(help: "Path to a retained local audio file.")
        var audioPath: String

        @Option(name: .long, help: "Path to a completeness fixture JSON file.")
        var fixture: String

        @Option(name: .long, help: "Baseline model id.")
        var baselineModel: String = "whisper-large-v3"

        @Option(name: .long, help: "Candidate model id.")
        var candidateModel: String = "parakeet-unified-en-0.6b"

        @Option(name: .long, help: "Paired runs from 1 through 5.")
        var iterations: Int = 2

        @Flag(
            name: .long,
            help: "Exit successfully when critical meaning passes despite an accuracy regression."
        )
        var allowAccuracyRegression: Bool = false

        func validate() throws {
            guard (1...5).contains(iterations) else {
                throw ValidationError("--iterations must be from 1 through 5.")
            }
        }

        func run() throws {
            guard let baseline = ModelRegistry.find(baselineModel) else {
                throw ValidationError("unknown baseline model: \(baselineModel)")
            }
            guard let candidate = ModelRegistry.find(candidateModel) else {
                throw ValidationError("unknown candidate model: \(candidateModel)")
            }
            try Self.requireCached(baseline)
            try Self.requireCached(candidate)

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
            let audio = try AudioProcessor.loadAudioAsFloatArray(fromPath: audioURL.path)
            guard fixture.sampleCount == audio.count else {
                throw ValidationError("decoded sample count does not match fixture")
            }

            let vocabulary = DictionaryVocabularySource(
                entries: fixture.vocabularyTerms.map {
                    DictionaryEntry(spokenForm: $0, replacement: $0)
                }
            )
            let baselineTranscriber = TranscriberFactory.make(
                model: baseline,
                vocabulary: vocabulary
            )
            let candidateTranscriber = TranscriberFactory.make(
                model: candidate,
                vocabulary: vocabulary
            )
            let box = BackendCompareResultBox()
            let semaphore = DispatchSemaphore(value: 0)
            let runCount = iterations
            Task.detached {
                do {
                    try await baselineTranscriber.warmUp()
                    try await candidateTranscriber.warmUp()
                    var runs: [BackendCompareRun] = []
                    for iteration in 0..<runCount {
                        let baselineFirst = iteration.isMultiple(of: 2)
                        let baselineRun: BackendTranscriptRun
                        let candidateRun: BackendTranscriptRun
                        if baselineFirst {
                            baselineRun = try await Self.transcribe(
                                baselineTranscriber,
                                audio: audio
                            )
                            candidateRun = try await Self.transcribe(
                                candidateTranscriber,
                                audio: audio
                            )
                        } else {
                            candidateRun = try await Self.transcribe(
                                candidateTranscriber,
                                audio: audio
                            )
                            baselineRun = try await Self.transcribe(
                                baselineTranscriber,
                                audio: audio
                            )
                        }
                        guard let comparison = TranscriptionCompletenessOracle.compare(
                            fixture: fixture,
                            baseline: baselineRun.transcript,
                            candidate: candidateRun.transcript
                        ) else {
                            throw BackendCompareError.invalidComparison
                        }
                        let criticalCategories: Set<ProtectedTranscriptCategory> = [
                            .beginning, .ending, .number, .negation,
                        ]
                        let criticalPassed = comparison.candidateProtected
                            .filter { criticalCategories.contains($0.category) }
                            .allSatisfy(\.passed)
                        runs.append(BackendCompareRun(
                            iteration: iteration + 1,
                            order: baselineFirst
                                ? "baseline-candidate"
                                : "candidate-baseline",
                            baseline: baselineRun,
                            candidate: candidateRun,
                            criticalMeaningPassed: criticalPassed,
                            fullAccuracyPassed:
                                comparison.candidatePassesCompletenessGate,
                            rejectionReasons: comparison.rejectionReasons
                        ))
                    }
                    box.store(.success(runs))
                } catch {
                    box.store(.failure(error))
                }
                semaphore.signal()
            }
            semaphore.wait()
            let runs = try box.load().get()

            let baselineMedian = Self.median(runs.map(\.baseline.seconds))
            let candidateMedian = Self.median(runs.map(\.candidate.seconds))
            let speedup = candidateMedian > 0
                ? baselineMedian / candidateMedian
                : 0
            let criticalPassed = runs.allSatisfy(\.criticalMeaningPassed)
            let fullAccuracyPassed = runs.allSatisfy(\.fullAccuracyPassed)
            print("fixture: \(fixture.id)")
            print("audio sha256: \(audioSHA256)")
            print("baseline: \(baseline.id)")
            print("candidate: \(candidate.id)")
            print(String(format: "baseline stop-to-final median: %.3fs", baselineMedian))
            print(String(format: "candidate stop-to-final median: %.3fs", candidateMedian))
            print(String(format: "candidate speedup: %.1fx", speedup))
            print("critical meaning gate: \(criticalPassed ? "PASS" : "REJECT")")
            print("full accuracy gate: \(fullAccuracyPassed ? "PASS" : "REJECT")")
            if allowAccuracyRegression, criticalPassed, !fullAccuracyPassed {
                print("accuracy regression explicitly accepted for this comparison")
            }
            for run in runs {
                print(
                    "run \(run.iteration) \(run.order): "
                        + "baseline=\(String(format: "%.3fs", run.baseline.seconds)) "
                        + "candidate=\(String(format: "%.3fs", run.candidate.seconds)) "
                        + "rejections=\(run.rejectionReasons.joined(separator: ","))"
                )
            }
            if !criticalPassed || (!fullAccuracyPassed && !allowAccuracyRegression) {
                throw ExitCode.failure
            }
        }

        private static func requireCached(_ model: TranscriptionModel) throws {
            switch model.engine {
            case .whisperKit:
                guard let engineID = model.whisperKitID,
                      WhisperModelStorage.localModelFolder(
                          modelID: engineID,
                          downloadBase: WhisperModelStorage.defaultDownloadBase()
                      ) != nil
                else {
                    throw ValidationError(
                        "\(model.id) is not completely cached; backend comparison "
                            + "never downloads models."
                    )
                }
            case .parakeet:
                guard case .ready = ParakeetModelStorage.cacheState() else {
                    throw ValidationError(
                        "\(model.id) is not completely cached; backend comparison "
                            + "never downloads models."
                    )
                }
            }
        }

        private static func transcribe(
            _ transcriber: any Transcribing,
            audio: [Float]
        ) async throws -> BackendTranscriptRun {
            let started = ProcessInfo.processInfo.systemUptime
            let transcript = try await transcriber.transcribe(audio)
            return BackendTranscriptRun(
                transcript: transcript.trimmingCharacters(in: .whitespacesAndNewlines),
                seconds: ProcessInfo.processInfo.systemUptime - started
            )
        }

        private static func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return 0 }
            let midpoint = sorted.count / 2
            if sorted.count.isMultiple(of: 2) {
                return (sorted[midpoint - 1] + sorted[midpoint]) / 2
            }
            return sorted[midpoint]
        }

        private static func sha256(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }
}

private struct BackendTranscriptRun: Sendable {
    let transcript: String
    let seconds: TimeInterval
}

private struct BackendCompareRun: Sendable {
    let iteration: Int
    let order: String
    let baseline: BackendTranscriptRun
    let candidate: BackendTranscriptRun
    let criticalMeaningPassed: Bool
    let fullAccuracyPassed: Bool
    let rejectionReasons: [String]
}

private final class BackendCompareResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<[BackendCompareRun], Error>?

    func store(_ result: Result<[BackendCompareRun], Error>) {
        lock.withLock { self.result = result }
    }

    func load() -> Result<[BackendCompareRun], Error> {
        lock.withLock {
            result ?? .failure(BackendCompareError.missingResult)
        }
    }
}

private enum BackendCompareError: Error {
    case invalidComparison
    case missingResult
}
