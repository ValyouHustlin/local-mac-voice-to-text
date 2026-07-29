import AppKit
import ArgumentParser
import Foundation
import WordhandCore
import WhisperKit

@main
struct Wordhand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wordhand",
        abstract: "Private, on-device macOS dictation. Hold Control-Space, speak, release.",
        subcommands: [Run.self, Setup.self, Doctor.self, Models.self, Install.self],
        defaultSubcommand: Run.self
    )
}

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the daemon (default)."
    )

    @Flag(name: .long, help: "Skip permission checks at startup.")
    var skipDoctor: Bool = false

    @Flag(name: .long, help: "Print every keyboard event the tap sees (debug).")
    var debugHotkey: Bool = false

    @Flag(name: .long, help: "Write each capture to /tmp/wordhand-last.wav for inspection.")
    var dumpWav: Bool = false

    @Flag(name: .long, help: "Disable the on-screen recording overlay.")
    var noOverlay: Bool = false

    @Option(name: .long, help: "Model id to use. Defaults to the recommended model.")
    var model: String?

    @Option(name: .long, help: "Override the local data directory for development.")
    var dataDirectory: String?

    @Flag(
        name: .long,
        help: "Explicitly opt in to a bounded development test of global input."
    )
    var allowGlobalInputTest: Bool = false

    @Option(
        name: .long,
        help: "Self-terminate a global-input test after 1–30 seconds."
    )
    var globalInputTestTimeoutSeconds: Int?

    func run() throws {
        let environment = ProcessInfo.processInfo.environment
        if GlobalInputSafetyPolicy.blocksGlobalInput(environment: environment) {
            FileHandle.standardError.write(Data(
                """
                global input disabled because WORDHAND_SAFE is set
                no event tap or text injector was installed

                """.utf8
            ))
            throw ExitCode(1)
        }
        if GlobalInputSafetyPolicy.hasInvalidDevelopmentTestConfiguration(
            optedIn: allowGlobalInputTest,
            timeoutSeconds: globalInputTestTimeoutSeconds
        ) {
            FileHandle.standardError.write(Data(
                """
                development tests require both --allow-global-input-test and \
                --global-input-test-timeout-seconds 1...\(GlobalInputSafetyPolicy.maximumDevelopmentTestSeconds)

                """.utf8
            ))
            throw ExitCode(1)
        }
        let developmentTestTimeout =
            GlobalInputSafetyPolicy.validatedDevelopmentTestTimeout(
                optedIn: allowGlobalInputTest,
                timeoutSeconds: globalInputTestTimeoutSeconds
            )

        if dataDirectory == nil {
            do {
                if try ApplicationData.migrateLegacyDataIfNeeded() {
                    FileHandle.standardError.write(Data(
                        "migrated existing local data from Parrot to Wordhand\n".utf8
                    ))
                }
            } catch {
                FileHandle.standardError.write(Data(
                    "couldn't migrate existing Parrot data: \(error)\n".utf8
                ))
                throw ExitCode(1)
            }
        }

        if !skipDoctor {
            let checks = DoctorReport.run()
            if !DoctorReport.allOK(checks) {
                FileHandle.standardError.write(Data("startup checks failed:\n".utf8))
                DoctorReport.print(checks)
                FileHandle.standardError.write(Data("\nfix the above or pass --skip-doctor\n".utf8))
                throw ExitCode(1)
            }
        }

        let customDataDirectory = dataDirectory.map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        let dictionaryURL = customDataDirectory?.appendingPathComponent("dictionary.json")
            ?? DictionaryStore.defaultFileURL()
        let historyURL = customDataDirectory?.appendingPathComponent("history.sqlite")
            ?? TranscriptHistoryStore.defaultFileURL()
        let settingsURL = customDataDirectory?.appendingPathComponent("settings.json")
            ?? SettingsStore.defaultFileURL()
        let runtimeLockURL = settingsURL.deletingLastPathComponent()
            .appendingPathComponent("wordhand.lock")
        let instanceLock = try SingleInstanceLock(fileURL: runtimeLockURL)
        let settingsStore = SettingsStore(fileURL: settingsURL)
        let settings: AppSettings
        do {
            settings = try settingsStore.load()
        } catch {
            settings = AppSettings()
            FileHandle.standardError.write(Data(
                "settings load failed; using defaults without overwriting the file: \(error)\n".utf8
            ))
        }

        let chosenModel: TranscriptionModel
        let chosenModelID = model ?? settings.modelID
        guard let selectedModel = ModelRegistry.find(chosenModelID) else {
            FileHandle.standardError.write(Data("unknown model: \(chosenModelID)\n".utf8))
            FileHandle.standardError.write(Data("run `wordhand models list` to see options.\n".utf8))
            throw ExitCode(1)
        }
        chosenModel = selectedModel

        let app = NSApplication.shared
        MainActor.assumeIsolated {
            AppIdentity.configure(app)
        }
        let dictionary = MainActor.assumeIsolated {
            DictionaryController(store: DictionaryStore(fileURL: dictionaryURL))
        }
        let transcriber = WhisperKitTranscriber(
            model: chosenModel,
            vocabulary: dictionary.vocabulary
        )
        let warmupSemaphore = DispatchSemaphore(value: 0)
        var warmupError: Error?
        Task.detached {
            do {
                try await transcriber.warmUp()
            } catch {
                warmupError = error
            }
            warmupSemaphore.signal()
        }
        warmupSemaphore.wait()
        if let warmupError {
            FileHandle.standardError.write(Data("warmup failed: \(warmupError)\n".utf8))
            throw ExitCode(1)
        }

        let monitor = HotkeyMonitor(bindings: settings.hotkeys, debug: debugHotkey)
        let capture = AudioCapture()
        let processor = AppAwareTranscriptProcessor(
            dictionaryProcessor: dictionary.processor,
            profile: settings.formattingProfile
        )
        let inserter = MacTextInserter()
        let historyStore = try TranscriptHistoryStore(fileURL: historyURL)
        let retentionDays: Int? = settings.historyRetentionDays
        if let retentionDays,
           let retentionCutoff = Calendar.current.date(
               byAdding: .day,
               value: -retentionDays,
               to: Date()
           )
        {
            try historyStore.prune(before: retentionCutoff)
        }
        let history = MainActor.assumeIsolated {
            HistoryController(store: historyStore, dictionary: dictionary, inserter: inserter)
        }
        let dumpWav = self.dumpWav
        let overlay: RecordingOverlay? = noOverlay ? nil : MainActor.assumeIsolated { RecordingOverlay() }
        let audioCues = MainActor.assumeIsolated {
            AudioCuePlayer(isEnabled: settings.soundEffectsEnabled)
        }
        if let overlay {
            capture.onLevel = { level in overlay.pushLevel(level) }
        }
        let settingsController = MainActor.assumeIsolated {
            SettingsController(store: settingsStore, settings: settings)
        }
        let menuBar = MainActor.assumeIsolated {
            MenuBarController(
                modelID: chosenModel.id,
                settings: settings,
                onOpenSettings: { settingsController.showSettings() },
                onOpenHistory: { history.showHistory() },
                onOpenDictionary: { dictionary.showDictionary() },
                onCorrectLast: { dictionary.correctLatestTranscript() }
            )
        }
        let appDelegate = MainActor.assumeIsolated {
            WordhandAppDelegate(onOpenPrimaryWindow: { settingsController.showSettings() })
        }
        let coordinator = MainActor.assumeIsolated {
            DictationCoordinator(
                capture: capture,
                transcriber: transcriber,
                processor: processor,
                inserter: inserter,
                history: historyStore,
                insertionMode: settings.insertionMode,
                language: chosenModel.languages.first,
                audioSampleRate: AudioCapture.targetSampleRate,
                currentTarget: currentTranscriptTarget
            )
        }
        MainActor.assumeIsolated {
            app.delegate = appDelegate
            overlay?.onCancel = {
                audioCues.play(.cancel)
                monitor.cancelActiveRecording()
                Task { @MainActor in
                    await coordinator.cancelCurrent()
                }
            }
            settingsController.onSettingsChange = { updated in
                monitor.updateBindings(updated.hotkeys)
                coordinator.updateInsertionMode(updated.insertionMode)
                processor.update(profile: updated.formattingProfile)
                audioCues.isEnabled = updated.soundEffectsEnabled
                menuBar.updateSettings(updated)
                if !updated.showOverlay {
                    overlay?.hide()
                }
            }
            settingsController.onShortcutCaptureChange = { capturing in
                monitor.setSuspended(capturing)
            }
            coordinator.onStateChange = { state in
                switch state {
                case .idle:
                    overlay?.hide()
                    menuBar.setRecording(false)
                case .recording:
                    FileHandle.standardError.write(Data("● recording\n".utf8))
                    audioCues.play(.start)
                    if settingsController.settings.showOverlay {
                        overlay?.show(.recording)
                    }
                    menuBar.setRecording(true)
                case .transcribing:
                    if settingsController.settings.showOverlay {
                        overlay?.show(.transcribing)
                    }
                    menuBar.setTranscribing()
                case .processing:
                    if settingsController.settings.showOverlay {
                        overlay?.show(.transcribing)
                    }
                    menuBar.setTranscribing()
                case .inserting:
                    if settingsController.settings.showOverlay {
                        overlay?.show(.finishing)
                    }
                    menuBar.setTranscribing()
                case .failed(let failure):
                    FileHandle.standardError.write(Data("dictation failed: \(failure)\n".utf8))
                    overlay?.hide()
                    menuBar.setRecording(false)
                    switch failure {
                    case .history:
                        menuBar.setFailure("history unavailable · text not inserted")
                    case .historyStatus:
                        menuBar.setFailure("inserted · history status needs attention")
                    case .insertion:
                        menuBar.setFailure("not inserted · saved in history")
                    case .capture, .transcription:
                        menuBar.setFailure("dictation failed · try again")
                    }
                }
            }
            coordinator.onCapture = { samples in
                audioCues.play(.stop)
                let seconds = Double(samples.count) / AudioCapture.targetSampleRate
                let rms = computeRMS(samples)
                FileHandle.standardError.write(Data(
                    String(format: "○ captured %.2fs · rms %.3f\n", seconds, rms).utf8
                ))
                if dumpWav, !samples.isEmpty {
                    let path = "/tmp/wordhand-last.wav"
                    do {
                        try WAVWriter.write(samples: samples, sampleRate: 16_000, to: path)
                        FileHandle.standardError.write(Data("  wrote \(path)\n".utf8))
                    } catch {
                        FileHandle.standardError.write(Data("  wav write failed: \(error)\n".utf8))
                    }
                }
            }
            coordinator.onTranscript = { text, elapsed in
                FileHandle.standardError.write(Data(
                    String(format: "→ %.2fs · %@\n", elapsed, text).utf8
                ))
                dictionary.rememberLatestTranscript(text)
                menuBar.setHasLatestTranscript(true)
            }
            coordinator.onProcessingDuration = { elapsed in
                FileHandle.standardError.write(Data(
                    String(format: "  local formatting %.2fs\n", elapsed).utf8
                ))
            }
            coordinator.onRecordingLimitReached = {
                FileHandle.standardError.write(Data(
                    "recording reached the 10-minute safety limit; processing captured audio\n".utf8
                ))
                menuBar.setFailure("10-minute limit reached · processing")
            }
            coordinator.onHistoryChange = {
                history.reloadIfVisible()
            }
        }

        do {
            try monitor.start { event in
                Task { @MainActor in
                    await coordinator.handle(event)
                }
            }
        } catch {
            FileHandle.standardError.write(Data("failed to register hotkey tap: \(error)\n".utf8))
            FileHandle.standardError.write(Data("run `wordhand setup` to configure permissions.\n".utf8))
            throw ExitCode(1)
        }

        var globalInputTestTimer: DispatchSourceTimer?
        if let developmentTestTimeout {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + .seconds(developmentTestTimeout))
            timer.setEventHandler {
                FileHandle.standardError.write(Data(
                    "global-input test timeout reached; shutting down\n".utf8
                ))
                monitor.stop()
                NSApp.terminate(nil)
            }
            timer.resume()
            globalInputTestTimer = timer
            FileHandle.standardError.write(Data(
                """
                development global-input test enabled for \(developmentTestTimeout)s
                immediate kill path: /usr/bin/pkill -x wordhand

                """.utf8
            ))
        }

        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler {
            FileHandle.standardError.write(Data("\nshutting down\n".utf8))
            monitor.stop()
            NSApp.terminate(nil)
        }
        sigint.resume()
        signal(SIGINT, SIG_IGN)

        let shortcuts = settings.hotkeys.map {
            let behavior = $0.action == .toggleRecording ? "tap" : "hold"
            return "\($0.displayName) \(behavior)"
        }.joined(separator: ", ")
        FileHandle.standardError.write(Data(
            "listening on \(shortcuts) · model: \(chosenModel.id) · ^C to quit\n".utf8
        ))
        withExtendedLifetime((instanceLock, globalInputTestTimer)) {
            app.run()
        }
    }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check microphone, accessibility, and Control-Space availability."
    )

    func run() throws {
        let checks = DoctorReport.run()
        DoctorReport.print(checks)
        if !DoctorReport.allOK(checks) {
            throw ExitCode(1)
        }
    }
}

