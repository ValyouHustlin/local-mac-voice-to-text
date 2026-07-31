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
    func startAcceptanceFeedbackPrecedesCaptureStartup() async {
        var events: [String] = []
        let capture = FakeCapture(
            samples: [0.1],
            onStart: { events.append("capture-start") }
        )
        let coordinator = DictationCoordinator(
            capture: capture,
            transcriber: FakeTranscriber(result: "hello"),
            processor: TranscriptProcessor(),
            inserter: FakeInserter()
        )
        coordinator.onRecordingStartAccepted = {
            events.append("start-feedback")
        }

        await coordinator.handle(.pressed)

        #expect(events == ["start-feedback", "capture-start"])
        #expect(coordinator.state == .recording)
    }

    @Test
    func failedCaptureStartImmediatelyRejectsAcceptedFeedback() async {
        var events: [String] = []
        let capture = FakeCapture(
            samples: [],
            startError: FakeError.failure,
            onStart: { events.append("capture-start") }
        )
        let coordinator = DictationCoordinator(
            capture: capture,
            transcriber: FakeTranscriber(result: "unused"),
            processor: TranscriptProcessor(),
            inserter: FakeInserter()
        )
        coordinator.onRecordingStartAccepted = {
            events.append("start-feedback")
        }
        coordinator.onRecordingStartRejected = {
            events.append("rejected-feedback")
        }

        await coordinator.handle(.pressed)

        #expect(
            events
                == [
                    "start-feedback",
                    "capture-start",
                    "rejected-feedback",
                ]
        )
        #expect(coordinator.state == .failed(.capture("failure")))
    }

    @Test
    func failedRecoveryPreparationRejectsFeedbackWithoutStartingCapture() async {
        var events: [String] = []
        let capture = FailingRecoveryPreparationCapture(
            onPrepare: { events.append("recovery-prepare") },
            onStart: { events.append("capture-start") }
        )
        let coordinator = DictationCoordinator(
            capture: capture,
            transcriber: FakeTranscriber(result: "unused"),
            processor: TranscriptProcessor(),
            inserter: FakeInserter()
        )
        coordinator.onRecordingStartAccepted = {
            events.append("start-feedback")
        }
        coordinator.onRecordingStartRejected = {
            events.append("rejected-feedback")
        }

        await coordinator.handle(.pressed)

        #expect(
            events
                == [
                    "start-feedback",
                    "recovery-prepare",
                    "rejected-feedback",
                ]
        )
        #expect(coordinator.state == .failed(.capture("failure")))
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
    func normalReleaseEmitsOneFinishIntentAtInputStop() async {
        let capture = SuspendedCapture()
        let coordinator = DictationCoordinator(
            capture: capture,
            transcriber: FakeTranscriber(result: "unused"),
            processor: TranscriptProcessor(),
            inserter: FakeInserter()
        )
        var stopCueCount = 0
        capture.onInputStopped = {
            if coordinator.consumeRecordingEndIntent() == .finish {
                stopCueCount += 1
            }
        }

        await coordinator.handle(.pressed)
        let release = Task { await coordinator.handle(.released) }
        await capture.waitUntilStopStarted()

        #expect(stopCueCount == 0)

        capture.finishStop()
        await release.value

        #expect(stopCueCount == 1)
        capture.repeatInputStopped()
        #expect(stopCueCount == 1)
        #expect(coordinator.consumeRecordingEndIntent() == nil)
    }

    @Test
    func cancellationDuringReleaseTailSuppressesNormalFinishIntent() async {
        let capture = SuspendedCapture()
        let transcriber = FakeTranscriber(result: "must not run")
        let inserter = FakeInserter()
        let coordinator = DictationCoordinator(
            capture: capture,
            transcriber: transcriber,
            processor: TranscriptProcessor(),
            inserter: inserter
        )
        var cancelCueCount = 0
        var stopCueCount = 0
        capture.onInputStopped = {
            if coordinator.consumeRecordingEndIntent() == .finish {
                stopCueCount += 1
            }
        }

        await coordinator.handle(.pressed)
        let release = Task { await coordinator.handle(.released) }
        await capture.waitUntilStopStarted()

        coordinator.markCancellationIntent()
        cancelCueCount += 1
        await coordinator.cancelCurrent()
        capture.finishStop()
        await release.value

        #expect(cancelCueCount == 1)
        #expect(stopCueCount == 0)
        #expect(coordinator.state == .idle)
        #expect(transcriber.callCount == 0)
        #expect(inserter.insertions.isEmpty)
        #expect(coordinator.consumeRecordingEndIntent() == nil)
    }

    @Test
    func cancelDuringTranscriptionPreventsInsertion() async {
        let capture = FakeRecoveryCapture(samples: [0.1])
        let transcriber = SuspendedTranscriber()
        let inserter = FakeInserter()
        let coordinator = DictationCoordinator(
            capture: capture,
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
        #expect(capture.discardedIDs == capture.preparedIDs)
    }

    @Test
    func lifecycleInterruptionWaitsForCaptureSealWithoutTranscribingOrInserting() async {
        let capture = SuspendedCapture()
        let transcriber = FakeTranscriber(result: "must remain recoverable")
        let inserter = FakeInserter()
        let coordinator = DictationCoordinator(
            capture: capture,
            transcriber: transcriber,
            processor: TranscriptProcessor(),
            inserter: inserter
        )

        await coordinator.handle(.pressed)
        let result = LockedBoolean()
        let interruption = Task {
            let preserved = await coordinator.preserveCurrentCaptureForRecovery(
                reason: .applicationQuit
            )
            result.set(preserved)
        }
        await capture.waitUntilStopStarted()

        #expect(coordinator.state == .transcribing)
        #expect(transcriber.callCount == 0)
        capture.finishStop()

        await interruption.value
        #expect(result.value)
        #expect(coordinator.state == .idle)
        #expect(transcriber.callCount == 0)
        #expect(inserter.insertions.isEmpty)
    }

    @Test
    func lifecycleInterruptionDuringReleaseTailWaitsForTheExistingSeal() async {
        let capture = SuspendedCapture()
        let transcriber = FakeTranscriber(result: "must remain recoverable")
        let inserter = FakeInserter()
        let coordinator = DictationCoordinator(
            capture: capture,
            transcriber: transcriber,
            processor: TranscriptProcessor(),
            inserter: inserter
        )

        await coordinator.handle(.pressed)
        let release = Task { await coordinator.handle(.released) }
        await capture.waitUntilStopStarted()
        let result = LockedBoolean()
        let interruption = Task {
            let preserved = await coordinator.preserveCurrentCaptureForRecovery(
                reason: .systemSleep
            )
            result.set(preserved)
        }
        await Task.yield()
        capture.finishStop()

        await interruption.value
        #expect(result.value)
        await release.value
        #expect(coordinator.state == .idle)
        #expect(transcriber.callCount == 0)
        #expect(inserter.insertions.isEmpty)
    }

    @Test
    func lifecycleInterruptionRetainsThePreparedRecoveryJournal() async {
        let capture = FakeRecoveryCapture(samples: [0.1, 0.2])
        let coordinator = DictationCoordinator(
            capture: capture,
            transcriber: FakeTranscriber(result: "must remain recoverable"),
            processor: TranscriptProcessor(),
            inserter: FakeInserter()
        )

        await coordinator.handle(.pressed)
        let preserved = await coordinator.preserveCurrentCaptureForRecovery(
            reason: .applicationQuit
        )

        #expect(preserved)
        #expect(capture.preparedIDs.count == 1)
        #expect(capture.committedIDs.isEmpty)
        #expect(capture.discardedIDs.isEmpty)
    }

    @Test
    func lifecycleInterruptionWaitsForOldReleaseBeforeStartingRecovery() async throws {
        let capture = FakeRecoveryCapture(samples: [0.1, 0.2])
        let transcriber = SuspendedFirstTranscriber(recoveredResult: "recovered")
        let history = FakeHistory()
        let inserter = FakeInserter()
        let coordinator = DictationCoordinator(
            capture: capture,
            transcriber: transcriber,
            processor: TranscriptProcessor(),
            inserter: inserter,
            history: history
        )

        await coordinator.handle(.pressed)
        let release = Task { await coordinator.handle(.released) }
        await transcriber.waitUntilFirstStarted()
        let interruptionFinished = LockedBoolean()
        let interruption = Task {
            let preserved = await coordinator.preserveCurrentCaptureForRecovery(
                reason: .systemSleep
            )
            interruptionFinished.set(preserved)
        }
        while transcriber.cancelCount == 0 {
            await Task.yield()
        }

        #expect(!interruptionFinished.value)
        transcriber.finishFirst(with: "abandoned")
        await release.value
        await interruption.value
        #expect(interruptionFinished.value)

        let originalID = try #require(capture.preparedIDs.only)
        let recovered = await coordinator.recover(RecoveredAudioCapture(
            id: originalID,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            sampleRate: 16_000,
            samples: [0.1, 0.2]
        ))

        #expect(recovered)
        #expect(transcriber.callCount == 2)
        #expect(history.saved.map(\.text) == ["recovered"])
        #expect(inserter.insertions.isEmpty)
        #expect(coordinator.state == .idle)
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
    func cancellationJoinsTheRecordingLimitTaskBeforeStoppingCapture() async {
        let sleeper = SuspendedSleep()
        let capture = SuspendedCapture()
        let coordinator = DictationCoordinator(
            capture: capture,
            transcriber: FakeTranscriber(result: "unused"),
            processor: TranscriptProcessor(),
            inserter: FakeInserter(),
            maximumRecordingNanoseconds: 1,
            sleep: { nanoseconds in
                await sleeper.sleep(nanoseconds: nanoseconds)
            }
        )

        await coordinator.handle(.pressed)
        await sleeper.waitUntilStarted()
        let cancellation = Task { await coordinator.cancelCurrent() }
        await Task.yield()

        #expect(!capture.hasStopStarted)
        sleeper.finish()
        await capture.waitUntilStopStarted()
        capture.finishStop()
        await cancellation.value

        #expect(coordinator.state == .idle)
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
    func activeAudioWithNoRecognizedTextFailsVisibleAndStaysRecoverable() async {
        let capture = FakeRecoveryCapture(
            samples: Array(repeating: 0.1, count: 16_000)
        )
        let history = FakeHistory()
        let inserter = FakeInserter()
        let coordinator = DictationCoordinator(
            capture: capture,
            transcriber: FakeTranscriber(result: ""),
            processor: TranscriptProcessor(),
            inserter: inserter,
            history: history
        )
        var diagnostics: [OperationalDiagnosticEvent] = []
        coordinator.onDiagnosticEvent = { diagnostics.append($0) }

        await coordinator.handle(.pressed)
        await coordinator.handle(.released)

        #expect(
            coordinator.state
                == .failed(.preservedForRecovery(
                    "No text was recognized. The recording is safe for recovery."
                ))
        )
        #expect(history.saved.isEmpty)
        #expect(inserter.insertions.isEmpty)
        #expect(capture.committedIDs.isEmpty)
        #expect(capture.discardedIDs.isEmpty)
        #expect(
            diagnostics.contains {
                $0.name == "transcription.empty_preserved"
            }
        )
    }

    @Test
    func recoveredEmptyPrimaryContinuesThroughHistoryAndInsertion()
        async throws
    {
        let capture = FakeRecoveryCapture(samples: [0.1])
        let history = FakeHistory()
        let inserter = FakeInserter()
        let coordinator = DictationCoordinator(
            capture: capture,
            transcriber: EmptyRecoveredDiagnosticTranscriber(),
            processor: TranscriptProcessor(),
            inserter: inserter,
            history: history
        )

        await coordinator.handle(.pressed)
        await coordinator.handle(.released)

        let saved = try #require(history.saved.only)
        #expect(saved.text == "Recovered beginning and exact ending.")
        #expect(inserter.insertions == [saved.text])
        #expect(capture.committedIDs == [saved.id])
        #expect(capture.discardedIDs.isEmpty)
        #expect(coordinator.state == .idle)
    }

    @Test
    func emptyDecodePreservesExactBeginningAndEndingAcrossJournalReopen()
        async throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "wordhand-empty-recovery-\(UUID().uuidString)"
            )
        defer { try? FileManager.default.removeItem(at: directory) }
        let samples =
            [Float(0.123)]
            + Array(repeating: Float(0.1), count: 15_998)
            + [Float(-0.234)]
        let capture = JournalBackedFakeCapture(
            samples: samples,
            directory: directory
        )
        let coordinator = DictationCoordinator(
            capture: capture,
            transcriber: FakeTranscriber(result: ""),
            processor: TranscriptProcessor(),
            inserter: FakeInserter(),
            history: FakeHistory()
        )

        await coordinator.handle(.pressed)
        await coordinator.handle(.released)

        let reopened = CrashSafeCaptureJournal(directoryURL: directory)
        let recovered = try #require(
            try reopened.recoverableCaptures().only
        )
        #expect(
            recovered.samples.map(\.bitPattern)
                == samples.map(\.bitPattern)
        )
        #expect(
            recovered.samples.first?.bitPattern
                == samples.first?.bitPattern
        )
        #expect(
            recovered.samples.last?.bitPattern
                == samples.last?.bitPattern
        )
    }

    @Test
    func quietAudioWithNoRecognizedTextReturnsIdleAndDiscardsJournal() async {
        let capture = FakeRecoveryCapture(
            samples: Array(repeating: 0.0001, count: 16_000)
        )
        let coordinator = DictationCoordinator(
            capture: capture,
            transcriber: FakeTranscriber(result: ""),
            processor: TranscriptProcessor(),
            inserter: FakeInserter()
        )
        var diagnostics: [OperationalDiagnosticEvent] = []
        coordinator.onDiagnosticEvent = { diagnostics.append($0) }

        await coordinator.handle(.pressed)
        await coordinator.handle(.released)

        #expect(coordinator.state == .idle)
        #expect(capture.committedIDs.isEmpty)
        #expect(capture.discardedIDs == capture.preparedIDs)
        #expect(
            diagnostics.contains {
                $0.name == "transcription.empty_silence"
            }
        )
    }

    @Test
    func quietAudioCleanupFailureStaysVisibleAndDoesNotClaimDiscard() async {
        let capture = FakeRecoveryCapture(
            samples: Array(repeating: 0.0001, count: 16_000),
            discardError: FakeError.failure
        )
        let coordinator = DictationCoordinator(
            capture: capture,
            transcriber: FakeTranscriber(result: ""),
            processor: TranscriptProcessor(),
            inserter: FakeInserter()
        )
        var diagnostics: [OperationalDiagnosticEvent] = []
        coordinator.onDiagnosticEvent = { diagnostics.append($0) }

        await coordinator.handle(.pressed)
        await coordinator.handle(.released)

        #expect(
            coordinator.state
                == .failed(.capture(
                    "Quiet recording cleanup failed: failure"
                ))
        )
        #expect(capture.discardedIDs.isEmpty)
        #expect(
            diagnostics.contains {
                $0.name == "capture_recovery.cleanup_failed"
            }
        )
    }

    @Test
    func whitespaceOnlyFormattingFailsVisibleAndPreservesJournal() async {
        let capture = FakeRecoveryCapture(samples: [0.1])
        let history = FakeHistory()
        let inserter = FakeInserter()
        let coordinator = DictationCoordinator(
            capture: capture,
            transcriber: FakeTranscriber(result: "recognized words"),
            processor: FixedProcessor(result: " \n "),
            inserter: inserter,
            history: history
        )

        await coordinator.handle(.pressed)
        await coordinator.handle(.released)

        #expect(
            coordinator.state
                == .failed(.preservedForRecovery(
                    "Formatting produced no text. "
                        + "The recording is safe for recovery."
                ))
        )
        #expect(history.saved.isEmpty)
        #expect(inserter.insertions.isEmpty)
        #expect(capture.committedIDs.isEmpty)
        #expect(capture.discardedIDs.isEmpty)
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
    func capturesOneImmutableTargetAndFormattingRoutePerDictation() async throws {
        let history = FakeHistory()
        let processor = ContextRecordingProcessor()
        var targetCallCount = 0
        var selectedProfile = TranscriptFormattingProfile.aiCommunication
        let coordinator = DictationCoordinator(
            capture: FakeCapture(samples: [0.1]),
            transcriber: FakeTranscriber(result: "hello"),
            processor: processor,
            inserter: FakeInserter(),
            history: history,
            currentTarget: {
                targetCallCount += 1
                return TranscriptTarget(
                    bundleIdentifier: targetCallCount == 1
                        ? "com.apple.Terminal"
                        : "com.apple.TextEdit",
                    applicationName: targetCallCount == 1
                        ? "Terminal"
                        : "TextEdit"
                )
            },
            currentProcessingContext: { target in
                TranscriptProcessingContext(
                    target: target,
                    formattingProfile: selectedProfile,
                    formattingRouteSource: .applicationOverride,
                    performanceMode: .maximum
                )
            }
        )
        var diagnostics: [OperationalDiagnosticEvent] = []
        coordinator.onDiagnosticEvent = { diagnostics.append($0) }

        await coordinator.handle(.pressed)
        let captured = try #require(coordinator.activeProcessingContext)
        selectedProfile = .professional
        await coordinator.handle(.released)

        #expect(targetCallCount == 1)
        #expect(captured.target.bundleIdentifier == "com.apple.Terminal")
        #expect(captured.formattingProfile == .aiCommunication)
        #expect(processor.contexts == [captured])
        #expect(history.saved.first?.target.bundleIdentifier == "com.apple.Terminal")
        let started = try #require(
            diagnostics.first(where: { $0.name == "dictation.started" })
        )
        let processed = try #require(
            diagnostics.first(where: { $0.name == "processing.completed" })
        )
        #expect(started.attributes["formatting_profile"] == "aiCommunication")
        #expect(started.attributes["formatting_route"] == "applicationOverride")
        #expect(started.attributes["performance_mode"] == "maximum")
        #expect(processed.attributes["formatting_profile"] == "aiCommunication")
        #expect(processed.attributes["formatting_route"] == "applicationOverride")
        #expect(processed.attributes["performance_mode"] == "maximum")
        #expect(coordinator.activeProcessingContext == nil)
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
    func rejectedReplacementIsInsertedLiterallyAndSurfacesTextFreeNotice() async throws {
        let raw =
            "Friday is possible. Friday is preferred. "
            + "Command correction, replace Friday with Monday."
        let history = FakeHistory()
        let inserter = FakeInserter()
        let coordinator = DictationCoordinator(
            capture: FakeCapture(samples: [0.1]),
            transcriber: FakeTranscriber(result: raw),
            processor: TranscriptProcessor(),
            inserter: inserter,
            history: history
        )
        var notices: [TranscriptProcessingNotice] = []
        var events: [OperationalDiagnosticEvent] = []
        coordinator.onProcessingNotice = { notices.append($0) }
        coordinator.onDiagnosticEvent = { events.append($0) }

        await coordinator.handle(.pressed)
        await coordinator.handle(.released)

        let saved = try #require(history.saved.first)
        #expect(saved.rawText == raw)
        #expect(saved.text == raw)
        #expect(inserter.insertions == [raw])
        #expect(
            notices == [.spokenReplacementRejected(.targetRepeated)]
        )
        let rejection = try #require(
            events.first {
                $0.name == "processing.command_rejected"
            }
        )
        #expect(rejection.attributes == ["reason": "target_repeated"])
        #expect(!rejection.attributes.values.contains(raw))
    }

    @Test
    func rejectedReplacementNoticeSurvivesHistoryStatusFailure() async throws {
        let raw =
            "Friday is possible. Friday is preferred. "
            + "Command correction, replace Friday with Monday."
        let history = FakeHistory(updateError: FakeError.failure)
        let inserter = FakeInserter()
        let coordinator = DictationCoordinator(
            capture: FakeCapture(samples: [0.1]),
            transcriber: FakeTranscriber(result: raw),
            processor: TranscriptProcessor(),
            inserter: inserter,
            history: history
        )
        var notices: [TranscriptProcessingNotice] = []
        coordinator.onProcessingNotice = { notices.append($0) }

        await coordinator.handle(.pressed)
        await coordinator.handle(.released)

        #expect(inserter.insertions == [raw])
        #expect(
            notices == [.spokenReplacementRejected(.targetRepeated)]
        )
        #expect(coordinator.state == .failed(.historyStatus("failure")))
    }

    @Test
    func acceptedInsertionReachesHistoryBeforeInsertionWithoutCommandText() async throws {
        let raw =
            "Send the proposal Friday. "
            + "Command correction, insert at noon after Friday."
        let history = FakeHistory()
        let inserter = FakeInserter()
        let coordinator = DictationCoordinator(
            capture: FakeCapture(samples: [0.1]),
            transcriber: FakeTranscriber(result: raw),
            processor: TranscriptProcessor(),
            inserter: inserter,
            history: history
        )
        var notices: [TranscriptProcessingNotice] = []
        coordinator.onProcessingNotice = { notices.append($0) }

        await coordinator.handle(.pressed)
        await coordinator.handle(.released)

        let saved = try #require(history.saved.first)
        #expect(saved.rawText == raw)
        #expect(saved.text == "Send the proposal Friday at noon.")
        #expect(inserter.insertions == ["Send the proposal Friday at noon."])
        #expect(notices.isEmpty)
        #expect(history.updates.count == 1)
        #expect(history.updates[0].0 == saved.id)
        #expect(history.updates[0].1 == .inserted)
    }

    @Test
    func rejectedInsertionIsLiteralAndDiagnosticRemainsTextFree() async throws {
        let raw =
            "Friday is possible. Friday is preferred. "
            + "Command correction, insert not after Friday."
        let history = FakeHistory()
        let inserter = FakeInserter()
        let coordinator = DictationCoordinator(
            capture: FakeCapture(samples: [0.1]),
            transcriber: FakeTranscriber(result: raw),
            processor: TranscriptProcessor(),
            inserter: inserter,
            history: history
        )
        var events: [OperationalDiagnosticEvent] = []
        coordinator.onDiagnosticEvent = { events.append($0) }

        await coordinator.handle(.pressed)
        await coordinator.handle(.released)

        #expect(history.saved.first?.text == raw)
        #expect(inserter.insertions == [raw])
        let rejection = try #require(
            events.first { $0.name == "processing.command_rejected" }
        )
        #expect(rejection.attributes == ["reason": "target_repeated"])
        #expect(!rejection.attributes.values.contains(raw))
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

    @Test
    func recoveredCaptureIsSavedToHistoryWithoutInsertion() async throws {
        let history = FakeHistory()
        let inserter = FakeInserter()
        let id = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let coordinator = DictationCoordinator(
            capture: FakeCapture(samples: []),
            transcriber: FakeTranscriber(result: "beginning and exact ending"),
            processor: TranscriptProcessor(),
            inserter: inserter,
            history: history,
            now: makeClock([10, 10.5])
        )

        let handled = await coordinator.recover(RecoveredAudioCapture(
            id: id,
            createdAt: createdAt,
            sampleRate: 16_000,
            samples: [0.1, 0.2, 0.3]
        ))

        let saved = try #require(history.saved.only)
        #expect(handled)
        #expect(saved.id == id)
        #expect(saved.createdAt == createdAt)
        #expect(saved.text == "beginning and exact ending")
        #expect(
            saved.status
                == .insertionFailed(
                    "Recovered after Wordhand closed before insertion."
                )
        )
        #expect(inserter.insertions.isEmpty)
        #expect(coordinator.state == .idle)
    }

    @Test
    func recoveredActiveAudioStaysRecoverableWhenTextIsStillEmpty() async {
        let id = UUID()
        let capture = FakeRecoveryCapture(samples: [])
        let coordinator = DictationCoordinator(
            capture: capture,
            transcriber: FakeTranscriber(result: ""),
            processor: TranscriptProcessor(),
            inserter: FakeInserter(),
            history: FakeHistory()
        )

        let handled = await coordinator.recover(RecoveredAudioCapture(
            id: id,
            createdAt: Date(),
            sampleRate: 16_000,
            samples: Array(repeating: 0.1, count: 16_000)
        ))

        #expect(!handled)
        #expect(capture.discardedIDs.isEmpty)
        #expect(
            coordinator.state
                == .failed(.preservedForRecovery(
                    "No text was recognized. "
                        + "The recording remains safe for recovery."
                ))
        )
    }

    @Test
    func recoveredQuietAudioIsDiscardedInsteadOfRetryingForever() async {
        let id = UUID()
        let capture = FakeRecoveryCapture(samples: [])
        let coordinator = DictationCoordinator(
            capture: capture,
            transcriber: FakeTranscriber(result: ""),
            processor: TranscriptProcessor(),
            inserter: FakeInserter(),
            history: FakeHistory()
        )

        let handled = await coordinator.recover(RecoveredAudioCapture(
            id: id,
            createdAt: Date(),
            sampleRate: 16_000,
            samples: Array(repeating: 0.0001, count: 16_000)
        ))

        #expect(handled)
        #expect(capture.discardedIDs == [id])
        #expect(coordinator.state == .idle)
    }

    @Test
    func recoveredQuietCleanupFailureDoesNotClaimSuccess() async {
        let id = UUID()
        let capture = FakeRecoveryCapture(
            samples: [],
            discardError: FakeError.failure
        )
        let coordinator = DictationCoordinator(
            capture: capture,
            transcriber: FakeTranscriber(result: ""),
            processor: TranscriptProcessor(),
            inserter: FakeInserter(),
            history: FakeHistory()
        )

        let handled = await coordinator.recover(RecoveredAudioCapture(
            id: id,
            createdAt: Date(),
            sampleRate: 16_000,
            samples: Array(repeating: 0.0001, count: 16_000)
        ))

        #expect(!handled)
        #expect(capture.discardedIDs.isEmpty)
        #expect(
            coordinator.state
                == .failed(.capture(
                    "Quiet recovery cleanup failed: failure"
                ))
        )
    }

    @Test
    func recoveredWhitespaceFormattingPreservesJournal() async {
        let capture = FakeRecoveryCapture(samples: [])
        let coordinator = DictationCoordinator(
            capture: capture,
            transcriber: FakeTranscriber(result: "recognized words"),
            processor: FixedProcessor(result: " \t "),
            inserter: FakeInserter(),
            history: FakeHistory()
        )

        let handled = await coordinator.recover(RecoveredAudioCapture(
            id: UUID(),
            createdAt: Date(),
            sampleRate: 16_000,
            samples: [0.1]
        ))

        #expect(!handled)
        #expect(capture.discardedIDs.isEmpty)
        #expect(
            coordinator.state
                == .failed(.preservedForRecovery(
                    "Formatting produced no text. "
                        + "The recording remains safe for recovery."
                ))
        )
    }

    @Test
    func recoveryJournalDeletesOnlyAfterHistoryCommit() async throws {
        let capture = FakeRecoveryCapture(samples: [0.1, 0.2])
        let history = FakeHistory()
        let coordinator = DictationCoordinator(
            capture: capture,
            transcriber: FakeTranscriber(result: "safe result"),
            processor: TranscriptProcessor(),
            inserter: FakeInserter(),
            history: history
        )

        await coordinator.handle(.pressed)
        await coordinator.handle(.released)

        let saved = try #require(history.saved.only)
        #expect(capture.preparedIDs == [saved.id])
        #expect(capture.committedIDs == [saved.id])
        #expect(capture.discardedIDs.isEmpty)
    }
}

