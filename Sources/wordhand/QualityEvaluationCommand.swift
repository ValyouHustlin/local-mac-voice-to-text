import ArgumentParser
import Darwin
import Foundation
import WordhandCore
import WhisperKit

struct QualityEvaluate: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "evaluate",
        abstract: "Score cached local models against corrected Quality Lab recordings."
    )

    @Option(
        name: .long,
        help: "Model id to evaluate. Repeat this option to compare models."
    )
    var model: [String] = []

    @Flag(
        name: .long,
        help: "Evaluate every Wordhand model whose complete local cache is available."
    )
    var allCached: Bool = false

    @Flag(
        name: .long,
        help: "Disable local dictionary conditioning and deterministic substitution."
    )
    var withoutDictionary: Bool = false

    @Option(
        name: .long,
        help: "Maximum paired corrected recordings to evaluate, newest first."
    )
    var limit: Int = 50

    @Option(
        name: .long,
        help: "Maximum seconds allowed for each isolated model comparison."
    )
    var modelTimeoutSeconds: Int = 180

    @Option(
        name: .long,
        help: "Override the local Wordhand data directory for isolated evaluation."
    )
    var dataDirectory: String?

    @Flag(
        name: .long,
        help: "Print per-record metrics by local transcript id without transcript text."
    )
    var details: Bool = false

    func validate() throws {
        guard (1...500).contains(limit) else {
            throw ValidationError("--limit must be from 1 through 500.")
        }
        guard (30...900).contains(modelTimeoutSeconds) else {
            throw ValidationError(
                "--model-timeout-seconds must be from 30 through 900."
            )
        }
        guard !(allCached && !model.isEmpty) else {
            throw ValidationError(
                "Use either repeated --model options or --all-cached, not both."
            )
        }
    }

    func run() throws {
        let request = try makeRequest()
        let isWorker =
            ProcessInfo.processInfo.environment["WORDHAND_QUALITY_WORKER"] == "1"
        let report: QualityEvaluationReport
        if !isWorker {
            report = try evaluateModelsInIsolatedProcesses(request)
        } else {
            report = try evaluateInCurrentProcess(request)
        }

        if isWorker {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(report)
            guard let output = String(data: data, encoding: .utf8) else {
                throw QualityEvaluationError.invalidWorkerOutput
            }
            print(output)
        } else {
            printReport(report)
        }
    }

    private func evaluateInCurrentProcess(
        _ request: QualityEvaluationRequest
    ) throws -> QualityEvaluationReport {
        let semaphore = DispatchSemaphore(value: 0)
        let resultBox = QualityEvaluationResultBox()
        Task.detached {
            do {
                resultBox.store(.success(
                    try await QualityEvaluationRunner.evaluate(request)
                ))
            } catch {
                resultBox.store(.failure(error))
            }
            semaphore.signal()
        }
        semaphore.wait()
        return try resultBox.load().get()
    }

    private func evaluateModelsInIsolatedProcesses(
        _ request: QualityEvaluationRequest
    ) throws -> QualityEvaluationReport {
        var results: [QualityModelEvaluation] = []
        for model in request.models {
            let childReport = try evaluateInIsolatedProcess(modelID: model.id)
            guard let result = childReport.results.first,
                  childReport.results.count == 1
            else {
                throw QualityEvaluationError.invalidWorkerOutput
            }
            results.append(result)
        }
        return QualityEvaluationReport(
            evaluatedSampleCount: request.samples.count,
            totalLabeledCount: request.totalLabeledCount,
            pairedCount: request.pairedCount,
            dictionaryEntryCount: request.dictionaryEntries.count,
            dictionaryEnabled: request.dictionaryEnabled,
            includeDetails: request.includeDetails,
            results: results
        )
    }

    private func evaluateInIsolatedProcess(
        modelID: String
    ) throws -> QualityEvaluationReport {
        guard let executable = Bundle.main.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path)
        else {
            throw ValidationError(
                "Could not resolve the Wordhand executable for isolated "
                    + "model evaluation."
            )
        }

        let process = Process()
        process.executableURL = executable
        var arguments = [
            "quality",
            "evaluate",
            "--model",
            modelID,
            "--limit",
            String(limit),
            "--model-timeout-seconds",
            String(modelTimeoutSeconds),
            "--data-directory",
            resolvedDataURL().path,
        ]
        if withoutDictionary {
            arguments.append("--without-dictionary")
        }
        if details {
            arguments.append("--details")
        }
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["WORDHAND_QUALITY_WORKER"] = "1"
        process.environment = environment
        process.standardError = FileHandle.standardError
        let outputPipe = Pipe()
        process.standardOutput = outputPipe

        let completion = DispatchSemaphore(value: 0)
        let outputCompletion = DispatchSemaphore(value: 0)
        let outputBox = QualityWorkerOutputBox()
        process.terminationHandler = { _ in completion.signal() }
        try process.run()
        DispatchQueue.global(qos: .utility).async {
            outputBox.store(
                outputPipe.fileHandleForReading.readDataToEndOfFile()
            )
            outputCompletion.signal()
        }
        let waitResult = completion.wait(
            timeout: .now() + .seconds(modelTimeoutSeconds)
        )
        if waitResult == .timedOut {
            process.terminate()
            if completion.wait(timeout: .now() + .seconds(3)) == .timedOut {
                if process.isRunning {
                    _ = Darwin.kill(process.processIdentifier, SIGKILL)
                }
                _ = completion.wait(timeout: .now() + .seconds(3))
            }
            _ = outputCompletion.wait(timeout: .now() + .seconds(3))
            throw ValidationError(
                "\(modelID) exceeded the \(modelTimeoutSeconds)-second "
                    + "evaluation timeout. No score was recorded."
            )
        }

        outputCompletion.wait()
        let output = outputBox.load()
        guard process.terminationStatus == 0 else {
            throw ValidationError(
                "\(modelID) evaluation exited with status "
                    + "\(process.terminationStatus)."
            )
        }
        do {
            return try JSONDecoder().decode(
                QualityEvaluationReport.self,
                from: output
            )
        } catch {
            throw QualityEvaluationError.invalidWorkerOutput
        }
    }

    private func makeRequest() throws -> QualityEvaluationRequest {
        let dataURL = resolvedDataURL()

        let history = try TranscriptHistoryStore(
            fileURL: dataURL.appendingPathComponent("history.sqlite")
        )
        let records = try history.records(limit: 5_000)
        let labeled = records.filter {
            $0.referenceText?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty == false
        }
        let archive = LocalQualityAudioArchive(
            directoryURL: dataURL.appendingPathComponent(
                "Quality Recordings",
                isDirectory: true
            )
        )
        let paired = labeled.compactMap { record -> QualityEvaluationSample? in
            guard let reference = record.referenceText?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !reference.isEmpty
            else {
                return nil
            }
            let audioURL = archive.fileURL(for: record.id)
            guard FileManager.default.fileExists(atPath: audioURL.path) else {
                return nil
            }
            return QualityEvaluationSample(
                transcriptID: record.id,
                referenceText: reference,
                audioURL: audioURL
            )
        }
        let selectedSamples = Array(paired.prefix(limit))
        guard !selectedSamples.isEmpty else {
            if labeled.isEmpty {
                throw ValidationError(
                    "No corrected references are available. In Wordhand History, "
                        + "choose Improve Transcript Accuracy for a retained recording, "
                        + "then run this command again."
                )
            }
            throw ValidationError(
                "\(labeled.count) corrected reference(s) exist, but none have "
                    + "their paired local Quality Lab recording."
            )
        }

        let dictionaryEntries: [DictionaryEntry]
        if withoutDictionary {
            dictionaryEntries = []
        } else {
            dictionaryEntries = try DictionaryStore(
                fileURL: dataURL.appendingPathComponent("dictionary.json")
            ).load().entries
        }

        let selectedModels = try resolveModels(dataURL: dataURL)
        return QualityEvaluationRequest(
            samples: selectedSamples,
            totalLabeledCount: labeled.count,
            pairedCount: paired.count,
            models: selectedModels,
            dictionaryEntries: dictionaryEntries,
            dictionaryEnabled: !withoutDictionary,
            includeDetails: details
        )
    }

    private func resolvedDataURL() -> URL {
        if let dataDirectory {
            return URL(
                fileURLWithPath: NSString(
                    string: dataDirectory
                ).expandingTildeInPath,
                isDirectory: true
            )
        }
        return ApplicationData.defaultDirectory()
    }

    private func resolveModels(dataURL: URL) throws -> [TranscriptionModel] {
        let downloadBase = WhisperModelStorage.defaultDownloadBase()
        let requestedIDs: [String]
        if allCached {
            requestedIDs = ModelRegistry.shared.compactMap { candidate in
                guard let engineID = candidate.whisperKitID,
                      WhisperModelStorage.localModelFolder(
                          modelID: engineID,
                          downloadBase: downloadBase
                      ) != nil
                else {
                    return nil
                }
                return candidate.id
            }
        } else if !model.isEmpty {
            requestedIDs = model
        } else {
            requestedIDs = [
                try SettingsStore(
                    fileURL: dataURL.appendingPathComponent("settings.json")
                ).load().modelID,
            ]
        }

        var seen = Set<String>()
        let uniqueIDs = requestedIDs.filter { seen.insert($0).inserted }
        guard !uniqueIDs.isEmpty else {
            throw ValidationError(
                "No complete cached Wordhand model is available for evaluation."
            )
        }

        return try uniqueIDs.map { id in
            guard let selected = ModelRegistry.find(id),
                  let engineID = selected.whisperKitID
            else {
                throw ValidationError("Unknown model: \(id)")
            }
            guard WhisperModelStorage.localModelFolder(
                modelID: engineID,
                downloadBase: downloadBase
            ) != nil
            else {
                throw ValidationError(
                    "\(id) is not completely cached. Run "
                        + "`wordhand models download \(id)` first; evaluation "
                        + "never downloads a model implicitly."
                )
            }
            return selected
        }
    }

    private func printReport(_ report: QualityEvaluationReport) {
        print("Quality Lab evaluation")
        print(
            "corpus: \(report.evaluatedSampleCount) paired corrected recording(s) "
                + "of \(report.totalLabeledCount) labeled"
        )
        if report.pairedCount > report.evaluatedSampleCount {
            print(
                "limit: newest \(report.evaluatedSampleCount) of "
                    + "\(report.pairedCount) paired recordings"
            )
        }
        print(
            report.dictionaryEnabled
                ? "dictionary: \(report.dictionaryEntryCount) local entries"
                : "dictionary: disabled for this evaluation"
        )
        print("network: disabled; complete cached models only")

        for result in report.results {
            print("")
            print("model: \(result.modelID)")
            print(String(format: "warmup: %.3fs", result.warmupDuration))
            print(String(format: "audio: %.2fs", result.audioDuration))
            print(
                String(
                    format: "transcription: %.3fs · real-time factor: %.3fx",
                    result.transcriptionDuration,
                    result.realTimeFactor
                )
            )
            print(
                String(
                    format: "normalized word error rate: %.2f%% · accuracy: %.2f%%",
                    result.aggregate.wordErrorRate * 100,
                    Self.accuracy(from: result.aggregate.wordErrorRate) * 100
                )
            )
            print(
                String(
                    format: "normalized spelling error rate: %.2f%% · accuracy: %.2f%%",
                    result.aggregate.characterErrorRate * 100,
                    Self.accuracy(from: result.aggregate.characterErrorRate) * 100
                )
            )
            print(
                "normalized exact: \(result.aggregate.exactMatchCount)"
                    + "/\(result.aggregate.sampleCount)"
            )
            if report.includeDetails {
                for detail in result.details {
                    print(
                        String(
                            format: "  %@ · WER %.2f%% · CER %.2f%% · %.3fs",
                            detail.transcriptID.uuidString.lowercased(),
                            detail.score.wordErrorRate * 100,
                            detail.score.characterErrorRate * 100,
                            detail.transcriptionDuration
                        )
                    )
                }
            }
        }

        if report.results.count > 1 {
            print("")
            print("ranking: lowest word error rate, then spelling error and latency")
            for (offset, result) in report.rankedResults.enumerated() {
                print(
                    String(
                        format: "%d. %@ · WER %.2f%% · CER %.2f%% · RTF %.3fx",
                        offset + 1,
                        result.modelID,
                        result.aggregate.wordErrorRate * 100,
                        result.aggregate.characterErrorRate * 100,
                        result.realTimeFactor
                    )
                )
            }
        }
    }

    private static func accuracy(from errorRate: Double) -> Double {
        max(0, 1 - errorRate)
    }
}

