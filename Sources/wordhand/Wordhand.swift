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
        subcommands: [
            Run.self,
            Format.self,
            Setup.self,
            Doctor.self,
            Models.self,
            DictionaryCommands.self,
            Quality.self,
            DiagnosticsCommands.self,
            CaptureRecoveryFixture.self,
            Install.self,
            OverlayPreview.self,
        ],
        defaultSubcommand: Run.self
    )
}

struct CaptureRecoveryFixture: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "capture-recovery-fixture",
        abstract: "Internal microphone-free crash-recovery fixture.",
        shouldDisplay: false
    )

    @Argument(help: "write or inspect")
    var action: String

    @Option(name: .long)
    var dataDirectory: String

    @Option(name: .long)
    var id: String = "00000000-0000-0000-0000-000000000001"

    func run() throws {
        let directory = URL(fileURLWithPath: dataDirectory, isDirectory: true)
        let journal = CrashSafeCaptureJournal(directoryURL: directory)
        let samples: [Float] = [
            Float(bitPattern: 0x8000_0000),
            0.1,
            -0.2,
            42.5,
            -1,
            0,
            Float(bitPattern: 0x3f7f_ffff),
        ]
        switch action {
        case "write":
            guard let captureID = UUID(uuidString: id) else {
                throw ValidationError("invalid fixture id")
            }
            try journal.beginCapture(
                id: captureID,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                sampleRate: 16_000
            )
            try journal.append(Array(samples.prefix(3)))
            try journal.append(Array(samples.dropFirst(3)))
            print(Self.receipt(samples))
            fflush(stdout)
            while true {
                Thread.sleep(forTimeInterval: 60)
            }
        case "inspect":
            guard let recovered = try journal.recoverableCaptures().first else {
                throw ValidationError("no recovered fixture")
            }
            print(Self.receipt(recovered.samples))
        default:
            throw ValidationError("action must be write or inspect")
        }
    }

    private static func receipt(_ samples: [Float]) -> String {
        let checksum = samples.reduce(UInt64(0xcbf2_9ce4_8422_2325)) {
            ($0 ^ UInt64($1.bitPattern)) &* 0x0000_0100_0000_01b3
        }
        return [
            "samples=\(samples.count)",
            "first=\(samples.first?.bitPattern ?? 0)",
            "last=\(samples.last?.bitPattern ?? 0)",
            "checksum=\(checksum)",
        ].joined(separator: " ")
    }
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
        let isBundledApplication = Bundle.main.bundleURL.pathExtension == "app"
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
                if isBundledApplication {
                    FileHandle.standardError.write(Data(
                        "\nWordhand.app will stay open so permissions can be repaired.\n".utf8
                    ))
                } else {
                    FileHandle.standardError.write(Data(
                        "\nfix the above or pass --skip-doctor\n".utf8
                    ))
                    throw ExitCode(1)
                }
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
        let qualityAudioURL = customDataDirectory?
            .appendingPathComponent("Quality Recordings", isDirectory: true)
            ?? LocalQualityAudioArchive.defaultDirectoryURL()
        let pendingCapturesURL = customDataDirectory?
            .appendingPathComponent("Pending Captures", isDirectory: true)
            ?? CrashSafeCaptureJournal.defaultDirectoryURL()
        let diagnosticsURL = customDataDirectory?
            .appendingPathComponent("Diagnostics", isDirectory: true)
            ?? OperationalDiagnosticsStore.defaultDirectoryURL()
        let runtimeLockURL = settingsURL.deletingLastPathComponent()
            .appendingPathComponent("wordhand.lock")
        let instanceLock = try SingleInstanceLock(fileURL: runtimeLockURL)
        let settingsStore = SettingsStore(fileURL: settingsURL)
        let diagnosticsStore = try OperationalDiagnosticsStore(
            directoryURL: diagnosticsURL
        )
        let appSessionID = UUID()
        let appStartedAt = ProcessInfo.processInfo.systemUptime
        let recordDiagnostic:
            @Sendable (OperationalDiagnosticEvent) -> Void = { event in
            do {
                try diagnosticsStore.append(event)
            } catch {
                FileHandle.standardError.write(Data(
                    "diagnostics write failed: \(error)\n".utf8
                ))
            }
        }
        recordDiagnostic(OperationalDiagnosticEvent(
            severity: .info,
            name: "app.starting",
            sessionID: appSessionID,
            attributes: [
                "build": Bundle.main.object(
                    forInfoDictionaryKey: "CFBundleVersion"
                ) as? String ?? "cli",
            ]
        ))
        let settings: AppSettings
        do {
            settings = try settingsStore.load()
        } catch {
            settings = AppSettings()
            recordDiagnostic(OperationalDiagnosticEvent(
                severity: .warning,
                name: "settings.load_failed",
                sessionID: appSessionID,
                attributes: ["reason": String(describing: error)]
            ))
            FileHandle.standardError.write(Data(
                "settings load failed; using defaults without overwriting the file: \(error)\n".utf8
            ))
        }

        let chosenModel: TranscriptionModel
        let chosenModelID = model ?? settings.modelID
        guard let selectedModel = ModelRegistry.find(chosenModelID) else {
            recordDiagnostic(OperationalDiagnosticEvent(
                severity: .error,
                name: "startup.failed",
                sessionID: appSessionID,
                attributes: [
                    "stage": "model_selection",
                    "model_id": chosenModelID,
                ]
            ))
            FileHandle.standardError.write(Data("unknown model: \(chosenModelID)\n".utf8))
            FileHandle.standardError.write(Data("run `wordhand models list` to see options.\n".utf8))
            throw ExitCode(1)
        }
        chosenModel = selectedModel
        recordDiagnostic(OperationalDiagnosticEvent(
            severity: .info,
            name: "app.launched",
            sessionID: appSessionID,
            attributes: [
                "model_id": chosenModel.id,
                "formatting_profile": settings.formattingProfile.rawValue,
                "performance_mode": settings.performanceMode.rawValue,
                "insertion_mode": settings.insertionMode.rawValue,
                "build": Bundle.main.object(
                    forInfoDictionaryKey: "CFBundleVersion"
                ) as? String ?? "cli",
            ]
        ))

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
        let monitor = HotkeyMonitor(bindings: settings.hotkeys, debug: debugHotkey)
        let recoveryJournal = CrashSafeCaptureJournal(
            directoryURL: pendingCapturesURL
        )
        let capture = AudioCapture(recoveryJournal: recoveryJournal)
        let processor = AppAwareTranscriptProcessor(
            dictionaryProcessor: dictionary.processor,
            profile: settings.formattingProfile,
            performanceMode: settings.performanceMode
        )
        let inserter = MacTextInserter()
        let historyStore = try TranscriptHistoryStore(fileURL: historyURL)
        let qualityAudioArchive = LocalQualityAudioArchive(directoryURL: qualityAudioURL)
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
        if settings.qualityAudioRetentionEnabled,
           let qualityCutoff = Calendar.current.date(
               byAdding: .day,
               value: -settings.qualityAudioRetentionDays,
               to: Date()
           )
        {
            try qualityAudioArchive.prune(olderThan: qualityCutoff)
            _ = try qualityAudioArchive.enforceMaximumBytes(
                settings.qualityAudioMaximumBytes
            )
        }
        let history = MainActor.assumeIsolated {
            HistoryController(
                store: historyStore,
                dictionary: dictionary,
                inserter: inserter,
                qualityAudioArchive: qualityAudioArchive
            )
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
            SettingsController(
                store: settingsStore,
                settings: settings,
                activeModelID: chosenModel.id
            )
        }
        let startupPermissions = MainActor.assumeIsolated {
            settingsController.permissionStatus
        }
        recordDiagnostic(OperationalDiagnosticEvent(
            severity: startupPermissions.globalInputReady ? .info : .warning,
            name: "permissions.snapshot",
            sessionID: appSessionID,
            attributes: [
                "accessibility": String(
                    startupPermissions.accessibilityGranted
                ),
                "input_monitoring": String(
                    startupPermissions.inputMonitoringGranted
                ),
                "microphone": String(
                    startupPermissions.microphone == .granted
                ),
            ]
        ))
        let menuBar = MainActor.assumeIsolated {
            var controller: MenuBarController!
            controller = MenuBarController(
                modelID: chosenModel.id,
                settings: settings,
                onOpenSettings: { settingsController.showSettings() },
                onOpenHistory: { history.showHistory() },
                onOpenDictionary: { dictionary.showDictionary() },
                onCorrectLast: { dictionary.correctLatestTranscript() },
                onImproveLast: { history.improveLatestTranscript() },
                onUndoLast: {
                    do {
                        try inserter.undoLastInsertion()
                    } catch {
                        NSSound.beep()
                        controller.setFailure(error.localizedDescription)
                    }
                }
            )
            if let latest = try? history.records(matching: "").first {
                dictionary.rememberLatestTranscript(latest.text)
                controller.setHasLatestTranscript(true)
            }
            return controller!
        }
        let readiness = MainActor.assumeIsolated {
            RuntimeReadiness()
        }
        var modelWarmupTask: Task<Void, Never>?
        var diagnosticsHeartbeatTask: Task<Void, Never>?
        let appDelegate = MainActor.assumeIsolated {
            WordhandAppDelegate(
                onOpenPrimaryWindow: { settingsController.showSettings() },
                onTerminate: {
                    recordDiagnostic(OperationalDiagnosticEvent(
                        severity: .info,
                        name: "app.terminated",
                        sessionID: appSessionID
                    ))
                    modelWarmupTask?.cancel()
                    diagnosticsHeartbeatTask?.cancel()
                    monitor.stop()
                }
            )
        }
        let coordinator = MainActor.assumeIsolated {
            DictationCoordinator(
                capture: capture,
                transcriber: transcriber,
                processor: processor,
                inserter: inserter,
                history: historyStore,
                insertionMode: settings.insertionMode,
                streamingEnabled: settings.performanceMode.enablesRollingTranscription,
                language: chosenModel.languages.first,
                audioSampleRate: AudioCapture.targetSampleRate,
                currentTarget: currentTranscriptTarget,
                diagnosticSessionID: appSessionID
            )
        }
        let startHotkeyMonitor = {
            try monitor.start { event in
                Task { @MainActor in
                    await coordinator.handle(event)
                }
            }
        }
        MainActor.assumeIsolated {
            app.delegate = appDelegate
            coordinator.onDiagnosticEvent = recordDiagnostic
            overlay?.onCancel = {
                audioCues.play(.cancel)
                monitor.cancelActiveRecording()
                Task { @MainActor in
                    await coordinator.cancelCurrent()
                }
            }
            settingsController.onSettingsChange = { updated in
                recordDiagnostic(OperationalDiagnosticEvent(
                    severity: .info,
                    name: "settings.changed",
                    sessionID: appSessionID,
                    attributes: [
                        "model_id": updated.modelID,
                        "formatting_profile": updated.formattingProfile.rawValue,
                        "performance_mode": updated.performanceMode.rawValue,
                        "insertion_mode": updated.insertionMode.rawValue,
                        "hotkey_count": String(updated.hotkeys.count),
                        "quality_audio_enabled": String(
                            updated.qualityAudioRetentionEnabled
                        ),
                    ]
                ))
                monitor.updateBindings(updated.hotkeys)
                coordinator.updateInsertionMode(updated.insertionMode)
                coordinator.updateStreamingEnabled(
                    updated.performanceMode.enablesRollingTranscription
                )
                processor.update(
                    profile: updated.formattingProfile,
                    performanceMode: updated.performanceMode
                )
                if updated.performanceMode == .maximum {
                    let target = currentTranscriptTarget()
                    Task {
                        await processor.prepare(target: target)
                    }
                }
                audioCues.isEnabled = updated.soundEffectsEnabled
                menuBar.updateSettings(updated)
                if !updated.showOverlay {
                    overlay?.hide()
                }
                if updated.qualityAudioRetentionEnabled {
                    let maximumBytes = updated.qualityAudioMaximumBytes
                    Task.detached {
                        do {
                            _ = try qualityAudioArchive.enforceMaximumBytes(
                                maximumBytes
                            )
                        } catch {
                            FileHandle.standardError.write(Data(
                                "quality storage cleanup failed: \(error)\n".utf8
                            ))
                        }
                    }
                }
            }
            inserter.onUndoAvailabilityChange = { available in
                Task { @MainActor in
                    menuBar.setCanUndoLastInsertion(available)
                }
            }
            settingsController.onShortcutCaptureChange = { capturing in
                monitor.setSuspended(capturing)
            }
            settingsController.onRelaunchRequested = {
                try ApplicationRelauncher.relaunchCurrentApplication()
            }
            settingsController.onRevealQualityAudio = {
                try? qualityAudioArchive.ensureDirectory()
                NSWorkspace.shared.open(qualityAudioArchive.directoryURL)
            }
            settingsController.onDeleteQualityAudio = {
                try qualityAudioArchive.deleteAll()
            }
            settingsController.onRevealDiagnostics = {
                NSWorkspace.shared.open(diagnosticsStore.directoryURL)
            }
            settingsController.onDiagnosticsReport = {
                try await Task.detached {
                    DiagnosticsCommands.Report.format(
                        try diagnosticsStore.report(),
                        retentionDays: diagnosticsStore.retentionDays
                    )
                }.value
            }
            settingsController.onPermissionsRefresh = { permissions in
                recordDiagnostic(OperationalDiagnosticEvent(
                    severity: permissions.globalInputReady ? .info : .warning,
                    name: "permissions.snapshot",
                    sessionID: appSessionID,
                    attributes: [
                        "accessibility": String(
                            permissions.accessibilityGranted
                        ),
                        "input_monitoring": String(
                            permissions.inputMonitoringGranted
                        ),
                        "microphone": String(
                            permissions.microphone == .granted
                        ),
                    ]
                ))
                guard permissions.globalInputReady else {
                    if readiness.hotkeyReady {
                        monitor.stop()
                        readiness.hotkeyReady = false
                    }
                    menuBar.setFailure("permissions needed · open Settings")
                    return
                }
                guard !readiness.hotkeyReady else {
                    return
                }
                do {
                    try startHotkeyMonitor()
                    readiness.hotkeyReady = true
                    if readiness.modelReady {
                        menuBar.setReady()
                    } else {
                        menuBar.setLoadingModel(chosenModel.id)
                    }
                } catch {
                    FileHandle.standardError.write(Data(
                        "permission recovery failed: \(error)\n".utf8
                    ))
                    menuBar.setFailure("permissions needed · open Settings")
                }
            }
            coordinator.onStateChange = { state in
                switch state {
                case .idle:
                    overlay?.hide()
                    menuBar.setRecording(false)
                case .recording:
                    FileHandle.standardError.write(Data("● recording\n".utf8))
                    audioCues.play(.start)
                    let target = currentTranscriptTarget()
                    Task {
                        await processor.prepare(target: target)
                    }
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
                    String(
                        format: "→ %.2fs · %d characters\n",
                        elapsed,
                        text.count
                    ).utf8
                ))
                dictionary.rememberLatestTranscript(text)
                menuBar.setHasLatestTranscript(true)
            }
            coordinator.onQualityAudio = { sample in
                guard settingsController.settings.qualityAudioRetentionEnabled else {
                    return
                }
                let retentionDays = settingsController.settings.qualityAudioRetentionDays
                let maximumBytes = settingsController.settings.qualityAudioMaximumBytes
                Task.detached {
                    do {
                        _ = try qualityAudioArchive.store(sample)
                        recordDiagnostic(OperationalDiagnosticEvent(
                            severity: .info,
                            name: "quality_audio.stored",
                            sessionID: appSessionID,
                            attributes: [
                                "transcript_id":
                                    sample.transcriptID.uuidString.lowercased()
                            ]
                        ))
                        if let cutoff = Calendar.current.date(
                            byAdding: .day,
                            value: -retentionDays,
                            to: Date()
                        ) {
                            try qualityAudioArchive.prune(olderThan: cutoff)
                        }
                        _ = try qualityAudioArchive.enforceMaximumBytes(
                            maximumBytes
                        )
                    } catch {
                        recordDiagnostic(OperationalDiagnosticEvent(
                            severity: .error,
                            name: "quality_audio.failed",
                            sessionID: appSessionID,
                            attributes: [
                                "transcript_id":
                                    sample.transcriptID.uuidString.lowercased(),
                                "reason": String(describing: error),
                            ]
                        ))
                        FileHandle.standardError.write(Data(
                            "quality audio archive failed: \(error)\n".utf8
                        ))
                    }
                }
            }
            coordinator.onProcessingDuration = { elapsed in
                FileHandle.standardError.write(Data(
                    String(format: "  local formatting %.2fs\n", elapsed).utf8
                ))
            }
            coordinator.onStreamingFinalizationDuration = { elapsed in
                FileHandle.standardError.write(Data(
                    String(format: "  streaming finalization %.2fs\n", elapsed).utf8
                ))
            }
            coordinator.onRecordingLimitReached = {
                recordDiagnostic(OperationalDiagnosticEvent(
                    severity: .warning,
                    name: "recording.limit_reached",
                    sessionID: appSessionID
                ))
                FileHandle.standardError.write(Data(
                    "recording reached the 10-minute safety limit; processing captured audio\n".utf8
                ))
                menuBar.setFailure("10-minute limit reached · processing")
            }
            coordinator.onHistoryChange = {
                history.reloadIfVisible()
            }
        }

        MainActor.assumeIsolated {
            menuBar.setLoadingModel(chosenModel.id)
        }
        do {
            try startHotkeyMonitor()
            MainActor.assumeIsolated {
                readiness.hotkeyReady = true
            }
            recordDiagnostic(OperationalDiagnosticEvent(
                severity: .info,
                name: "hotkey.ready",
                sessionID: appSessionID,
                attributes: ["binding_count": String(settings.hotkeys.count)]
            ))
        } catch {
            recordDiagnostic(OperationalDiagnosticEvent(
                severity: .error,
                name: "hotkey.failed",
                sessionID: appSessionID,
                attributes: ["reason": String(describing: error)]
            ))
            FileHandle.standardError.write(Data("failed to register hotkey tap: \(error)\n".utf8))
            FileHandle.standardError.write(Data("run `wordhand setup` to configure permissions.\n".utf8))
            if isBundledApplication {
                MainActor.assumeIsolated {
                    menuBar.setFailure("permissions needed · open Settings")
                    settingsController.showSettings()
                }
            } else {
                throw ExitCode(1)
            }
        }

        modelWarmupTask = Task { @MainActor in
            let warmupStarted = ProcessInfo.processInfo.systemUptime
            do {
                try await transcriber.warmUp()
                if let quarantineCutoff = Calendar.current.date(
                    byAdding: .day,
                    value: -30,
                    to: Date()
                ) {
                    try recoveryJournal.pruneQuarantine(
                        olderThan: quarantineCutoff
                    )
                }
                let pendingCaptures = try recoveryJournal.recoverableCaptures()
                for pendingCapture in pendingCaptures {
                    let recovered = await coordinator.recover(pendingCapture)
                    guard recovered else { break }
                    try recoveryJournal.discard(id: pendingCapture.id)
                }
                if settingsController.settings.performanceMode == .maximum {
                    await processor.prepare(target: currentTranscriptTarget())
                }
                readiness.modelReady = true
                if readiness.hotkeyReady, coordinator.state == .idle {
                    menuBar.setReady()
                }
                recordDiagnostic(OperationalDiagnosticEvent(
                    severity: .info,
                    name: "model.warmup_completed",
                    sessionID: appSessionID,
                    metrics: [
                        "warmup_seconds":
                            ProcessInfo.processInfo.systemUptime - warmupStarted
                    ],
                    attributes: ["model_id": chosenModel.id]
                ))
            } catch {
                recordDiagnostic(OperationalDiagnosticEvent(
                    severity: .error,
                    name: "model.warmup_failed",
                    sessionID: appSessionID,
                    metrics: [
                        "warmup_seconds":
                            ProcessInfo.processInfo.systemUptime - warmupStarted
                    ],
                    attributes: [
                        "model_id": chosenModel.id,
                        "reason": String(describing: error),
                    ]
                ))
                FileHandle.standardError.write(Data("warmup failed: \(error)\n".utf8))
                if coordinator.state == .idle {
                    menuBar.setFailure("model unavailable · open Settings")
                }
            }
        }
        diagnosticsHeartbeatTask = Task { @MainActor in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 3_600_000_000_000)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                let processInfo = ProcessInfo.processInfo
                recordDiagnostic(OperationalDiagnosticEvent(
                    severity: .info,
                    name: "app.heartbeat",
                    sessionID: appSessionID,
                    metrics: [
                        "app_uptime_seconds":
                            processInfo.systemUptime - appStartedAt
                    ],
                    attributes: [
                        "hotkey_ready": String(readiness.hotkeyReady),
                        "model_ready": String(readiness.modelReady),
                        "low_power_mode": String(
                            processInfo.isLowPowerModeEnabled
                        ),
                        "thermal_state": String(
                            describing: processInfo.thermalState
                        ),
                    ]
                ))
            }
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

        let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigterm.setEventHandler {
            monitor.stop()
            NSApp.terminate(nil)
        }
        sigterm.resume()
        signal(SIGTERM, SIG_IGN)

        let shortcuts = settings.hotkeys.map {
            let behavior = $0.action == .toggleRecording ? "tap" : "hold"
            return "\($0.displayName) \(behavior)"
        }.joined(separator: ", ")
        let hotkeyReady = MainActor.assumeIsolated {
            readiness.hotkeyReady
        }
        let runtimeStatus = hotkeyReady
            ? "listening on \(shortcuts)"
            : "app open; global shortcut unavailable"
        FileHandle.standardError.write(Data(
            "\(runtimeStatus) · model: \(chosenModel.id) · ^C to quit\n".utf8
        ))
        withExtendedLifetime((
            instanceLock,
            globalInputTestTimer,
            modelWarmupTask,
            diagnosticsHeartbeatTask,
            sigterm,
            appDelegate,
            diagnosticsStore
        )) {
            app.run()
        }
    }
}

