import Foundation
import Testing
@testable import WordhandCore

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
    func emitsCorrelatedLifecycleDiagnosticsAndSavesTailOutcome() async throws {
        let history = FakeHistory()
        let transcriber = DiagnosticFakeTranscriber()
        let coordinator = DictationCoordinator(
            capture: FakeCapture(samples: Array(repeating: 0.1, count: 32_000)),
            transcriber: transcriber,
            processor: TranscriptProcessor(),
            inserter: FakeInserter(),
            history: history,
            now: makeClock([10, 12, 13, 14, 15, 16])
        )
        var events: [OperationalDiagnosticEvent] = []
        coordinator.onDiagnosticEvent = { events.append($0) }

        await coordinator.handle(.pressed)
        await coordinator.handle(.released)

        let saved = try #require(history.saved.first)
        #expect(saved.tailRecoveryOutcome == .fullRetryRecovered)
        #expect(
            events.map(\.name) == [
                "dictation.started",
                "capture.completed",
                "transcription.completed",
                "processing.completed",
                "history.saved",
                "insertion.completed",
                "dictation.completed",
            ]
        )
        let ids = Set(events.compactMap(\.dictationID))
        #expect(ids.count == 1)
        #expect(events.allSatisfy { !$0.attributes.keys.contains("text") })
        let transcription = try #require(
            events.first(where: { $0.name == "transcription.completed" })
        )
        #expect(
            transcription.attributes["tail_outcome"]
                == TailRecoveryOutcome.fullRetryRecovered.rawValue
        )
    }

    @Test
    func insertionModeCanChangeWithoutRestarting() async {
        let inserter = FakeInserter()
        let coordinator = DictationCoordinator(
            capture: FakeCapture(samples: [0.1]),
            transcriber: FakeTranscriber(result: "hello"),
            processor: TranscriptProcessor(),
            inserter: inserter,
            insertionMode: .unicode
        )

        coordinator.updateInsertionMode(.paste)
        await coordinator.handle(.pressed)
        await coordinator.handle(.released)

        #expect(inserter.modes == [.paste])
    }

    @Test
    func maximumPerformanceUsesStreamingResultInsteadOfBatchingAtRelease() async {
        let capture = FakeStreamingCapture(
            samples: [0.1, 0.2, 0.3],
            chunks: [[0.1], [0.2, 0.3]]
        )
        let transcriber = FakeStreamingTranscriber(
            streamingResult: StreamingTranscriptionResult(
                text: "already streamed",
                totalInferenceDuration: 1.5,
                finalizationDuration: 0.25
            )
        )
        let inserter = FakeInserter()
        let coordinator = DictationCoordinator(
            capture: capture,
            transcriber: transcriber,
            processor: TranscriptProcessor(),
            inserter: inserter,
            streamingEnabled: true
        )
        var finalizationDuration: TimeInterval?
        coordinator.onStreamingFinalizationDuration = {
            finalizationDuration = $0
        }

        await coordinator.handle(.pressed)
        await Task.yield()
        await coordinator.handle(.released)

        #expect(inserter.insertions == ["already streamed"])
        #expect(await transcriber.beginCount == 1)
        #expect(await transcriber.appendedSamples == [[0.1], [0.2, 0.3]])
        #expect(await transcriber.finishCount == 1)
        #expect(await transcriber.batchCount == 0)
        #expect(finalizationDuration == 0.25)
        #expect(!capture.hasStreamingHandler)
    }

    @Test
    func adaptivePerformanceKeepsTheSingleBatchPath() async {
        let capture = FakeStreamingCapture(
            samples: [0.1, 0.2],
            chunks: [[0.1], [0.2]]
        )
        let transcriber = FakeStreamingTranscriber(
            streamingResult: StreamingTranscriptionResult(
                text: "unused stream",
                totalInferenceDuration: 1,
                finalizationDuration: 0.1
            ),
            batchResult: "adaptive batch"
        )
        let inserter = FakeInserter()
        let coordinator = DictationCoordinator(
            capture: capture,
            transcriber: transcriber,
            processor: TranscriptProcessor(),
            inserter: inserter
        )

        await coordinator.handle(.pressed)
        await coordinator.handle(.released)

        #expect(inserter.insertions == ["adaptive batch"])
        #expect(await transcriber.beginCount == 0)
        #expect(await transcriber.finishCount == 0)
        #expect(await transcriber.batchCount == 1)
        #expect(!capture.hasStreamingHandler)
    }

    @Test
    func captureGapRefusesToInsertAQuietlyTruncatedRecording() async {
        let capture = FakeCapture(samples: Array(repeating: 0.1, count: 16_000))
        let transcriber = FakeTranscriber(result: "partial transcript")
        let inserter = FakeInserter()
        var timestamps: [TimeInterval] = [100, 105]
        let coordinator = DictationCoordinator(
            capture: capture,
            transcriber: transcriber,
            processor: TranscriptProcessor(),
            inserter: inserter,
            now: { timestamps.removeFirst() }
        )

        await coordinator.handle(.pressed)
        await coordinator.handle(.released)

        #expect(inserter.insertions.isEmpty)
        #expect(transcriber.callCount == 0)
        #expect(
            coordinator.state
                == .failed(.capture(
                    "Audio input stopped before recording ended. Wordhand did not insert a partial transcript."
                ))
        )
    }

    @Test
    func streamingFailureFallsBackToTheCompleteCapturedBuffer() async {
        let capture = FakeStreamingCapture(samples: [0.1, 0.2], chunks: [[0.1]])
        let transcriber = FakeStreamingTranscriber(
            streamingResult: nil,
            batchResult: "safe batch fallback"
        )
        let inserter = FakeInserter()
        let coordinator = DictationCoordinator(
            capture: capture,
            transcriber: transcriber,
            processor: TranscriptProcessor(),
            inserter: inserter,
            streamingEnabled: true
        )

        await coordinator.handle(.pressed)
        await coordinator.handle(.released)

        #expect(inserter.insertions == ["safe batch fallback"])
        #expect(await transcriber.finishCount == 1)
        #expect(await transcriber.batchCount == 1)
    }

    @Test
    func cancellationStopsStreamingAndClearsTheChunkHandler() async {
        let capture = FakeStreamingCapture(samples: [0.1], chunks: [])
        let transcriber = FakeStreamingTranscriber(
            streamingResult: StreamingTranscriptionResult(
                text: "unused",
                totalInferenceDuration: 0,
                finalizationDuration: 0
            )
        )
        let coordinator = DictationCoordinator(
            capture: capture,
            transcriber: transcriber,
            processor: TranscriptProcessor(),
            inserter: FakeInserter(),
            streamingEnabled: true
        )

        await coordinator.handle(.pressed)
        await coordinator.cancelCurrent()

        #expect(await transcriber.cancelStreamingCount == 1)
        #expect(!capture.hasStreamingHandler)
        #expect(coordinator.state == .idle)
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
    func cancelWhileRecordingDiscardsAudioAndReturnsToIdle() async {
        let capture = FakeCapture(samples: [0.1, 0.2])
        let transcriber = FakeTranscriber(result: "must never be inserted")
        let inserter = FakeInserter()
        let coordinator = DictationCoordinator(
            capture: capture,
            transcriber: transcriber,
            processor: TranscriptProcessor(),
            inserter: inserter
        )

        await coordinator.handle(.pressed)
        await coordinator.cancelCurrent()

        #expect(coordinator.state == .idle)
        #expect(capture.stopCount == 1)
        #expect(transcriber.callCount == 0)
        #expect(inserter.insertions.isEmpty)
    }

    @Test
    func cancelDoesNotAllowRestartUntilMicrophoneHasStopped() async {
        let capture = SuspendedCapture()
        let coordinator = DictationCoordinator(
            capture: capture,
            transcriber: FakeTranscriber(result: "unused"),
            processor: TranscriptProcessor(),
            inserter: FakeInserter()
        )

        await coordinator.handle(.pressed)
        let cancel = Task { await coordinator.cancelCurrent() }
        await capture.waitUntilStopStarted()
        await coordinator.handle(.pressed)

        #expect(capture.startCount == 1)
        #expect(coordinator.state == .recording)

        capture.finishStop()
        await cancel.value
        #expect(coordinator.state == .idle)

        await coordinator.handle(.pressed)
        #expect(capture.startCount == 2)
    }

    @Test
    func cancelDuringTranscriptionPreventsInsertion() async {
        let transcriber = SuspendedTranscriber()
        let inserter = FakeInserter()
        let coordinator = DictationCoordinator(
            capture: FakeCapture(samples: [0.1]),
            transcriber: transcriber,
            processor: TranscriptProcessor(),
            inserter: inserter
        )

        await coordinator.handle(.pressed)
        let release = Task { await coordinator.handle(.released) }
        await transcriber.waitUntilStarted()
        await coordinator.cancelCurrent()
        transcriber.finish(with: "must never be inserted")
        await release.value

        #expect(coordinator.state == .idle)
        #expect(inserter.insertions.isEmpty)
        #expect(transcriber.cancelCount == 1)
    }

    @Test
    func recordingLimitStopsAndProcessesInsteadOfGrowingForever() async {
        let sleeper = SuspendedSleep()
        let capture = FakeCapture(samples: [0.1, 0.2])
        let transcriber = FakeTranscriber(result: "limited recording")
        let inserter = FakeInserter()
        let coordinator = DictationCoordinator(
            capture: capture,
            transcriber: transcriber,
            processor: TranscriptProcessor(),
            inserter: inserter,
            maximumRecordingNanoseconds: 1,
            sleep: { nanoseconds in
                await sleeper.sleep(nanoseconds: nanoseconds)
            }
        )
        var reachedLimit = false
        coordinator.onRecordingLimitReached = {
            reachedLimit = true
        }

        await coordinator.handle(.pressed)
        await sleeper.waitUntilStarted()
        sleeper.finish()

        while coordinator.state != .idle {
            await Task.yield()
        }

        #expect(reachedLimit)
        #expect(capture.stopCount == 1)
        #expect(inserter.insertions == ["limited recording"])
        #expect(!transcriber.wasCancelledDuringTranscription)
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
            now: makeClock([10, 10.75, 20, 20.75, 30, 30])
        )
        var qualitySample: QualityAudioSample?
        coordinator.onQualityAudio = { qualitySample = $0 }

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
        #expect(qualitySample?.transcriptID == saved.id)
        #expect(qualitySample?.createdAt == createdAt)
        #expect(qualitySample?.samples.count == 32_000)
        #expect(qualitySample?.sampleRate == 16_000)
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
    private(set) var stopCount = 0

    init(samples: [Float]) {
        self.samples = samples
    }

    func start() throws {
        startCount += 1
    }

    func stop() async -> [Float] {
        stopCount += 1
        return samples
    }
}