private struct QualityEvaluationSample: Sendable {
    let transcriptID: UUID
    let referenceText: String
    let audioURL: URL
}

private struct QualityEvaluationRequest: Sendable {
    let samples: [QualityEvaluationSample]
    let totalLabeledCount: Int
    let pairedCount: Int
    let models: [TranscriptionModel]
    let dictionaryEntries: [DictionaryEntry]
    let dictionaryEnabled: Bool
    let includeDetails: Bool
}

private struct QualityEvaluationDetail: Codable, Sendable {
    let transcriptID: UUID
    let score: TranscriptionQualityScore
    let transcriptionDuration: TimeInterval
}

private struct QualityModelEvaluation: Codable, Sendable {
    let modelID: String
    let warmupDuration: TimeInterval
    let audioDuration: TimeInterval
    let transcriptionDuration: TimeInterval
    let aggregate: TranscriptionQualityAggregate
    let details: [QualityEvaluationDetail]

    var realTimeFactor: Double {
        guard audioDuration > 0 else { return 0 }
        return transcriptionDuration / audioDuration
    }
}

private struct QualityEvaluationReport: Codable, Sendable {
    let evaluatedSampleCount: Int
    let totalLabeledCount: Int
    let pairedCount: Int
    let dictionaryEntryCount: Int
    let dictionaryEnabled: Bool
    let includeDetails: Bool
    let results: [QualityModelEvaluation]