struct Quality: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "quality",
        abstract: "Manage the private, local transcription Quality Lab.",
        subcommands: [
            Status.self,
            Enable.self,
            Disable.self,
            Clear.self,
            QualityEvaluate.self,
        ]
    )

    struct Status: ParsableCommand {
        func run() throws {
            let settings = try SettingsStore(
                fileURL: SettingsStore.defaultFileURL()
            ).load()
            let archive = LocalQualityAudioArchive()
            let report = try archive.storageReport()
            print(
                settings.qualityAudioRetentionEnabled
                    ? "enabled · \(settings.qualityAudioRetentionDays)-day retention"
                    : "disabled"
            )
            print("recordings: \(report.recordingCount)")
            print(
                "storage: \(Self.bytes(report.totalBytes)) / "
                    + "\(Self.bytes(settings.qualityAudioMaximumBytes))"
            )
            print("location: \(archive.directoryURL.path)")
        }

        private static func bytes(_ count: Int64) -> String {
            ByteCountFormatter.string(
                fromByteCount: count,
                countStyle: .file
            )
        }
    }

    struct Enable: ParsableCommand {
        @Option(name: .long, help: "Automatically delete audio after 1–90 days.")
        var retentionDays: Int = 7

        func validate() throws {
            guard (1...90).contains(retentionDays) else {
                throw ValidationError("--retention-days must be from 1 through 90.")
            }
        }

        func run() throws {
            let store = SettingsStore(fileURL: SettingsStore.defaultFileURL())
            var settings = try store.load()
            settings.qualityAudioRetentionEnabled = true
            settings.qualityAudioRetentionDays = retentionDays
            try store.save(settings)
            print("Quality Lab enabled locally with \(retentionDays)-day retention.")
            print("Relaunch Wordhand if it is currently open.")
        }
    }

    struct Disable: ParsableCommand {
        func run() throws {
            let store = SettingsStore(fileURL: SettingsStore.defaultFileURL())
            var settings = try store.load()
            settings.qualityAudioRetentionEnabled = false
            try store.save(settings)
            print("Quality Lab disabled. Existing recordings were left in place.")
            print("Relaunch Wordhand if it is currently open.")
        }
    }

    struct Clear: ParsableCommand {
        @Flag(name: .long, help: "Confirm permanent deletion of retained audio.")
        var confirm: Bool = false

        func run() throws {
            guard confirm else {
                throw ValidationError("Pass --confirm to permanently delete retained audio.")
            }
            try LocalQualityAudioArchive().deleteAll()
            print("Deleted all locally retained Quality Lab audio.")
        }
    }
}

