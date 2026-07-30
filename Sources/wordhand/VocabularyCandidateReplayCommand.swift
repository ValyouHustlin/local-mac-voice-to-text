import ArgumentParser
import CryptoKit
import Darwin
import Foundation
import WordhandCore
import WhisperKit

struct QualityProveVocabulary: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prove-vocabulary",
        abstract: "Replay a candidate vocabulary term against corrected local audio."
    )

    @Flag(name: .long, help: "Read the private replay request as JSON from stdin.")
    var requestStdin = false

    @Flag(name: .long, help: "Print the aggregate, transcript-free report as JSON.")
    var json = false

    @Option(name: .long, help: "Override the local Wordhand data directory.")
    var dataDirectory: String?

    @Option(name: .long, help: "Maximum seconds allowed for the isolated replay.")
    var timeoutSeconds = 900

    func validate() throws {
        guard requestStdin else {
            throw ValidationError("--request-stdin is required.")
        }
        guard (30...3_600).contains(timeoutSeconds) else {
            throw ValidationError("--timeout-seconds must be from 30 through 3600.")
        }
    }

    func run() throws {
        let input = try Self.readBoundedInput(FileHandle.standardInput)
        let request: VocabularyReplayRequest
        do {
            request = try JSONDecoder().decode(
                VocabularyReplayRequest.self,
                from: input
            )
        } catch {
            throw ValidationError("stdin does not contain a valid replay request.")
        }
        try request.validate()

        let worker =
            ProcessInfo.processInfo.environment["WORDHAND_VOCABULARY_REPLAY_WORKER"]
                == "1"
        let report = worker
            ? try evaluateInCurrentProcess(request)
            : try evaluateInIsolatedProcess(request, input: input)
        if worker || json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            FileHandle.standardOutput.write(try encoder.encode(report))
            FileHandle.standardOutput.write(Data("\n".utf8))
        } else {
            printHumanReport(report)
        }
    }

    private func evaluateInCurrentProcess(
        _ request: VocabularyReplayRequest
    ) throws -> VocabularyReplayReport {
        let semaphore = DispatchSemaphore(value: 0)
        let box = VocabularyReplayResultBox()
        Task.detached {
            do {
                box.store(.success(try await VocabularyReplayRunner.evaluate(
                    request,
                    dataURL: resolvedDataURL()
                )))
            } catch {
                box.store(.failure(error))
            }
            semaphore.signal()
        }
        semaphore.wait()
        return try box.load().get()
    }

    private func evaluateInIsolatedProcess(
        _ request: VocabularyReplayRequest,
        input: Data
    ) throws -> VocabularyReplayReport {
        guard let executable = Bundle.main.executableURL else {
            throw ValidationError("Could not resolve the Wordhand executable.")
        }
        let process = Process()
        process.executableURL = executable
        var arguments = [
            "quality", "prove-vocabulary",
            "--request-stdin", "--json",
            "--timeout-seconds", String(timeoutSeconds),
        ]
        if let dataDirectory {
            arguments += ["--data-directory", dataDirectory]
        }
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["WORDHAND_VOCABULARY_REPLAY_WORKER"] = "1"
        process.environment = environment
        process.standardError = FileHandle.standardError
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        let completion = DispatchSemaphore(value: 0)
        let outputCompletion = DispatchSemaphore(value: 0)
        let outputBox = VocabularyReplayOutputBox()
        process.terminationHandler = { _ in completion.signal() }
        try process.run()
        inputPipe.fileHandleForWriting.write(input)
        try inputPipe.fileHandleForWriting.close()
        DispatchQueue.global(qos: .utility).async {
            outputBox.store(outputPipe.fileHandleForReading.readDataToEndOfFile())
            outputCompletion.signal()
        }
        if completion.wait(
            timeout: .now() + .seconds(timeoutSeconds)
        ) == .timedOut {
            process.terminate()
            if completion.wait(timeout: .now() + .seconds(3)) == .timedOut,
               process.isRunning
            {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                _ = completion.wait(timeout: .now() + .seconds(3))
            }
            _ = outputCompletion.wait(timeout: .now() + .seconds(3))
            throw ValidationError(
                "Vocabulary replay exceeded \(timeoutSeconds) seconds; "
                    + "no partial verdict was recorded."
            )
        }
        outputCompletion.wait()
        guard process.terminationStatus == 0 else {
            throw ValidationError(
                "Vocabulary replay worker exited with status "
                    + "\(process.terminationStatus)."
            )
        }
        do {
            return try JSONDecoder().decode(
                VocabularyReplayReport.self,
                from: outputBox.load()
            )
        } catch {
            throw ValidationError("Vocabulary replay worker returned invalid output.")
        }
    }

    private func resolvedDataURL() -> URL {
        dataDirectory.map {
            URL(
                fileURLWithPath: NSString(string: $0).expandingTildeInPath,
                isDirectory: true
            )
        } ?? ApplicationData.defaultDirectory()
    }

    private func printHumanReport(_ report: VocabularyReplayReport) {
        print("Vocabulary causal replay")
        print("candidate kind: \(report.candidateKind.rawValue)")
        print("candidate sha256: \(report.candidateSHA256)")
        print("model: \(report.modelID)")
        print(
            "corpus: \(report.decision.supportingRecordingCount) supporting · "
                + "\(report.decision.corpusRecordingCount) total · "
                + "\(report.decision.repetitionCount) paired repetitions"
        )
        print(
            "word edits: \(report.decision.baselineWordEditDistance) → "
                + "\(report.decision.candidateWordEditDistance)"
        )
        print(
            "character edits: \(report.decision.baselineCharacterEditDistance) → "
                + "\(report.decision.candidateCharacterEditDistance)"
        )
        print(
            String(
                format: "decode time: %.3fs → %.3fs",
                report.decision.baselineDuration,
                report.decision.candidateDuration
            )
        )
        print("verdict: \(report.decision.verdict.rawValue)")
        if !report.decision.reasons.isEmpty {
            print("reasons: \(report.decision.reasons.joined(separator: ", "))")
        }
        if let live = report.liveBaselineDecision {
            print(
                "live-baseline check: \(live.verdict.rawValue) · "
                    + "word edits \(live.baselineWordEditDistance) → "
                    + "\(live.candidateWordEditDistance)"
            )
        }
        print("writes: none · network: disabled · report: transcript-free")
    }

    static func readBoundedInput(_ handle: FileHandle) throws -> Data {
        let maximumBytes = 16 * 1_024
        var input = Data()
        while input.count <= maximumBytes {
            let chunk = handle.readData(
                ofLength: min(4_096, maximumBytes + 1 - input.count)
            )
            if chunk.isEmpty { return input }
            input.append(chunk)
        }
        throw ValidationError(
            "Replay request exceeds the 16 KiB stdin limit."
        )
    }
}