private enum FakeError: Error {
    case failure
}

private final class FakeCapture: AudioCapturing {
    private let samples: [Float]
    private let startError: Error?
    private let onStart: (() -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(
        samples: [Float],
        startError: Error? = nil,
        onStart: (() -> Void)? = nil
    ) {
        self.samples = samples
        self.startError = startError
        self.onStart = onStart
    }

    func start() throws {
        onStart?()
        if let startError {
            throw startError
        }
        startCount += 1
    }

    func stop() async -> [Float] {
        stopCount += 1
        return samples
    }
}

private final class FailingRecoveryPreparationCapture:
    RecoveryManagedAudioCapturing
{
    private let onPrepare: () -> Void
    private let onStart: () -> Void

    init(
        onPrepare: @escaping () -> Void,
        onStart: @escaping () -> Void
    ) {
        self.onPrepare = onPrepare
        self.onStart = onStart
    }

    func prepareRecovery(id: UUID, createdAt: Date, sampleRate: Int) throws {
        onPrepare()
        throw FakeError.failure
    }

    func start() throws {
        onStart()
    }

    func stop() async -> [Float] {
        []
    }

    func markRecoveryCommitted(id: UUID) throws {}

    func discardRecovery(id: UUID) throws {}
}

private final class FakeRecoveryCapture: RecoveryManagedAudioCapturing {
    private let samples: [Float]
    private let discardError: Error?
    private(set) var preparedIDs: [UUID] = []
    private(set) var committedIDs: [UUID] = []
    private(set) var discardedIDs: [UUID] = []