private final class FakeStreamingCapture: StreamingAudioCapturing, @unchecked Sendable {
    private let samples: [Float]
    private let chunks: [[Float]]
    private let lock = NSLock()
    private var handler: (@Sendable ([Float]) -> Void)?

    init(samples: [Float], chunks: [[Float]]) {
        self.samples = samples
        self.chunks = chunks
    }

    var hasStreamingHandler: Bool {
        lock.withLock { handler != nil }
    }

    func setStreamingChunkHandler(
        _ handler: (@Sendable ([Float]) -> Void)?
    ) {
        lock.withLock {
            self.handler = handler
        }
    }

    func start() throws {
        let callback = lock.withLock { handler }
        for chunk in chunks {
            callback?(chunk)
        }
    }

    func stop() async -> [Float] {
        samples
    }
}

private actor FakeStreamingTranscriber: StreamingTranscribing {
    nonisolated let modelID = "fake-streaming"
    private let streamingResult: StreamingTranscriptionResult?
    private let batchResult: String
    private(set) var beginCount = 0
    private(set) var appendedSamples: [[Float]] = []
    private(set) var finishCount = 0
    private(set) var batchCount = 0
    private(set) var cancelStreamingCount = 0

    init(
        streamingResult: StreamingTranscriptionResult?,
        batchResult: String = "batch"
    ) {
        self.streamingResult = streamingResult
        self.batchResult = batchResult
    }

    func warmUp() async throws {}

    func transcribe(_ audio: [Float]) async throws -> String {
        batchCount += 1
        return batchResult
    }

    func beginStreaming(
        configuration: StreamingTranscriptionConfiguration
    ) {
        beginCount += 1
    }

    func appendStreamingAudio(_ samples: [Float]) {
        appendedSamples.append(samples)
    }

    func finishStreaming(
        finalAudio: [Float]
    ) throws -> StreamingTranscriptionResult {
        finishCount += 1
        guard let streamingResult else {
            throw FakeError.failure
        }
        return streamingResult
    }

    func cancelStreaming() {
        cancelStreamingCount += 1
    }
}