struct VocabularyReplayRequest: Codable, Equatable {
    let schema: Int
    let candidate: String
    let heardAs: String?
    let supportingTranscriptIDs: [UUID]
    let modelID: String
    let repetitions: Int
    let limit: Int

    init(
        schema: Int,
        candidate: String,
        heardAs: String? = nil,
        supportingTranscriptIDs: [UUID],
        modelID: String,
        repetitions: Int,
        limit: Int
    ) {
        self.schema = schema
        self.candidate = candidate
        self.heardAs = heardAs
        self.supportingTranscriptIDs = supportingTranscriptIDs
        self.modelID = modelID
        self.repetitions = repetitions
        self.limit = limit
    }

    var candidateKind: VocabularyReplayCandidateKind {
        schema == 2 ? .pronunciationAlias : .canonicalTerm
    }

    func validate() throws {
        guard schema == 1 || schema == 2 else {
            throw ValidationError("Unsupported replay request schema.")
        }
        let term = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, term.count <= 100 else {
            throw ValidationError("Candidate must contain 1 through 100 characters.")
        }
        guard Set(supportingTranscriptIDs).count >= 2 else {
            throw ValidationError(
                "At least two distinct supporting transcript ids are required."
            )
        }
        guard supportingTranscriptIDs.count <= limit else {
            throw ValidationError(
                "The corpus limit cannot be smaller than the supporting set."
            )
        }
        if schema == 1 {
            guard heardAs == nil, repetitions == 4 else {
                throw ValidationError(
                    "Canonical proof requires exactly four paired repetitions."
                )
            }
        } else {
            let heard = heardAs?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !heard.isEmpty, heard.count <= 100,
                  normalizedRequestText(heard) != normalizedRequestText(term)
            else {
                throw ValidationError(
                    "Alias proof requires a distinct 1 through 100 character heardAs."
                )
            }
            guard repetitions == 6 else {
                throw ValidationError(
                    "Alias proof requires exactly six counterbalanced repetitions."
                )
            }
        }
        guard (3...50).contains(limit) else {
            throw ValidationError(
                "--limit in the request must be from 3 through 50."
            )
        }
    }