    init(samples: [Float], discardError: Error? = nil) {
        self.samples = samples
        self.discardError = discardError
    }

    func prepareRecovery(id: UUID, createdAt: Date, sampleRate: Int) throws {
        preparedIDs.append(id)
    }

    func start() throws {}

    func stop() async -> [Float] {
        samples
    }

    func markRecoveryCommitted(id: UUID) throws {
        committedIDs.append(id)
    }

    func discardRecovery(id: UUID) throws {
        if let discardError {
            throw discardError
        }
        discardedIDs.append(id)
    }
}

private final class JournalBackedFakeCapture:
    RecoveryManagedAudioCapturing
{
    private let samples: [Float]
    private let journal: CrashSafeCaptureJournal
    private let writer: CrashSafeCaptureWriter

    init(samples: [Float], directory: URL) {
        self.samples = samples
        journal = CrashSafeCaptureJournal(directoryURL: directory)
        writer = CrashSafeCaptureWriter(journal: journal)
    }

    func prepareRecovery(id: UUID, createdAt: Date, sampleRate: Int) throws {
        try writer.beginCapture(
            id: id,
            createdAt: createdAt,
            sampleRate: sampleRate
        )
    }

    func start() throws {}

    func stop() async -> [Float] {
        _ = writer.enqueue(samples)
        try? await writer.seal()
        return samples
    }

    func markRecoveryCommitted(id: UUID) throws {
        try journal.discard(id: id)
    }

    func discardRecovery(id: UUID) throws {
        try journal.discard(id: id)
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

private final class EmptyRecoveredDiagnosticTranscriber:
    Transcribing,
    TranscriptionDiagnosticsProviding,
    @unchecked Sendable
{
    let modelID = "empty-recovery-fake"

    func warmUp() async throws {}

    func transcribe(_ audio: [Float]) async throws -> String {
        "Recovered beginning and exact ending."
    }

    func lastRunDiagnostics() async -> TranscriptionRunDiagnostics {
        TranscriptionRunDiagnostics(
            primaryWordCount: 0,
            finalWordCount: 5,
            fullRetryPerformed: true,
            emptyTranscriptRecoveryOutcome: .recovered
        )
    }
}

private final class SuspendedCapture: AudioCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var startCount = 0
    private var stopStarted = false
    private var stopStartedContinuation: CheckedContinuation<Void, Never>?
    private var stopContinuation: CheckedContinuation<[Float], Never>?
    var onInputStopped: (@MainActor () -> Void)?

    var hasStopStarted: Bool {
        lock.withLock { stopStarted }
    }

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

    @MainActor
    func finishStop() {
        onInputStopped?()
        let continuation = lock.withLock {
            let continuation = stopContinuation
            stopContinuation = nil
            return continuation
        }
        continuation?.resume(returning: [])
    }

    @MainActor
    func repeatInputStopped() {
        onInputStopped?()
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

private final class SuspendedFirstTranscriber:
    Transcribing,
    @unchecked Sendable
{
    let modelID = "suspended-first"
    private let lock = NSLock()
    private let recoveredResult: String
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var firstResultContinuation: CheckedContinuation<String, Never>?
    private var firstDidStart = false
    private var storedCallCount = 0
    private var storedCancelCount = 0

    var callCount: Int {
        lock.withLock { storedCallCount }
    }

    var cancelCount: Int {
        lock.withLock { storedCancelCount }
    }

    init(recoveredResult: String) {
        self.recoveredResult = recoveredResult
    }

    func warmUp() async throws {}

    func transcribe(_ audio: [Float]) async throws -> String {
        let call = lock.withLock {
            storedCallCount += 1
            return storedCallCount
        }
        guard call == 1 else { return recoveredResult }
        let started = lock.withLock {
            firstDidStart = true
            let continuation = startedContinuation
            startedContinuation = nil
            return continuation
        }
        started?.resume()
        return await withCheckedContinuation { continuation in
            lock.withLock {
                firstResultContinuation = continuation
            }
        }
    }

    func waitUntilFirstStarted() async {
        if lock.withLock({ firstDidStart }) { return }
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                if firstDidStart {
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

    func finishFirst(with result: String) {
        let continuation = lock.withLock {
            let continuation = firstResultContinuation
            firstResultContinuation = nil
            return continuation
        }
        continuation?.resume(returning: result)
    }

    func cancel() {
        lock.withLock {
            storedCancelCount += 1
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
    private let updateError: Error?

    init(updateError: Error? = nil) {
        self.updateError = updateError
    }

    func save(_ record: TranscriptRecord) throws {
        saved.append(record)
    }

    func updateStatus(id: UUID, status: TranscriptInsertionStatus) throws {
        if let updateError {
            throw updateError
        }
        updates.append((id, status))
    }
}

private final class ContextRecordingProcessor:
    ContextualTranscriptProcessing,
    @unchecked Sendable
{
    private(set) var contexts: [TranscriptProcessingContext] = []

    func process(_ text: String, target: TranscriptTarget) async -> String {
        text
    }

    func process(
        _ text: String,
        context: TranscriptProcessingContext
    ) async -> String {
        contexts.append(context)
        return text
    }
}

private final class FixedProcessor:
    TranscriptProcessing,
    @unchecked Sendable
{
    private let result: String

    init(result: String) {
        self.result = result
    }

    func process(_ text: String, target: TranscriptTarget) async -> String {
        result
    }
}

private func makeClock(_ values: [TimeInterval]) -> () -> TimeInterval {
    var iterator = values.makeIterator()
    return { iterator.next() ?? values.last ?? 0 }
}

private final class LockedBoolean: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    var value: Bool {
        lock.withLock { stored }
    }

    func set(_ value: Bool) {
        lock.withLock {
            stored = value
        }
    }
}

private extension Collection {
    var only: Element? {
        count == 1 ? first : nil
    }
}