private final class FakeTranscriber: Transcribing, @unchecked Sendable {
    let modelID = "fake"
    private let result: String
    private(set) var callCount = 0
    private(set) var wasCancelledDuringTranscription = false

    init(result: String) {
        self.result = result
    }

    func warmUp() async throws {}

    func transcribe(_ audio: [Float]) async throws -> String {
        callCount += 1
        wasCancelledDuringTranscription = Task.isCancelled
        return result
    }
}

private final class DiagnosticFakeTranscriber:
    Transcribing,
    TranscriptionDiagnosticsProviding,
    @unchecked Sendable
{
    let modelID = "diagnostic-fake"

    func warmUp() async throws {}

    func transcribe(_ audio: [Float]) async throws -> String {
        "The recovered final sentence."
    }

    func lastRunDiagnostics() async -> TranscriptionRunDiagnostics {
        TranscriptionRunDiagnostics(
            tailRecoveryOutcome: .fullRetryRecovered,
            primaryWordCount: 2,
            finalWordCount: 4,
            fullRetryPerformed: true
        )
    }
}

private final class SuspendedCapture: AudioCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var startCount = 0
    private var stopStarted = false
    private var stopStartedContinuation: CheckedContinuation<Void, Never>?
    private var stopContinuation: CheckedContinuation<[Float], Never>?

    func start() throws {
        lock.withLock {
            startCount += 1
        }
    }

    func stop() async -> [Float] {
        let waiter = lock.withLock {
            stopStarted = true
            let waiter = stopStartedContinuation
            stopStartedContinuation = nil
            return waiter
        }
        waiter?.resume()
        return await withCheckedContinuation { continuation in
            lock.withLock {
                stopContinuation = continuation
            }
        }
    }

    func waitUntilStopStarted() async {
        if lock.withLock({ stopStarted }) { return }
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                if stopStarted {
                    return true
                }
                stopStartedContinuation = continuation
                return false
            }
            if resumeNow {
                continuation.resume()
            }
        }
    }

    func finishStop() {
        let continuation = lock.withLock {
            let continuation = stopContinuation
            stopContinuation = nil
            return continuation
        }
        continuation?.resume(returning: [])
    }
}