    private func normalizedRequestText(_ text: String) -> String {
        text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}

private struct VocabularyReplaySample: Sendable {
    let transcriptID: UUID
    let reference: String
    let audioURL: URL
    let audioSHA256: String
    let isSupporting: Bool
}

struct VocabularyReplayReport: Codable {
    let schema: Int
    let modelID: String
    let decoderConfigurationID: String
    let candidateKind: VocabularyReplayCandidateKind
    let candidateSHA256: String
    let spokenFormSHA256: String?
    let dictionarySHA256: String
    let corpusSHA256: String
    let supportingTranscriptIDSHA256: [String]
    let decision: VocabularyCandidateReplayDecision
    let liveBaselineDecision: VocabularyCandidateReplayDecision?
}

enum VocabularyReplayRunner {
    static func evaluate(
        _ request: VocabularyReplayRequest,
        dataURL: URL
    ) async throws -> VocabularyReplayReport {
        guard let model = ModelRegistry.find(request.modelID),
              let engineID = model.whisperKitID
        else {
            throw ValidationError("Unknown model: \(request.modelID)")
        }
        guard WhisperModelStorage.localModelFolder(
            modelID: engineID,
            downloadBase: WhisperModelStorage.defaultDownloadBase()
        ) != nil else {
            throw ValidationError(
                "\(request.modelID) is not completely cached; replay never downloads."
            )
        }

        let dictionaryURL = dataURL.appendingPathComponent("dictionary.json")
        let dictionarySnapshot = try loadDictionaryReadOnly(dictionaryURL)
        let baselineEntries = dictionarySnapshot.document.entries
        let candidate = request.candidate
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let records = try loadHistoryReadOnly(
            dataURL.appendingPathComponent("history.sqlite")
        )
        let samples = try loadSamples(
            request,
            records: records,
            dataURL: dataURL
        )
        let enabledCanonical = canonicalTerms(from: baselineEntries)
            .contains(where: { normalized($0) == normalized(candidate) })
        let candidateEntries: [DictionaryEntry]
        let priorityControlEntries: [DictionaryEntry]?
        let spokenForm: String?
        if request.candidateKind == .canonicalTerm {
            guard !enabledCanonical else {
                throw ValidationError(
                    "Candidate is already enabled in the dictionary."
                )
            }
            candidateEntries = baselineEntries + [
                DictionaryEntry(spokenForm: candidate, replacement: candidate),
            ]
            priorityControlEntries = nil
            spokenForm = nil
        } else {
            guard enabledCanonical, let requestedHeard = request.heardAs?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            else {
                throw ValidationError(
                    "Alias proof requires an enabled canonical dictionary term."
                )
            }
            let retainedIDs = Set(samples.map(\.transcriptID))
            let suggestions = PronunciationAliasSuggestionOracle.suggestions(
                records: records,
                retainedRecordingIDs: retainedIDs,
                existingEntries: baselineEntries
            )
            let supportIDs = Set(request.supportingTranscriptIDs)
            guard suggestions.contains(where: {
                normalized($0.heardForm) == normalized(requestedHeard)
                    && normalized($0.canonicalTerm) == normalized(candidate)
                    && supportIDs.isSubset(of: Set($0.supportingTranscriptIDs))
            }) else {
                throw ValidationError(
                    "Retained History does not prove this repeated explicit alias."
                )
            }
            let matchedDate = Date(timeIntervalSince1970: 4_102_444_800)
            let priorityEntry = DictionaryEntry(
                spokenForm: candidate,
                replacement: candidate,
                createdAt: matchedDate,
                updatedAt: matchedDate
            )
            let aliasEntry = DictionaryEntry(
                spokenForm: requestedHeard,
                replacement: candidate,
                createdAt: matchedDate,
                updatedAt: matchedDate
            )
            let control = baselineEntries + [priorityEntry]
            let alias = baselineEntries + [aliasEntry]
            try validateMatchedAliasPrompts(
                controlEntries: control,
                aliasEntries: alias,
                spokenForm: requestedHeard,
                canonicalTerm: candidate
            )
            priorityControlEntries = control
            candidateEntries = alias
            spokenForm = requestedHeard
        }
        let vocabulary = DictionaryVocabularySource(entries: baselineEntries)
        let transcriber = WhisperKitTranscriber(
            model: model,
            vocabulary: vocabulary
        )
        try await transcriber.warmUpRequiringCachedModel()
        let baselineProcessor = TranscriptProcessor(
            dictionaryEntries: baselineEntries
        )
        let result = request.candidateKind == .canonicalTerm
            ? try await runCanonicalReplay(
                request: request,
                samples: samples,
                candidate: candidate,
                baselineEntries: baselineEntries,
                candidateEntries: candidateEntries,
                vocabulary: vocabulary,
                transcriber: transcriber,
                processor: baselineProcessor
            )
            : try await runAliasReplay(
                request: request,
                samples: samples,
                candidate: candidate,
                spokenForm: spokenForm!,
                baselineEntries: baselineEntries,
                priorityControlEntries: priorityControlEntries!,
                aliasEntries: candidateEntries,
                vocabulary: vocabulary,
                transcriber: transcriber,
                processor: baselineProcessor
            )
        guard try loadDictionaryReadOnly(dictionaryURL).data
            == dictionarySnapshot.data
        else {
            throw ValidationError(
                "Dictionary changed during replay; no stale verdict was recorded."
            )
        }
        return VocabularyReplayReport(
            schema: request.schema,
            modelID: request.modelID,
            decoderConfigurationID: request.candidateKind == .canonicalTerm
                ? "full-buffer-v1-baseline-processor-v2"
                : "full-buffer-v1-priority-matched-alias-v1",
            candidateKind: request.candidateKind,
            candidateSHA256: sha256(Data(candidate.utf8)),
            spokenFormSHA256: spokenForm.map { sha256(Data($0.utf8)) },
            dictionarySHA256: sha256(dictionarySnapshot.data),
            corpusSHA256: corpusSHA256(samples),
            supportingTranscriptIDSHA256: samples.filter(\.isSupporting)
                .map {
                    sha256(Data(
                        $0.transcriptID.uuidString.lowercased().utf8
                    ))
                }
                .sorted(),
            decision: result.decision,
            liveBaselineDecision: result.liveBaselineDecision
        )
    }

