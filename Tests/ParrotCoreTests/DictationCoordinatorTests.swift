import Foundation
import Testing
@testable import ParrotCore

@Suite
@MainActor
struct DictationCoordinatorTests {
    @Test
    func successfulFlowProcessesAndInsertsTranscript() async {
        let capture = FakeCapture(samples: [0.1, 0.2])
        let transcriber = FakeTranscriber(result: "hello [MUSIC] whisper flow")
        let inserter = FakeInserter()
        let coordinator = DictationCoordinator(
            capture: capture,
            transcriber: transcriber,
            processor: TranscriptProcessor(dictionaryEntries: [
                DictionaryEntry(spokenForm: "whisper flow", replacement: "Wispr Flow"),
            ]),
            inserter: inserter
        )
        var states: [DictationState] = []
        coordinator.onStateChange = { states.append($0) }

        await coordinator.handle(.pressed)
        await coordinator.handle(.released)

        #expect(inserter.insertions == ["hello Wispr Flow"])
        #expect(states == [.recording, .transcribing, .processing, .inserting, .idle])
    }

    @Test
    func ignoresSecondPressWhileRecording() async {
        let capture = FakeCapture(samples: [0.1])
        let coordinator = DictationCoordinator(
            capture: capture,
            transcriber: FakeTranscriber(result: "hello"),
            processor: TranscriptProcessor(),
            inserter: FakeInserter()
        )

        await coordinator.handle(.pressed)
        await coordinator.handle(.pressed)

        #expect(capture.startCount == 1)
    }

    @Test
    func emptyCaptureReturnsToIdleWithoutTranscribing() async {
        let transcriber = FakeTranscriber(result: "should not run")
        let coordinator = DictationCoordinator(
            capture: FakeCapture(samples: []),
            transcriber: transcriber,
            processor: TranscriptProcessor(),
            inserter: FakeInserter()
        )

        await coordinator.handle(.pressed)
        await coordinator.handle(.released)

        #expect(coordinator.state == .idle)
        #expect(transcriber.callCount == 0)
    }

    @Test
    func insertionFailureRemainsVisibleUntilReset() async {
        let coordinator = DictationCoordinator(
            capture: FakeCapture(samples: [0.1]),
            transcriber: FakeTranscriber(result: "hello"),
            processor: TranscriptProcessor(),
            inserter: FakeInserter(error: FakeError.failure)
        )

        await coordinator.handle(.pressed)
        await coordinator.handle(.released)

        if case .failed(.insertion) = coordinator.state {
            coordinator.resetFailure()
            #expect(coordinator.state == .idle)
        } else {
            Issue.record("expected insertion failure, got \(coordinator.state)")
        }
    }

    @Test
    func nextPressRecoversFromPreviousFailure() async {
        let capture = FakeCapture(samples: [0.1])
        let coordinator = DictationCoordinator(
            capture: capture,
            transcriber: FakeTranscriber(result: "hello"),
            processor: TranscriptProcessor(),
            inserter: FakeInserter(error: FakeError.failure)
        )

        await coordinator.handle(.pressed)
        await coordinator.handle(.released)
        await coordinator.handle(.pressed)

        #expect(coordinator.state == .recording)
        #expect(capture.startCount == 2)
    }

    @Test
    func savesProcessedTranscriptBeforeInsertionAndMarksSuccess() async throws {
        let history = FakeHistory()
        let inserter = FakeInserter(onInsert: {
            #expect(history.saved.count == 1)
            #expect(history.saved[0].status == .pendingInsertion)
        })
        let createdAt = Date(timeIntervalSince1970: 1_234)
        let coordinator = DictationCoordinator(
            capture: FakeCapture(samples: Array(repeating: 0.1, count: 32_000)),
            transcriber: FakeTranscriber(result: "hello [MUSIC] whisper flow"),
            processor: TranscriptProcessor(dictionaryEntries: [
                DictionaryEntry(spokenForm: "whisper flow", replacement: "Wispr Flow"),
            ]),
            inserter: inserter,
            history: history,
            language: "en",
            currentTarget: {
                TranscriptTarget(
                    bundleIdentifier: "com.apple.TextEdit",
                    applicationName: "TextEdit"
                )
            },
            date: { createdAt },
            now: makeClock([10, 10.75])
        )

        await coordinator.handle(.pressed)
        await coordinator.handle(.released)

        let saved = try #require(history.saved.first)
        #expect(saved.createdAt == createdAt)
        #expect(saved.rawText == "hello [MUSIC] whisper flow")
        #expect(saved.text == "hello Wispr Flow")
        #expect(saved.modelID == "fake")
        #expect(saved.language == "en")
        #expect(saved.audioDuration == 2)
        #expect(saved.transcriptionDuration == 0.75)
        #expect(saved.insertionMode == .unicode)
        #expect(saved.target.applicationName == "TextEdit")
        #expect(history.updates.count == 1)
        #expect(history.updates[0].0 == saved.id)
        #expect(history.updates[0].1 == .inserted)
    }

    @Test
    func failedInsertionRemainsRecoverableInHistory() async throws {
        let history = FakeHistory()
        let coordinator = DictationCoordinator(
            capture: FakeCapture(samples: [0.1]),
            transcriber: FakeTranscriber(result: "do not lose this"),
            processor: TranscriptProcessor(),
            inserter: FakeInserter(error: FakeError.failure),
            history: history
        )

        await coordinator.handle(.pressed)
        await coordinator.handle(.released)

        let saved = try #require(history.saved.first)
        #expect(saved.text == "do not lose this")
        #expect(history.updates.count == 1)
        if case .insertionFailed = history.updates[0].1 {
            // Expected.
        } else {
            Issue.record("expected failed history state, got \(history.updates[0].1)")
        }
        #expect(coordinator.state == .failed(.insertion("failure")))
    }
}

private enum FakeError: Error {
    case failure
}

private final class FakeCapture: AudioCapturing {
    private let samples: [Float]
    private(set) var startCount = 0

    init(samples: [Float]) {
        self.samples = samples
    }

    func start() throws {
        startCount += 1
    }

    func stop() -> [Float] {
        samples
    }
}

private final class FakeTranscriber: Transcribing, @unchecked Sendable {
    let modelID = "fake"
    private let result: String
    private(set) var callCount = 0

    init(result: String) {
        self.result = result
    }

    func warmUp() async throws {}

    func transcribe(_ audio: [Float]) async throws -> String {
        callCount += 1
        return result
    }
}

private final class FakeInserter: TextInserting, @unchecked Sendable {
    private(set) var insertions: [String] = []
    private let error: Error?
    private let onInsert: (() -> Void)?

    init(error: Error? = nil, onInsert: (() -> Void)? = nil) {
        self.error = error
        self.onInsert = onInsert
    }

    func insert(_ text: String, mode: InsertionMode) async throws {
        onInsert?()
        if let error { throw error }
        insertions.append(text)
    }
}

private final class FakeHistory: TranscriptRecording, @unchecked Sendable {
    private(set) var saved: [TranscriptRecord] = []
    private(set) var updates: [(UUID, TranscriptInsertionStatus)] = []

    func save(_ record: TranscriptRecord) throws {
        saved.append(record)
    }

    func updateStatus(id: UUID, status: TranscriptInsertionStatus) throws {
        updates.append((id, status))
    }
}

private func makeClock(_ values: [TimeInterval]) -> () -> TimeInterval {
    var iterator = values.makeIterator()
    return { iterator.next() ?? values.last ?? 0 }
}