    var rankedResults: [QualityModelEvaluation] {
        results.sorted {
            if $0.aggregate.wordErrorRate != $1.aggregate.wordErrorRate {
                return $0.aggregate.wordErrorRate < $1.aggregate.wordErrorRate
            }
            if $0.aggregate.characterErrorRate != $1.aggregate.characterErrorRate {
                return $0.aggregate.characterErrorRate
                    < $1.aggregate.characterErrorRate
            }
            return $0.realTimeFactor < $1.realTimeFactor
        }
    }
}

private enum QualityEvaluationRunner {
    static func evaluate(
        _ request: QualityEvaluationRequest
    ) async throws -> QualityEvaluationReport {
        var results: [QualityModelEvaluation] = []
        for model in request.models {
            results.append(
                try await evaluate(model: model, request: request)
            )
        }
        return QualityEvaluationReport(
            evaluatedSampleCount: request.samples.count,
            totalLabeledCount: request.totalLabeledCount,
            pairedCount: request.pairedCount,
            dictionaryEntryCount: request.dictionaryEntries.count,
            dictionaryEnabled: request.dictionaryEnabled,
            includeDetails: request.includeDetails,
            results: results
        )
    }

    private static func evaluate(
        model: TranscriptionModel,
        request: QualityEvaluationRequest
    ) async throws -> QualityModelEvaluation {
        let vocabulary = DictionaryVocabularySource(
            entries: request.dictionaryEntries
        )
        let transcriber = WhisperKitTranscriber(
            model: model,
            vocabulary: vocabulary
        )
        let processor = TranscriptProcessor(
            dictionaryEntries: request.dictionaryEntries
        )

        let warmupStarted = ProcessInfo.processInfo.systemUptime
        try await transcriber.warmUpRequiringCachedModel()
        let warmupDuration =
            ProcessInfo.processInfo.systemUptime - warmupStarted

        var scores: [TranscriptionQualityScore] = []
        var details: [QualityEvaluationDetail] = []
        var audioDuration: TimeInterval = 0
        var transcriptionDuration: TimeInterval = 0

        for sample in request.samples {
            let audio = try AudioProcessor.loadAudioAsFloatArray(
                fromPath: sample.audioURL.path
            )
            guard !audio.isEmpty else {
                throw ValidationError(
                    "Quality recording \(sample.transcriptID.uuidString) "
                        + "contains no audio samples."
                )
            }
            audioDuration += Double(audio.count) / Double(WhisperKit.sampleRate)

            let transcriptionStarted = ProcessInfo.processInfo.systemUptime
            let raw = try await transcriber.transcribe(audio)
            let elapsed =
                ProcessInfo.processInfo.systemUptime - transcriptionStarted
            transcriptionDuration += elapsed

            let processed = await processor.process(raw)
            guard let score = TranscriptionQualityMetrics.score(
                reference: sample.referenceText,
                hypothesis: processed
            ) else {
                throw ValidationError(
                    "Corrected reference \(sample.transcriptID.uuidString) "
                        + "contains no scorable words."
                )
            }
            scores.append(score)
            if request.includeDetails {
                details.append(QualityEvaluationDetail(
                    transcriptID: sample.transcriptID,
                    score: score,
                    transcriptionDuration: elapsed
                ))
            }
        }

        return QualityModelEvaluation(
            modelID: model.id,
            warmupDuration: warmupDuration,
            audioDuration: audioDuration,
            transcriptionDuration: transcriptionDuration,
            aggregate: TranscriptionQualityAggregate(scores: scores),
            details: details
        )
    }
}

private final class QualityEvaluationResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<QualityEvaluationReport, Error>?

    func store(_ result: Result<QualityEvaluationReport, Error>) {
        lock.withLock {
            self.result = result
        }
    }

    func load() -> Result<QualityEvaluationReport, Error> {
        lock.withLock {
            result ?? .failure(QualityEvaluationError.missingResult)
        }
    }
}

private final class QualityWorkerOutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func store(_ data: Data) {
        lock.withLock {
            self.data = data
        }
    }

    func load() -> Data {
        lock.withLock { data }
    }
}

private enum QualityEvaluationError: Error {
    case missingResult
    case invalidWorkerOutput
}