    private static func runCanonicalReplay(
        request: VocabularyReplayRequest,
        samples: [VocabularyReplaySample],
        candidate: String,
        baselineEntries: [DictionaryEntry],
        candidateEntries: [DictionaryEntry],
        vocabulary: DictionaryVocabularySource,
        transcriber: WhisperKitTranscriber,
        processor: TranscriptProcessor
    ) async throws -> ReplayEvaluationResult {
        var observations: [VocabularyCandidateReplayObservation] = []
        for repetition in 0..<request.repetitions {
            let candidateFirst = repetition == 1 || repetition == 2
            for sample in samples {
                let audio = try loadAudio(sample)
                let baseline: ReplayTranscript
                let withCandidate: ReplayTranscript
                if candidateFirst {
                    withCandidate = try await transcribe(
                        audio,
                        entries: candidateEntries,
                        vocabulary: vocabulary,
                        transcriber: transcriber,
                        processor: processor
                    )
                    baseline = try await transcribe(
                        audio,
                        entries: baselineEntries,
                        vocabulary: vocabulary,
                        transcriber: transcriber,
                        processor: processor
                    )
                } else {
                    baseline = try await transcribe(
                        audio,
                        entries: baselineEntries,
                        vocabulary: vocabulary,
                        transcriber: transcriber,
                        processor: processor
                    )
                    withCandidate = try await transcribe(
                        audio,
                        entries: candidateEntries,
                        vocabulary: vocabulary,
                        transcriber: transcriber,
                        processor: processor
                    )
                }
                observations.append(try observation(
                    sample: sample,
                    repetition: repetition,
                    candidateKind: .canonicalTerm,
                    candidate: candidate,
                    spokenForm: nil,
                    baseline: baseline,
                    withCandidate: withCandidate,
                    dictionaryEntries: baselineEntries
                ))
            }
        }
        return ReplayEvaluationResult(
            decision: VocabularyCandidateReplayOracle.assess(
                observations: observations,
                requiredRepetitions: request.repetitions
            ),
            liveBaselineDecision: nil
        )
    }