private final class SuspendedTranscriber: Transcribing, @unchecked Sendable {
    let modelID = "suspended"
    private let lock = NSLock()
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var resultContinuation: CheckedContinuation<String, Never>?
    private var didStart = false
    private(set) var cancelCount = 0

    func warmUp() async throws {}

    func transcribe(_ audio: [Float]) async throws -> String {
        let started = lock.withLock {
            didStart = true
            let continuation = startedContinuation
            startedContinuation = nil
            return continuation
        }
        started?.resume()
        return await withCheckedContinuation { continuation in
            lock.withLock {
                resultContinuation = continuation
            }
        }
    }

    func waitUntilStarted() async {
        if lock.withLock({ didStart }) { return }
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                if didStart {
                    return true
                } else {
                    startedContinuation = continuation
                    return false
                }
            }
            if resumeNow {
                continuation.resume()
            }
        }
    }

    func finish(with result: String) {
        let continuation = lock.withLock {
            let continuation = resultContinuation
            resultContinuation = nil
            return continuation
        }
        continuation?.resume(returning: result)
    }

    func cancel() {
        lock.withLock {
            cancelCount += 1
        }
    }
}

private final class SuspendedSleep: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var sleepContinuation: CheckedContinuation<Void, Never>?

    func sleep(nanoseconds: UInt64) async {
        let waiter = lock.withLock {
            started = true
            let waiter = startedContinuation
            startedContinuation = nil
            return waiter
        }
        waiter?.resume()
        await withCheckedContinuation { continuation in
            lock.withLock {
                sleepContinuation = continuation
            }
        }
    }

    func waitUntilStarted() async {
        if lock.withLock({ started }) { return }
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                if started {
                    return true
                }
                startedContinuation = continuation
                return false
            }
            if resumeNow {
                continuation.resume()
            }
        }
    }

    func finish() {
        let continuation = lock.withLock {
            let continuation = sleepContinuation
            sleepContinuation = nil
            return continuation
        }
        continuation?.resume()
    }
}

private final class FakeInserter: TextInserting, @unchecked Sendable {
    private(set) var insertions: [String] = []
    private(set) var modes: [InsertionMode] = []
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
        modes.append(mode)
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
