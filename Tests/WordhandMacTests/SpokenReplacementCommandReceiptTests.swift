import CryptoKit
import Foundation
import Testing
import WordhandCore
@testable import wordhand

@Suite(.serialized)
struct SpokenReplacementCommandReceiptTests {
    @Test
    func retainedFixtureIdentitiesAndExpectedEditsAreBound() throws {
        let fixture = try Self.loadFixture()
        #expect(fixture.schemaVersion == 1)
        #expect(fixture.modelID == "whisper-large-v3")
        #expect(fixture.provenance == "syntheticNamespaceEvidence")
        #expect(fixture.generator.path == "/usr/bin/say")
        #expect(fixture.generator.voice == "Samantha")
        #expect(fixture.fixtures.count == 7)
        #expect(
            Set(
                fixture.fixtures
                    .filter { $0.id.contains("spoken-deletion") }
                    .map(\.id)
            ) == [
                "english-spoken-deletion-positive-v1",
                "english-spoken-deletion-repeated-v1",
                "english-spoken-deletion-semantic-v1",
            ]
        )

        let fixtureDirectory = Self.fixtureDirectory()
        for item in fixture.fixtures {
            let audio = try Data(
                contentsOf: fixtureDirectory.appendingPathComponent(item.audio)
            )
            #expect(Self.sha256(audio) == item.audioSHA256)
            #expect(Self.sha256(item.source) == item.sourceSHA256)
            #expect(
                Self.sha256(item.expectedDecodedText)
                    == item.expectedDecodedSHA256
            )
            #expect(
                Self.sha256(item.expectedProcessedText)
                    == item.expectedProcessedSHA256
            )
            #expect(item.nativeSampleRate == 22_050)
            #expect(item.decodedSampleRate == 16_000)
            #expect(item.nativeSampleCount > item.decodedSampleCount)
            #expect(item.durationSeconds > 0)

            let result = SpokenReplacementCommandEngine.apply(
                to: item.expectedDecodedText
            )
            #expect(result.text == item.expectedProcessedText)
            #expect(
                Self.outcomeID(result.outcome) == item.expectedOutcome
            )
            for span in item.protectedSpans {
                #expect(item.expectedDecodedText.contains(span))
                #expect(item.expectedProcessedText.contains(span))
            }
        }
    }

    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment[
                "WORDHAND_REPLACEMENT_AUDIO_RECEIPT"
            ] == "1"
        )
    )
    func retainedAudioDecodesAndFormatsDeterministically() throws {
        let root = Self.repositoryRoot()
        let executable = root.appendingPathComponent(".build/debug/wordhand")
        let fixture = try Self.loadFixture()
        let fixtureDirectory = Self.fixtureDirectory()

        for item in fixture.fixtures {
            for _ in 0..<4 {
                let benchmark = try Self.runProcess(
                    executable: executable,
                    arguments: [
                        "models", "benchmark",
                        fixtureDirectory.appendingPathComponent(item.audio).path,
                        "--model", fixture.modelID,
                    ]
                )
                #expect(benchmark.status == 0)
                #expect(benchmark.output.contains("path: full buffer"))
                let decoded = try #require(
                    benchmark.output
                        .split(separator: "\n")
                        .first { $0.hasPrefix("transcript: ") }
                        .map { String($0.dropFirst("transcript: ".count)) }
                )
                #expect(decoded == item.expectedDecodedText)
                let result = SpokenReplacementCommandEngine.apply(to: decoded)
                #expect(result.text == item.expectedProcessedText)
                #expect(
                    Self.outcomeID(result.outcome) == item.expectedOutcome
                )
            }

            let formatted = try Self.runProcess(
                executable: executable,
                arguments: [
                    "format", item.expectedDecodedText,
                    "--style", "formatted",
                    "--application", "TextEdit",
                ]
            )
            #expect(formatted.status == 0)
            #expect(
                formatted.output
                    .trimmingCharacters(in: .newlines)
                    == item.expectedProcessedText
            )
        }
    }

    private static func outcomeID(
        _ outcome: SpokenReplacementCommandOutcome
    ) -> String {
        switch outcome {
        case .noCommand:
            return "no_command"
        case .applied:
            return "applied"
        case .rejected(let reason):
            return "rejected:\(reason.rawValue)"
        }
    }

    private static func loadFixture() throws -> ReplacementCorpusFixture {
        let data = try Data(
            contentsOf: fixtureDirectory()
                .appendingPathComponent(
                    "english-spoken-replacement-corpus-v1.json"
                )
        )
        return try JSONDecoder().decode(
            ReplacementCorpusFixture.self,
            from: data
        )
    }

    private static func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func fixtureDirectory() -> URL {
        repositoryRoot().appendingPathComponent("Tests/Fixtures")
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func sha256(_ text: String) -> String {
        sha256(Data(text.utf8))
    }

    private static func runProcess(
        executable: URL,
        arguments: [String]
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["WORDHAND_SAFE"] = "1"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: data, as: UTF8.self)
        )
    }
}

private struct ReplacementCorpusFixture: Decodable {
    let schemaVersion: Int
    let modelID: String
    let provenance: String
    let generator: ReplacementFixtureGenerator
    let fixtures: [ReplacementAudioFixture]
}

private struct ReplacementFixtureGenerator: Decodable {
    let path: String
    let voice: String
}

private struct ReplacementAudioFixture: Decodable {
    let id: String
    let audio: String
    let source: String
    let sourceSHA256: String
    let audioSHA256: String
    let nativeSampleRate: Int
    let nativeSampleCount: Int
    let decodedSampleRate: Int
    let decodedSampleCount: Int
    let durationSeconds: Double
    let expectedDecodedText: String
    let expectedDecodedSHA256: String
    let expectedProcessedText: String
    let expectedProcessedSHA256: String
    let expectedOutcome: String
    let protectedSpans: [String]
}