    private static func runAliasReplay(
        request: VocabularyReplayRequest,
        samples: [VocabularyReplaySample],
        candidate: String,
        spokenForm: String,
        baselineEntries: [DictionaryEntry],
        priorityControlEntries: [DictionaryEntry],
        aliasEntries: [DictionaryEntry],
        vocabulary: DictionaryVocabularySource,
        transcriber: WhisperKitTranscriber,
        processor: TranscriptProcessor
    ) async throws -> ReplayEvaluationResult {
        let orders: [[ReplayArm]] = [
            [.baseline, .priorityControl, .alias],
            [.baseline, .alias, .priorityControl],
            [.priorityControl, .baseline, .alias],
            [.priorityControl, .alias, .baseline],
            [.alias, .baseline, .priorityControl],
            [.alias, .priorityControl, .baseline],
        ]
        var causal: [VocabularyCandidateReplayObservation] = []
        var liveSafety: [VocabularyCandidateReplayObservation] = []
        for (repetition, order) in orders.enumerated() {
            for sample in samples {
                let audio = try loadAudio(sample)
                var transcripts: [ReplayArm: ReplayTranscript] = [:]
                for arm in order {
                    let entries: [DictionaryEntry]
                    switch arm {
                    case .baseline:
                        entries = baselineEntries
                    case .priorityControl:
                        entries = priorityControlEntries
                    case .alias:
                        entries = aliasEntries
                    }
                    transcripts[arm] = try await transcribe(
                        audio,
                        entries: entries,
                        vocabulary: vocabulary,
                        transcriber: transcriber,
                        processor: processor
                    )
                }
                guard let baseline = transcripts[.baseline],
                      let control = transcripts[.priorityControl],
                      let alias = transcripts[.alias]
                else {
                    throw ValidationError("Alias replay did not complete every arm.")
                }
                causal.append(try observation(
                    sample: sample,
                    repetition: repetition,
                    candidateKind: .pronunciationAlias,
                    candidate: candidate,
                    spokenForm: spokenForm,
                    baseline: control,
                    withCandidate: alias,
                    dictionaryEntries: baselineEntries
                ))
                liveSafety.append(try observation(
                    sample: sample,
                    repetition: repetition,
                    candidateKind: .pronunciationAlias,
                    candidate: candidate,
                    spokenForm: spokenForm,
                    baseline: baseline,
                    withCandidate: alias,
                    dictionaryEntries: baselineEntries
                ))
            }
        }
        let causalDecision = VocabularyCandidateReplayOracle.assess(
            observations: causal,
            requiredRepetitions: request.repetitions
        )
        let liveDecision = VocabularyCandidateReplayOracle.assess(
            observations: liveSafety,
            requiredRepetitions: request.repetitions
        )
        return ReplayEvaluationResult(
            decision: combinedAliasDecision(
                causal: causalDecision,
                liveSafety: liveDecision
            ),
            liveBaselineDecision: liveDecision
        )
    }

