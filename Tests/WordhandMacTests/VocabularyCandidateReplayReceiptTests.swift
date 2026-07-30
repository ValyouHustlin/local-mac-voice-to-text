import CryptoKit
import Foundation
import Testing
import WordhandCore
@testable import wordhand

@Suite(.serialized)
struct VocabularyCandidateReplayReceiptTests {
    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment[
                "WORDHAND_VOCABULARY_REPLAY_RECEIPT"
            ] == "1"
        )
    )
    func replaysPublicRetainedCorpusWithoutMutatingLocalState() async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixtures = root.appendingPathComponent("Tests/Fixtures")
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "wordhand-vocabulary-replay-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(
            at: temporary,
            withIntermediateDirectories: true
        )

        let fixtureNames = [
            "english-completeness-v1",
            "english-boundary-long-v1",
            "english-ambiguous-overlap-v1",
        ]
        let ids = [UUID(), UUID(), UUID()]
        do {
            let history = try TranscriptHistoryStore(
                fileURL: temporary.appendingPathComponent("history.sqlite")
            )
            let archive = LocalQualityAudioArchive(
                directoryURL: temporary.appendingPathComponent(
                    "Quality Recordings",
                    isDirectory: true
                )
            )
            try archive.ensureDirectory()
            for (offset, name) in fixtureNames.enumerated() {
                let fixtureData = try Data(
                    contentsOf: fixtures.appendingPathComponent("\(name).json")
                )
                let fixture = try JSONDecoder().decode(
                    TranscriptionCompletenessFixture.self,
                    from: fixtureData
                )
                try history.save(TranscriptRecord(
                    id: ids[offset],
                    createdAt: Date(timeIntervalSince1970: Double(offset)),
                    rawText: "",
                    text: "",
                    modelID: "whisper-large-v3",
                    audioDuration: 1,
                    transcriptionDuration: 1,
                    insertionMode: .paste,
                    referenceText: fixture.reference
                ))
                try Data(
                    contentsOf: fixtures.appendingPathComponent("\(name).aiff")
                ).write(to: archive.fileURL(for: ids[offset]))
            }
        }
        try DictionaryStore(
            fileURL: temporary.appendingPathComponent("dictionary.json")
        ).save(DictionaryDocument())

        let before = try directorySnapshot(temporary)
        let request = VocabularyReplayRequest(
            schema: 1,
            candidate: "Aaron Browne-Moore",
            supportingTranscriptIDs: Array(ids.prefix(2)),
            modelID: "whisper-large-v3",
            repetitions: 4,
            limit: 3
        )
        let process = Process()
        process.executableURL = root.appendingPathComponent(".build/debug/wordhand")
        process.arguments = [
            "quality", "prove-vocabulary",
            "--request-stdin", "--json",
            "--data-directory", temporary.path,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["WORDHAND_SAFE"] = "1"
        process.environment = environment
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.standardError
        try process.run()
        inputPipe.fileHandleForWriting.write(try JSONEncoder().encode(request))
        try inputPipe.fileHandleForWriting.close()
        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let report = try JSONDecoder().decode(
            VocabularyReplayReport.self,
            from: output
        )
        let after = try directorySnapshot(temporary)
        FileHandle.standardError.write(Data(
            (
                "vocabulary replay receipt: verdict="
                    + "\(report.decision.verdict.rawValue) "
                    + "word=\(report.decision.baselineWordEditDistance)"
                    + "->\(report.decision.candidateWordEditDistance) "
                    + "character=\(report.decision.baselineCharacterEditDistance)"
                    + "->\(report.decision.candidateCharacterEditDistance) "
                    + "exact=\(report.decision.baselineExactMatchCount)"
                    + "->\(report.decision.candidateExactMatchCount) "
                    + String(
                        format: "decode=%.3f->%.3f reasons=%@\n",
                        report.decision.baselineDuration,
                        report.decision.candidateDuration,
                        report.decision.reasons.joined(separator: ",")
                    )
            ).utf8
        ))

        #expect(before == after)
        #expect(report.decision.supportingRecordingCount == 2)
        #expect(report.decision.corpusRecordingCount == 3)
        #expect(report.decision.repetitionCount == 4)
        #expect(report.decision.verdict == .rejected)
        #expect(report.decision.reasons.contains("latency_regression"))
    }

    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment[
                "WORDHAND_PRONUNCIATION_REPLAY_RECEIPT"
            ] == "1"
        )
    )
    func replaysEvidenceBackedAliasAgainstMatchedPriorityControl() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "wordhand-pronunciation-replay-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(
            at: temporary,
            withIntermediateDirectories: true
        )
        let ids = [UUID(), UUID(), UUID()]
        let heard = "Aaron Brown more"
        let canonical = "Aaron Browne-Moore"
        let recordings = [
            (
                "Please ask Aaron Brown more to review the Wordhand release.",
                "Please ask Aaron Browne-Moore to review the Wordhand release.",
                170
            ),
            (
                "Email Aaron Brown more about the GitHub issue tomorrow.",
                "Email Aaron Browne-Moore about the GitHub issue tomorrow.",
                205
            ),
            (
                "Boundary alpha confirms 14.5 and do not deploy on Friday.",
                "Boundary alpha confirms 14.5 and do not deploy on Friday.",
                185
            ),
        ]
        do {
            let history = try TranscriptHistoryStore(
                fileURL: temporary.appendingPathComponent("history.sqlite")
            )
            let archive = LocalQualityAudioArchive(
                directoryURL: temporary.appendingPathComponent(
                    "Quality Recordings",
                    isDirectory: true
                )
            )
            try archive.ensureDirectory()
            for index in recordings.indices {
                let recording = recordings[index]
                let rawText = index < 2 ? recording.0 : recording.1
                try history.save(TranscriptRecord(
                    id: ids[index],
                    createdAt: Date(timeIntervalSince1970: Double(index)),
                    rawText: rawText,
                    text: rawText,
                    modelID: "whisper-large-v3",
                    audioDuration: 1,
                    transcriptionDuration: 1,
                    insertionMode: .paste,
                    referenceText: recording.1
                ))
                try synthesize(
                    recording.0,
                    rate: recording.2,
                    to: archive.fileURL(for: ids[index])
                )
            }
        }
        try DictionaryStore(
            fileURL: temporary.appendingPathComponent("dictionary.json")
        ).save(DictionaryDocument(entries: [
            DictionaryEntry(spokenForm: canonical, replacement: canonical),
        ]))

        let before = try directorySnapshot(temporary)
        let request = VocabularyReplayRequest(
            schema: 2,
            candidate: canonical,
            heardAs: heard,
            supportingTranscriptIDs: Array(ids.prefix(2)),
            modelID: "whisper-large-v3",
            repetitions: 6,
            limit: 3
        )
        let process = Process()
        process.executableURL = root.appendingPathComponent(".build/debug/wordhand")
        process.arguments = [
            "quality", "prove-vocabulary",
            "--request-stdin", "--json",
            "--data-directory", temporary.path,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["WORDHAND_SAFE"] = "1"
        process.environment = environment
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.standardError
        try process.run()
        inputPipe.fileHandleForWriting.write(try JSONEncoder().encode(request))
        try inputPipe.fileHandleForWriting.close()
        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let report = try JSONDecoder().decode(
            VocabularyReplayReport.self,
            from: output
        )
        let after = try directorySnapshot(temporary)
        FileHandle.standardError.write(Data(
            (
                "pronunciation replay receipt: verdict="
                    + "\(report.decision.verdict.rawValue) "
                    + "causal-word=\(report.decision.baselineWordEditDistance)"
                    + "->\(report.decision.candidateWordEditDistance) "
                    + String(
                        format: "causal-decode=%.3f->%.3f reasons=%@\n",
                        report.decision.baselineDuration,
                        report.decision.candidateDuration,
                        report.decision.reasons.joined(separator: ",")
                    )
            ).utf8
        ))

        #expect(before == after)
        #expect(report.candidateKind == .pronunciationAlias)
        #expect(report.spokenFormSHA256 != nil)
        #expect(report.liveBaselineDecision?.verdict == .rejected)
        #expect(report.decision.supportingRecordingCount == 2)
        #expect(report.decision.corpusRecordingCount == 3)
        #expect(report.decision.repetitionCount == 6)
        #expect(report.decision.verdict == .rejected)
        #expect(report.decision.reasons.contains(
            "priority_control:no_strict_supporting_improvement"
        ))
        #expect(report.decision.reasons.contains(
            "live_baseline:no_strict_supporting_improvement"
        ))
    }

    private func synthesize(
        _ text: String,
        rate: Int,
        to outputURL: URL
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = [
            "-v", "Samantha",
            "-r", String(rate),
            "-o", outputURL.path,
            "--data-format=LEI16@16000",
            text,
        ]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    private func directorySnapshot(_ root: URL) throws -> [String] {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .fileSizeKey,
        ]
        let enumerator = try #require(
            FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            )
        )
        var snapshot: [String] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: keys)
            let relative = String(url.path.dropFirst(root.path.count + 1))
            let attributes = try FileManager.default.attributesOfItem(
                atPath: url.path
            )
            let permissions = (attributes[.posixPermissions] as? NSNumber)?
                .intValue ?? -1
            if values.isDirectory == true {
                snapshot.append("d|\(relative)|\(permissions)")
            } else {
                snapshot.append(
                    "f|\(relative)|\(permissions)|\(values.fileSize ?? -1)|"
                        + (try fileSHA256(url))
                )
            }
        }
        return snapshot.sorted()
    }

    private func fileSHA256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