struct Models: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage transcription models.",
        subcommands: [List.self, Download.self, Benchmark.self]
    )

    struct List: ParsableCommand {
        func run() throws {
            for m in ModelRegistry.shared {
                let star = m.recommended ? "★" : " "
                let id = m.id.padding(toLength: 26, withPad: " ", startingAt: 0)
                let langs = "[\(m.languages.joined(separator: ","))]"
                    .padding(toLength: 9, withPad: " ", startingAt: 0)
                let size = String(format: "%5d MB", m.sizeMB)
                print("\(star) \(id) \(size)  \(langs)  \(m.displayName)")
            }
        }
    }

    struct Download: ParsableCommand {
        @Argument(help: "Model id to download.") var id: String

        func run() throws {
            guard let m = ModelRegistry.find(id) else {
                print("unknown model: \(id)")
                throw ExitCode(1)
            }
            let t = WhisperKitTranscriber(model: m)

            let sem = DispatchSemaphore(value: 0)
            var capturedError: Error?
            Task.detached {
                do { try await t.warmUp() } catch { capturedError = error }
                sem.signal()
            }
            sem.wait()
            if let e = capturedError { throw e }
        }
    }

    struct Benchmark: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Measure one model against a local audio file."
        )

        @Argument(help: "Path to an audio file.")
        var audioPath: String

        @Option(name: .long, help: "Model id. Defaults to the recommended model.")
        var model: String?

        @Flag(
            name: .long,
            help: "Condition decoding with Wordhand's bundled editable starter vocabulary."
        )
        var defaultVocabulary: Bool = false

        @Option(
            name: .long,
            help: "Comma-separated vocabulary terms for a controlled conditioning benchmark."
        )
        var vocabularyTerms: String?

        func run() throws {
            let modelID = model ?? ModelRegistry.recommended()?.id
            guard let modelID, let selectedModel = ModelRegistry.find(modelID) else {
                FileHandle.standardError.write(Data("unknown model: \(model ?? "none")\n".utf8))
                throw ExitCode(1)
            }

            let expandedPath = NSString(string: audioPath).expandingTildeInPath
            let audio = try AudioProcessor.loadAudioAsFloatArray(fromPath: expandedPath)
            guard !audio.isEmpty else {
                FileHandle.standardError.write(Data("audio file contained no samples\n".utf8))
                throw ExitCode(1)
            }

            let vocabulary: DictionaryVocabularySource
            if let vocabularyTerms {
                let terms = vocabularyTerms
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                vocabulary = DictionaryVocabularySource(entries: terms.map {
                    DictionaryEntry(spokenForm: $0, replacement: $0)
                })
            } else if defaultVocabulary {
                let seed = try BundledDictionaryVocabulary.load()
                let installedAt = Date(timeIntervalSince1970: 0)
                vocabulary = DictionaryVocabularySource(entries: seed.terms.enumerated().map {
                    DictionaryEntry(
                        spokenForm: $0.element,
                        replacement: $0.element,
                        origin: .starterVocabulary,
                        starterVocabularyOrder: $0.offset,
                        createdAt: installedAt,
                        updatedAt: installedAt
                    )
                })
            } else {
                vocabulary = DictionaryVocabularySource()
            }
            let transcriber = WhisperKitTranscriber(
                model: selectedModel,
                vocabulary: vocabulary
            )
            let semaphore = DispatchSemaphore(value: 0)
            let resultBox = ModelBenchmarkResultBox()
            Task.detached {
                do {
                    let warmupStarted = ProcessInfo.processInfo.systemUptime
                    try await transcriber.warmUp()
                    let warmupDuration =
                        ProcessInfo.processInfo.systemUptime - warmupStarted

                    let transcriptionStarted = ProcessInfo.processInfo.systemUptime
                    let transcript = try await transcriber.transcribe(audio)
                    let transcriptionDuration =
                        ProcessInfo.processInfo.systemUptime - transcriptionStarted
                    resultBox.store(.success(ModelBenchmarkResult(
                        transcript: transcript,
                        warmupDuration: warmupDuration,
                        transcriptionDuration: transcriptionDuration
                    )))
                } catch {
                    resultBox.store(.failure(error))
                }
                semaphore.signal()
            }
            semaphore.wait()
            let result = try resultBox.load().get()

            let audioDuration = Double(audio.count) / AudioCapture.targetSampleRate
            let realTimeFactor = result.transcriptionDuration / audioDuration
            print("model: \(selectedModel.id)")
            print(String(format: "audio: %.2fs", audioDuration))
            print(String(format: "warmup: %.3fs", result.warmupDuration))
            print(String(format: "transcription: %.3fs", result.transcriptionDuration))
            print(String(format: "real-time factor: %.3fx", realTimeFactor))
            print(
                "transcript: "
                    + result.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }
}

private struct ModelBenchmarkResult {
    let transcript: String
    let warmupDuration: TimeInterval
    let transcriptionDuration: TimeInterval
}

private final class ModelBenchmarkResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<ModelBenchmarkResult, Error>?

    func store(_ result: Result<ModelBenchmarkResult, Error>) {
        lock.withLock {
            self.result = result
        }
    }

    func load() -> Result<ModelBenchmarkResult, Error> {
        lock.withLock {
            result ?? .failure(ModelBenchmarkError.missingResult)
        }
    }
}

private enum ModelBenchmarkError: Error {
    case missingResult
}