    private static func combinedAliasDecision(
        causal: VocabularyCandidateReplayDecision,
        liveSafety: VocabularyCandidateReplayDecision
    ) -> VocabularyCandidateReplayDecision {
        let verdict: VocabularyCandidateReplayVerdict
        if causal.verdict == .inconclusive || liveSafety.verdict == .inconclusive {
            verdict = .inconclusive
        } else if causal.verdict == .proved && liveSafety.verdict == .proved {
            verdict = .proved
        } else {
            verdict = .rejected
        }
        let reasons = causal.reasons.map { "priority_control:\($0)" }
            + liveSafety.reasons.map { "live_baseline:\($0)" }
        return VocabularyCandidateReplayDecision(
            verdict: verdict,
            reasons: reasons,
            supportingRecordingCount: causal.supportingRecordingCount,
            corpusRecordingCount: causal.corpusRecordingCount,
            repetitionCount: causal.repetitionCount,
            baselineWordEditDistance: causal.baselineWordEditDistance,
            candidateWordEditDistance: causal.candidateWordEditDistance,
            baselineCharacterEditDistance: causal.baselineCharacterEditDistance,
            candidateCharacterEditDistance: causal.candidateCharacterEditDistance,
            baselineExactMatchCount: causal.baselineExactMatchCount,
            candidateExactMatchCount: causal.candidateExactMatchCount,
            baselineDuration: causal.baselineDuration,
            candidateDuration: causal.candidateDuration
        )
    }

    private static func observation(
        sample: VocabularyReplaySample,
        repetition: Int,
        candidateKind: VocabularyReplayCandidateKind,
        candidate: String,
        spokenForm: String?,
        baseline: ReplayTranscript,
        withCandidate: ReplayTranscript,
        dictionaryEntries: [DictionaryEntry]
    ) throws -> VocabularyCandidateReplayObservation {
        guard let baselineScore = TranscriptionQualityMetrics.score(
            reference: sample.reference,
            hypothesis: baseline.text
        ), let candidateScore = TranscriptionQualityMetrics.score(
            reference: sample.reference,
            hypothesis: withCandidate.text
        ) else {
            throw ValidationError("A selected reference is not scorable.")
        }
        return VocabularyCandidateReplayObservation(
            recordingID: sample.transcriptID.uuidString.lowercased(),
            audioSHA256: sample.audioSHA256,
            repetition: repetition,
            isSupporting: sample.isSupporting,
            candidateKind: candidateKind,
            baselineQuality: baselineScore,
            candidateQuality: candidateScore,
            baselineNormalizedSHA256: sha256(
                Data(normalized(baseline.text).utf8)
            ),
            candidateNormalizedSHA256: sha256(
                Data(normalized(withCandidate.text).utf8)
            ),
            baselineContainsCandidate: containsCanonicalSpelling(
                candidate,
                in: baseline.text
            ),
            candidateContainsCandidate: containsCanonicalSpelling(
                candidate,
                in: withCandidate.text
            ),
            baselineContainsSpokenForm: spokenForm.map {
                contains($0, in: baseline.text)
            } ?? false,
            protectedSpanRegression: protectedSpanRegression(
                reference: sample.reference,
                baseline: baseline.text,
                candidate: withCandidate.text,
                dictionaryEntries: dictionaryEntries
            ),
            baselineDuration: baseline.duration,
            candidateDuration: withCandidate.duration
        )
    }

    private static func loadAudio(
        _ sample: VocabularyReplaySample
    ) throws -> [Float] {
        let audio = try AudioProcessor.loadAudioAsFloatArray(
            fromPath: sample.audioURL.path
        )
        guard !audio.isEmpty else {
            throw ValidationError(
                "A selected Quality Lab recording contains no audio."
            )
        }
        return audio
    }

    private static func validateMatchedAliasPrompts(
        controlEntries: [DictionaryEntry],
        aliasEntries: [DictionaryEntry],
        spokenForm: String,
        canonicalTerm: String
    ) throws {
        let control = DictionaryVocabularySource(
            entries: controlEntries
        ).promptSnapshot()
        let alias = DictionaryVocabularySource(
            entries: aliasEntries
        ).promptSnapshot()
        guard control.canonicalTerms == alias.canonicalTerms else {
            throw ValidationError(
                "Alias and priority-control canonical prompts are not equivalent."
            )
        }
        let expected = DictionaryPronunciationAssociation(
            spokenForm: spokenForm,
            canonicalTerm: canonicalTerm
        )
        var remaining = alias.pronunciationAssociations
        guard let index = remaining.firstIndex(of: expected) else {
            throw ValidationError(
                "Alias was displaced from the bounded pronunciation prompt."
            )
        }
        remaining.remove(at: index)
        guard remaining == control.pronunciationAssociations else {
            throw ValidationError(
                "Alias changed another pronunciation association."
            )
        }
    }