struct Format: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "format",
        abstract: "Preview Wordhand's local writing styles without recording audio."
    )

    @Argument(help: "Dictated text to format.")
    var text: String

    @Option(
        name: .long,
        help: "casual, formatted, professional, or aiCommunication."
    )
    var style: String = TranscriptFormattingProfile.formatted.rawValue

    @Option(name: .long, help: "Application context used by the local formatter.")
    var application: String = "the current application"

    func run() throws {
        guard let profile = TranscriptFormattingProfile(rawValue: style) else {
            FileHandle.standardError.write(Data(
                "unknown style: \(style)\nuse casual, formatted, professional, or aiCommunication\n"
                    .utf8
            ))
            throw ExitCode(1)
        }

        let processor = AppAwareTranscriptProcessor(
            dictionaryProcessor: MutableTranscriptProcessor(),
            profile: profile
        )
        let target = TranscriptTarget(
            bundleIdentifier: nil,
            applicationName: application
        )
        let semaphore = DispatchSemaphore(value: 0)
        var output = ""
        Task {
            output = await processor.process(text, target: target)
            semaphore.signal()
        }
        semaphore.wait()
        print(output)
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
        subcommands: [List.self, Download.self, Benchmark.self, AuthorityCompare.self]
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

        @Flag(
            name: .long,
            help: "Condition decoding with the current user's local editable dictionary."
        )
        var userDictionary: Bool = false

        @Option(
            name: .long,
            help: "Comma-separated vocabulary terms for a controlled conditioning benchmark."
        )
        var vocabularyTerms: String?

        @Flag(
            name: .long,
            help: "Exercise the rolling Maximum Performance path without recording or playback."
        )
        var streaming: Bool = false

        func run() throws {
            let modelID = model ?? ModelRegistry.recommended()?.id
            guard let modelID, let selectedModel = ModelRegistry.find(modelID) else {
                FileHandle.standardError.write(Data("unknown model: \(model ?? "none")\n".utf8))
                throw ExitCode(1)
            }

            let vocabularySelectionCount = [
                defaultVocabulary,
                userDictionary,
                vocabularyTerms != nil,
            ].filter(\.self).count
            guard vocabularySelectionCount <= 1 else {
                throw ValidationError(
                    "Choose only one vocabulary source: --default-vocabulary, "
                        + "--user-dictionary, or --vocabulary-terms."
                )
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
            } else if userDictionary {
                let document = try DictionaryStore(
                    fileURL: DictionaryStore.defaultFileURL()
                ).installBundledDefaults()
                vocabulary = DictionaryVocabularySource(entries: document.entries)
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
                    let transcript: String
                    var finalizationDuration: TimeInterval?
                    if streaming {
                        await transcriber.beginStreaming(
                            configuration: StreamingTranscriptionConfiguration()
                        )
                        let chunkSize = Int(AudioCapture.targetSampleRate / 2)
                        var chunkStart = 0
                        while chunkStart < audio.count {
                            let chunkEnd = min(chunkStart + chunkSize, audio.count)
                            await transcriber.appendStreamingAudio(
                                Array(audio[chunkStart..<chunkEnd])
                            )
                            chunkStart = chunkEnd
                            if chunkStart < audio.count {
                                // Feed the local fixture at 4× real time so
                                // multiple rolling decodes complete without audio
                                // playback or a minute-long wall-clock wait.
                                try await Task.sleep(nanoseconds: 125_000_000)
                            }
                        }
                        let streamingResult = try await transcriber.finishStreaming(
                            finalAudio: audio
                        )
                        transcript = streamingResult.text
                        finalizationDuration = streamingResult.finalizationDuration
                    } else {
                        transcript = try await transcriber.transcribe(audio)
                    }
                    let transcriptionDuration =
                        ProcessInfo.processInfo.systemUptime - transcriptionStarted
                    resultBox.store(.success(ModelBenchmarkResult(
                        transcript: transcript,
                        warmupDuration: warmupDuration,
                        transcriptionDuration: transcriptionDuration,
                        finalizationDuration: finalizationDuration
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
            print("path: \(streaming ? "rolling maximum" : "full buffer")")
            print(String(format: "audio: %.2fs", audioDuration))
            print(String(format: "warmup: %.3fs", result.warmupDuration))
            print(String(format: "transcription: %.3fs", result.transcriptionDuration))
            if let finalizationDuration = result.finalizationDuration {
                print(String(format: "stop-to-final: %.3fs", finalizationDuration))
            }
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
    let finalizationDuration: TimeInterval?
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

struct OverlayPreview: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "overlay-preview",
        abstract: "Show the safe visual overlay preview without audio or global input."
    )

    @Option(name: .long, help: "recording, processing, or finishing.")
    var state: String = "processing"

    @Option(name: .long, help: "Preview duration from 1 through 10 seconds.")
    var seconds: Int = 4

    func validate() throws {
        guard (1...10).contains(seconds) else {
            throw ValidationError("--seconds must be from 1 through 10.")
        }
        guard ["recording", "processing", "finishing"].contains(state) else {
            throw ValidationError("--state must be recording, processing, or finishing.")
        }
    }

    func run() throws {
        let overlayState: RecordingOverlay.State
        switch state {
        case "recording":
            overlayState = .recording
        case "finishing":
            overlayState = .finishing
        default:
            overlayState = .transcribing
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let overlay = MainActor.assumeIsolated {
            let overlay = RecordingOverlay()
            overlay.show(overlayState)
            return overlay
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds)) {
            MainActor.assumeIsolated {
                overlay.hide()
                app.terminate(nil)
            }
        }
        withExtendedLifetime(overlay) {
            app.run()
        }
    }
}
