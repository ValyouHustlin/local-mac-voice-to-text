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

    init(error: Error? = nil) {
        self.error = error
    }

    func insert(_ text: String, mode: InsertionMode) async throws {
        if let error { throw error }
        insertions.append(text)
    }
}