    private static func loadSamples(
        _ request: VocabularyReplayRequest,
        records: [TranscriptRecord],
        dataURL: URL
    ) throws -> [VocabularyReplaySample] {
        let supportIDs = Set(request.supportingTranscriptIDs)
        let archive = LocalQualityAudioArchive(
            directoryURL: dataURL.appendingPathComponent(
                "Quality Recordings",
                isDirectory: true
            )
        )
        var seenAudio = Set<String>()
        let eligible = try records.compactMap {
            record -> VocabularyReplaySample? in
            guard let storedReference = record.referenceText else { return nil }
            let reference = storedReference
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !reference.isEmpty else { return nil }
            let audioURL = archive.fileURL(for: record.id)
            guard FileManager.default.fileExists(atPath: audioURL.path) else {
                return nil
            }
            let digest = sha256(try Data(contentsOf: audioURL))
            guard seenAudio.insert(digest).inserted else { return nil }
            return VocabularyReplaySample(
                transcriptID: record.id,
                reference: reference,
                audioURL: audioURL,
                audioSHA256: digest,
                isSupporting: supportIDs.contains(record.id)
            )
        }
        let supporting = eligible.filter(\.isSupporting)
        guard Set(supporting.map(\.transcriptID)) == supportIDs else {
            throw ValidationError(
                "Every supporting id must have a corrected reference and paired audio."
            )
        }
        let controls = eligible.filter { !$0.isSupporting }
        return supporting + controls.prefix(max(0, request.limit - supporting.count))
    }

    private static func transcribe(
        _ audio: [Float],
        entries: [DictionaryEntry],
        vocabulary: DictionaryVocabularySource,
        transcriber: WhisperKitTranscriber,
        processor: TranscriptProcessor
    ) async throws -> ReplayTranscript {
        vocabulary.update(entries: entries)
        let started = ProcessInfo.processInfo.systemUptime
        let raw = try await transcriber.transcribe(audio)
        let duration = ProcessInfo.processInfo.systemUptime - started
        return ReplayTranscript(
            text: await processor.process(raw),
            duration: duration
        )
    }

    private static func protectedSpanRegression(
        reference: String,
        baseline: String,
        candidate: String,
        dictionaryEntries: [DictionaryEntry]
    ) -> Bool {
        let referenceTokens = tokens(reference)
        let spans = [
            Array(referenceTokens.prefix(4)).joined(separator: " "),
            Array(referenceTokens.suffix(4)).joined(separator: " "),
        ] + referenceTokens.filter {
            $0.rangeOfCharacter(from: .decimalDigits) != nil
                || ["no", "not", "never", "without", "can't", "won't", "don't"]
                    .contains(normalized($0))
        }
        if spans.contains(where: { span in
            contains(span, in: baseline) && !contains(span, in: candidate)
        }) {
            return true
        }
        return canonicalTerms(from: dictionaryEntries).contains { term in
            containsCanonicalSpelling(term, in: baseline)
                && !containsCanonicalSpelling(term, in: candidate)
        }
    }

    private static func contains(_ phrase: String, in text: String) -> Bool {
        let phraseTokens = tokens(phrase)
        let textTokens = tokens(text)
        guard !phraseTokens.isEmpty, phraseTokens.count <= textTokens.count else {
            return false
        }
        for start in 0...(textTokens.count - phraseTokens.count) {
            if Array(textTokens[start..<(start + phraseTokens.count)])
                == phraseTokens
            {
                return true
            }
        }
        return false
    }

    private static func containsCanonicalSpelling(
        _ spelling: String,
        in text: String
    ) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: spelling)
        guard let expression = try? NSRegularExpression(
            pattern: #"(?<![\p{L}\p{N}])"# + escaped + #"(?![\p{L}\p{N}])"#
        ) else {
            return false
        }
        return expression.firstMatch(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text)
        ) != nil
    }

    private static func tokens(_ text: String) -> [String] {
        normalized(text).split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    private static func normalized(_ text: String) -> String {
        text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private static func canonicalTerms(
        from entries: [DictionaryEntry]
    ) -> [String] {
        var seen = Set<String>()
        return entries.compactMap { entry in
            guard entry.isEnabled else { return nil }
            let term = entry.replacement
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, seen.insert(normalized(term)).inserted else {
                return nil
            }
            return term
        }
    }

    private static func loadDictionaryReadOnly(
        _ fileURL: URL
    ) throws -> ReadOnlyDictionarySnapshot {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return ReadOnlyDictionarySnapshot(
                data: Data(),
                document: DictionaryDocument()
            )
        }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        if let document = try? decoder.decode(
            DictionaryDocument.self,
            from: data
        ) {
            return ReadOnlyDictionarySnapshot(
                data: data,
                document: try document.validated()
            )
        }
        if let entries = try? decoder.decode([DictionaryEntry].self, from: data) {
            return ReadOnlyDictionarySnapshot(
                data: data,
                document: try DictionaryDocument(entries: entries).validated()
            )
        }
        return ReadOnlyDictionarySnapshot(
            data: data,
            document: try decoder.decode(
                DictionaryDocument.self,
                from: data
            ).validated()
        )
    }

    private static func loadHistoryReadOnly(
        _ fileURL: URL
    ) throws -> [TranscriptRecord] {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "wordhand-quality-history-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(
            at: temporary,
            withIntermediateDirectories: true
        )
        let snapshotURL = temporary.appendingPathComponent("history.sqlite")

        for _ in 0..<3 {
            let first = try historyBytes(fileURL)
            let second = try historyBytes(fileURL)
            guard first == second else { continue }
            try first.database.write(to: snapshotURL, options: [.atomic])
            if let wal = first.wal {
                try wal.write(
                    to: URL(fileURLWithPath: snapshotURL.path + "-wal"),
                    options: [.atomic]
                )
            }
            do {
                let records = try TranscriptHistoryStore(
                    fileURL: snapshotURL
                ).records(limit: 5_000)
                return records
            } catch TranscriptHistoryError.unsupportedSchema(let version) {
                throw ValidationError(
                    "Transcript history schema \(version) requires the "
                        + "Wordhand app to migrate it before replay."
                )
            }
        }
        throw ValidationError(
            "Transcript history changed while Wordhand made its private "
                + "read-only snapshot; run replay again."
        )
    }

    private static func historyBytes(
        _ fileURL: URL
    ) throws -> HistoryFileBytes {
        let walURL = URL(fileURLWithPath: fileURL.path + "-wal")
        return HistoryFileBytes(
            database: try Data(contentsOf: fileURL),
            wal: FileManager.default.fileExists(atPath: walURL.path)
                ? try Data(contentsOf: walURL)
                : nil
        )
    }

    private static func corpusSHA256(
        _ samples: [VocabularyReplaySample]
    ) -> String {
        let identity = samples.map {
            [
                $0.transcriptID.uuidString.lowercased(),
                $0.audioSHA256,
                sha256(Data($0.reference.utf8)),
                $0.isSupporting ? "support" : "control",
            ].joined(separator: "\u{1f}")
        }.sorted().joined(separator: "\u{1e}")
        return sha256(Data(identity.utf8))
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct ReplayTranscript {
    let text: String
    let duration: TimeInterval
}

private enum ReplayArm: Hashable {
    case baseline
    case priorityControl
    case alias
}

private struct ReplayEvaluationResult {
    let decision: VocabularyCandidateReplayDecision
    let liveBaselineDecision: VocabularyCandidateReplayDecision?
}

private struct HistoryFileBytes: Equatable {
    let database: Data
    let wal: Data?
}

private struct ReadOnlyDictionarySnapshot {
    let data: Data
    let document: DictionaryDocument
}

private final class VocabularyReplayResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<VocabularyReplayReport, Error>?

    func store(_ result: Result<VocabularyReplayReport, Error>) {
        lock.withLock { self.result = result }
    }

    func load() -> Result<VocabularyReplayReport, Error> {
        lock.withLock {
            result ?? .failure(ValidationError("Replay worker produced no result."))
        }
    }
}

private final class VocabularyReplayOutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func store(_ data: Data) {
        lock.withLock { self.data = data }
    }

    func load() -> Data {
        lock.withLock { data }
    }
}
