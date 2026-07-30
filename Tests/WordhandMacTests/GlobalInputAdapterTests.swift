import AppKit
import Foundation
import Testing
import WordhandCore
@testable import wordhand

@Suite
struct GlobalInputAdapterTests {
    @Test
    func hotkeyMonitorUsesInjectedTapAndStopsItWithoutInstallingAGlobalTap() throws {
        let controller = FakeHotkeyTapController()
        let installer = FakeHotkeyTapInstaller(controller: controller)
        let monitor = HotkeyMonitor(
            bindings: [
                HotkeyBinding(
                    key: "z",
                    keyCode: 6,
                    modifiers: ["control", "option"],
                    action: .toggleRecording
                ),
            ],
            tapInstaller: installer
        )

        try monitor.start { _ in }
        #expect(installer.installCount == 1)
        #expect(!controller.didStop)

        monitor.stop()
        #expect(controller.didStop)
    }

    @Test
    func textInserterUsesInjectedPosterWithoutPostingSyntheticEvents() async throws {
        let poster = FakeTextEventPoster()
        let inserter = MacTextInserter(
            eventPoster: poster,
            observer: FakeTextInsertionObserver(results: [.unavailable]),
            secureInputEnabled: { false }
        )

        try await inserter.insert("local only", mode: .unicode)

        #expect(poster.unicodeTexts == ["local only"])
        #expect(poster.pasteShortcutCount == 0)
    }

    @Test
    func pasteRetriesOnceAfterAConfirmedNoOpAndCreatesSafeUndo() async throws {
        let poster = FakeTextEventPoster()
        let checkpoint = TextInsertionCheckpoint(
            id: UUID(),
            selection: NSRange(location: 4, length: 0)
        )
        let token = TextInsertionUndoToken(
            checkpointID: checkpoint.id,
            insertedRange: NSRange(location: 4, length: 5),
            expectedSelection: NSRange(location: 9, length: 0)
        )
        let observer = FakeTextInsertionObserver(
            checkpoint: checkpoint,
            results: [.unchanged, .verified(token)]
        )
        let inserter = MacTextInserter(
            eventPoster: poster,
            observer: observer,
            secureInputEnabled: { false }
        )

        try await inserter.insert("hello", mode: .paste)

        #expect(poster.pasteShortcutCount == 2)
        #expect(inserter.canUndoLastInsertion)
        try inserter.undoLastInsertion()
        #expect(observer.undoTokens == [token])
        #expect(!inserter.canUndoLastInsertion)
    }

    @Test
    func terminalPasteDoesNotDuplicateWhenAccessibilityCursorIsUnchanged() async throws {
        let poster = FakeTextEventPoster()
        let observer = FakeTextInsertionObserver(
            checkpoint: TextInsertionCheckpoint(
                id: UUID(),
                selection: NSRange(location: 0, length: 0),
                allowsAutomaticPasteRetry: false
            ),
            results: [.unchanged]
        )
        let inserter = MacTextInserter(
            eventPoster: poster,
            observer: observer,
            secureInputEnabled: { false }
        )

        try await inserter.insert("hello", mode: .paste)

        #expect(poster.pasteShortcutCount == 1)
        #expect(!inserter.canUndoLastInsertion)
    }

    @Test
    func pasteFailsHonestlyWhenTheRetryIsAlsoANoOp() async {
        let poster = FakeTextEventPoster()
        let observer = FakeTextInsertionObserver(
            checkpoint: TextInsertionCheckpoint(
                id: UUID(),
                selection: NSRange(location: 0, length: 0)
            ),
            results: [.unchanged, .unchanged]
        )
        let inserter = MacTextInserter(
            eventPoster: poster,
            observer: observer,
            secureInputEnabled: { false }
        )

        await #expect(throws: TextInsertionError.self) {
            try await inserter.insert("hello", mode: .paste)
        }
        #expect(poster.pasteShortcutCount == 2)
        #expect(!inserter.canUndoLastInsertion)
    }

    @Test
    func acknowledgedSelectionReplacementDoesNotOfferDestructiveUndo() async throws {
        let poster = FakeTextEventPoster()
        let observer = FakeTextInsertionObserver(
            checkpoint: TextInsertionCheckpoint(
                id: UUID(),
                selection: NSRange(location: 4, length: 8)
            ),
            results: [.verifiedWithoutUndo]
        )
        let inserter = MacTextInserter(
            eventPoster: poster,
            observer: observer,
            secureInputEnabled: { false }
        )

        try await inserter.insert("hello", mode: .paste)

        #expect(poster.pasteShortcutCount == 1)
        #expect(!inserter.canUndoLastInsertion)
    }

    @Test
    @MainActor
    func settingsLaunchAtLoginToggleUsesInjectedManager() throws {
        let manager = FakeLaunchAtLoginManager(state: .disabled)
        let permissions = FakePermissionManager()
        let fixture = try TemporarySettingsFixture()
        defer { fixture.remove() }
        let controller = SettingsController(
            store: fixture.store,
            settings: AppSettings(),
            launchAtLoginManager: manager,
            permissionManager: permissions
        )

        controller.setLaunchAtLogin(true)

        #expect(manager.setEnabledValues == [true])
        #expect(controller.launchAtLoginState == .enabled)
        #expect(controller.launchAtLoginError == nil)
    }

    @Test
    @MainActor
    func settingsLaunchAtLoginOpensApprovalPanelWhenRequired() throws {
        let manager = FakeLaunchAtLoginManager(state: .disabled)
        manager.nextEnabledState = .requiresApproval
        let permissions = FakePermissionManager()
        let fixture = try TemporarySettingsFixture()
        defer { fixture.remove() }
        let controller = SettingsController(
            store: fixture.store,
            settings: AppSettings(),
            launchAtLoginManager: manager,
            permissionManager: permissions
        )

        controller.setLaunchAtLogin(true)

        #expect(controller.launchAtLoginState == .requiresApproval)
        #expect(manager.openSettingsCount == 1)
    }

    @Test
    @MainActor
    func settingsWindowIsResizableAndCanShowMoreContent() throws {
        _ = NSApplication.shared
        let autosaveName = "Wordhand.Settings.Tests.\(UUID().uuidString)"
        let autosaveKey = "NSWindow Frame \(autosaveName)"
        defer { UserDefaults.standard.removeObject(forKey: autosaveKey) }
        let fixture = try TemporarySettingsFixture()
        defer { fixture.remove() }
        var controller: SettingsController? = SettingsController(
            store: fixture.store,
            settings: AppSettings(),
            launchAtLoginManager: FakeLaunchAtLoginManager(state: .disabled),
            permissionManager: FakePermissionManager(),
            frameAutosaveName: autosaveName
        )

        let window = try #require(controller?.ensureWindowController().window)

        #expect(window.title == "Settings")
        #expect(window.styleMask.contains(.resizable))
        #expect(window.minSize == NSSize(width: 620, height: 440))
        #expect(window.contentView?.frame.size == NSSize(width: 760, height: 620))

        window.setContentSize(NSSize(width: 900, height: 700))
        #expect(window.contentView?.frame.size == NSSize(width: 900, height: 700))

        let expectedSavedFrame = window.frameDescriptor
        window.close()
        #expect(UserDefaults.standard.string(forKey: autosaveKey) == expectedSavedFrame)
        controller = nil

        let restoredController = SettingsController(
            store: fixture.store,
            settings: AppSettings(),
            launchAtLoginManager: FakeLaunchAtLoginManager(state: .disabled),
            permissionManager: FakePermissionManager(),
            frameAutosaveName: autosaveName
        )
        let restoredWindow = try #require(restoredController.ensureWindowController().window)
        defer { restoredWindow.close() }
        #expect(restoredWindow.contentView?.frame.size == NSSize(width: 900, height: 700))
    }

    @Test
    @MainActor
    func qualityLabStorageLimitSavesImmediately() throws {
        let fixture = try TemporarySettingsFixture()
        defer { fixture.remove() }
        let controller = SettingsController(
            store: fixture.store,
            settings: AppSettings(),
            launchAtLoginManager: FakeLaunchAtLoginManager(state: .disabled),
            permissionManager: FakePermissionManager()
        )

        controller.setQualityAudioMaximumBytes(5_000_000_000)

        #expect(controller.settings.qualityAudioMaximumBytes == 5_000_000_000)
        #expect(try fixture.store.load().qualityAudioMaximumBytes == 5_000_000_000)
    }

    @Test
    @MainActor
    func settingsPermissionRefreshPublishesRecoveryState() throws {
        let permissions = FakePermissionManager()
        permissions.currentStatus = WordhandPermissionStatus(
            accessibilityGranted: false,
            inputMonitoringGranted: false,
            microphone: .granted
        )
        let fixture = try TemporarySettingsFixture()
        defer { fixture.remove() }
        let controller = SettingsController(
            store: fixture.store,
            settings: AppSettings(),
            launchAtLoginManager: FakeLaunchAtLoginManager(state: .disabled),
            permissionManager: permissions
        )
        var observed: WordhandPermissionStatus?
        controller.onPermissionsRefresh = { observed = $0 }
        permissions.currentStatus.accessibilityGranted = true
        permissions.currentStatus.inputMonitoringGranted = true

        controller.refreshPermissions()

        #expect(controller.permissionStatus.isReady)
        #expect(observed?.isReady == true)
    }

    @Test
    func permissionReadinessRequiresInputMonitoring() {
        let status = WordhandPermissionStatus(
            accessibilityGranted: true,
            inputMonitoringGranted: false,
            microphone: .granted
        )

        #expect(!status.isReady)
        #expect(!status.globalInputReady)
    }

    @Test
    @MainActor
    func settingsCanRepairInputMonitoringPermission() throws {
        let permissions = FakePermissionManager()
        permissions.currentStatus.inputMonitoringGranted = false
        let fixture = try TemporarySettingsFixture()
        defer { fixture.remove() }
        let controller = SettingsController(
            store: fixture.store,
            settings: AppSettings(),
            launchAtLoginManager: FakeLaunchAtLoginManager(state: .disabled),
            permissionManager: permissions
        )

        controller.repairInputMonitoringPermission()

        #expect(permissions.inputMonitoringRequestCount == 1)
        #expect(permissions.inputMonitoringSettingsCount == 1)
    }

    @Test
    @MainActor
    func modelChangeExposesInlineRelaunchUntilTheActiveModelIsRestored() throws {
        let fixture = try TemporarySettingsFixture()
        defer { fixture.remove() }
        let activeModelID = "whisper-large-v3"
        let controller = SettingsController(
            store: fixture.store,
            settings: AppSettings(modelID: activeModelID),
            launchAtLoginManager: FakeLaunchAtLoginManager(state: .disabled),
            permissionManager: FakePermissionManager(),
            activeModelID: activeModelID
        )
        var relaunchCount = 0
        controller.onRelaunchRequested = { relaunchCount += 1 }

        #expect(!controller.requiresRelaunch)
        controller.setModelID("whisper-large-v3-turbo")
        #expect(controller.requiresRelaunch)
        controller.relaunch()
        #expect(relaunchCount == 1)

        controller.setModelID(activeModelID)
        #expect(!controller.requiresRelaunch)
    }

    @Test
    func localWhisperModelRequiresEveryCompiledComponent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wordhand-model-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let modelID = "test-model"
        let modelFolder = directory
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml")
            .appendingPathComponent(modelID)
        try FileManager.default.createDirectory(
            at: modelFolder,
            withIntermediateDirectories: true
        )
        for entry in [
            "config.json",
            "MelSpectrogram.mlmodelc",
            "AudioEncoder.mlmodelc",
            "TextDecoder.mlmodelc",
        ] {
            try FileManager.default.createDirectory(
                at: modelFolder.appendingPathComponent(entry),
                withIntermediateDirectories: true
            )
        }

        #expect(
            WhisperModelStorage.localModelFolder(
                modelID: modelID,
                downloadBase: directory
            )?.standardizedFileURL.path == modelFolder.standardizedFileURL.path
        )

        try FileManager.default.removeItem(
            at: modelFolder.appendingPathComponent("TextDecoder.mlmodelc")
        )
        #expect(
            WhisperModelStorage.localModelFolder(
                modelID: modelID,
                downloadBase: directory
            ) == nil
        )
    }

    @Test
    func longTranscriptionUsesSilenceAwareChunkingWithoutVocabulary() {
        let options = WhisperKitTranscriber.makeDecodingOptions(promptTokens: nil)

        #expect(options.promptTokens == nil)
        #expect(options.chunkingStrategy == .vad)
    }

    @Test
    func writingStylesUseDistinctLocalRewriteInstructions() async {
        let rewriter = RecordingLocalTranscriptRewriter(
            responses: [
                "Formatted Valyou request with 3 requirements.",
                "Professional Valyou request with 3 requirements.",
                "AI-ready Valyou request with 3 requirements.",
            ]
        )
        let processor = AppAwareTranscriptProcessor(
            dictionaryProcessor: MutableTranscriptProcessor(),
            profile: .formatted,
            rewriter: rewriter
        )
        let original = "Valyou request with 3 requirements"
        let target = TranscriptTarget(
            bundleIdentifier: "com.apple.Terminal",
            applicationName: "Terminal"
        )

        let formatted = await processor.process(original, target: target)
        processor.update(profile: .professional)
        let professional = await processor.process(original, target: target)
        processor.update(profile: .aiCommunication)
        let aiCommunication = await processor.process(original, target: target)
        let calls = await rewriter.recordedCalls()

        #expect(formatted == "Formatted Valyou request with 3 requirements.")
        #expect(professional == "Professional Valyou request with 3 requirements.")
        #expect(aiCommunication == "AI-ready Valyou request with 3 requirements.")
        #expect(calls.count == 3)
        #expect(calls[0].instructions.contains("natural tone"))
        #expect(calls[1].instructions.contains("professional communication"))
        #expect(calls[2].instructions.contains("excellent input for an AI agent"))
        #expect(calls.allSatisfy { $0.instructions.contains("Never answer") })
        #expect(calls.allSatisfy { $0.instructions.contains("who must act") })
        #expect(calls.allSatisfy { $0.instructions.contains("modality") })
        #expect(calls.allSatisfy { $0.timeoutSeconds == 8 })
    }

    @Test
    func aiCommunicationPreservesProseWhenTheSourceIsNotAList() async {
        let prose = """
        The application is working well. I think accuracy should remain the priority. \
        The only open question is whether latency can improve.
        """
        let rewriter = RecordingLocalTranscriptRewriter(responses: [prose])
        let processor = AppAwareTranscriptProcessor(
            dictionaryProcessor: MutableTranscriptProcessor(),
            profile: .aiCommunication,
            rewriter: rewriter
        )

        let output = await processor.process(prose, target: .unknown)
        let calls = await rewriter.recordedCalls()

        #expect(output == prose)
        #expect(!output.contains("- The"))
        #expect(calls[0].instructions.contains("paragraphs for connected reasoning"))
        #expect(calls[0].instructions.contains("numbered steps only for a true sequence"))
    }

    @Test
    func maximumPerformancePrewarmsTheSelectedStyle() async {
        let rewriter = RecordingLocalTranscriptRewriter(responses: [])
        let processor = AppAwareTranscriptProcessor(
            dictionaryProcessor: MutableTranscriptProcessor(),
            profile: .professional,
            performanceMode: .maximum,
            rewriter: rewriter
        )
        let target = TranscriptTarget(
            bundleIdentifier: "com.mitchellh.ghostty",
            applicationName: "Ghostty"
        )

        await processor.prepare(target: target)

        let prewarms = await rewriter.recordedPrewarms()
        #expect(prewarms.count == 1)
        #expect(prewarms[0].contains("professional communication"))
        #expect(prewarms[0].contains("Ghostty"))
    }

    @Test
    func unsafeProfessionalRewriteFallsBackWithoutDroppingConstraints() async {
        let rewriter = RecordingLocalTranscriptRewriter(
            responses: ["Ship it.", "Ship it."]
        )
        let processor = AppAwareTranscriptProcessor(
            dictionaryProcessor: MutableTranscriptProcessor(),
            profile: .professional,
            rewriter: rewriter
        )

        let output = await processor.process(
            "Do not remove API v2 or the 30-day rollback",
            target: .unknown
        )

        #expect(output == "Do not remove API v2 or the 30-day rollback.")
    }
}

private final class FakeHotkeyTapController: HotkeyTapControlling {
    private(set) var didStop = false

    func setEnabled(_ enabled: Bool) {}

    func stop() {
        didStop = true
    }
}

private final class FakeHotkeyTapInstaller: HotkeyTapInstalling {
    let controller: FakeHotkeyTapController
    private(set) var installCount = 0

    init(controller: FakeHotkeyTapController) {
        self.controller = controller
    }

    func install(for monitor: HotkeyMonitor) throws -> any HotkeyTapControlling {
        installCount += 1
        return controller
    }
}

private final class FakeTextEventPoster: TextEventPosting, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var unicodeTexts: [String] = []
    private(set) var pasteShortcutCount = 0

    func postUnicode(_ text: String) {
        lock.withLock {
            unicodeTexts.append(text)
        }
    }

    func postPasteShortcut() throws {
        lock.withLock {
            pasteShortcutCount += 1
        }
    }
}

private final class FakeTextInsertionObserver: TextInsertionObserving, @unchecked Sendable {
    private let lock = NSLock()
    private let checkpoint: TextInsertionCheckpoint?
    private var results: [TextInsertionVerification]
    private(set) var undoTokens: [TextInsertionUndoToken] = []

    init(
        checkpoint: TextInsertionCheckpoint? = nil,
        results: [TextInsertionVerification]
    ) {
        self.checkpoint = checkpoint
        self.results = results
    }

    func captureCheckpoint() -> TextInsertionCheckpoint? {
        checkpoint
    }

    func verify(
        _ checkpoint: TextInsertionCheckpoint,
        insertedUTF16Count: Int
    ) -> TextInsertionVerification {
        lock.withLock {
            results.isEmpty ? .unavailable : results.removeFirst()
        }
    }

    func undo(_ token: TextInsertionUndoToken) throws {
        lock.withLock {
            undoTokens.append(token)
        }
    }
}

private actor RecordingLocalTranscriptRewriter: LocalTranscriptRewriting {
    struct Call: Sendable {
        var text: String
        var instructions: String
        var maximumResponseTokens: Int
        var timeoutSeconds: UInt64
    }

    private var responses: [String]
    private var calls: [Call] = []
    private var prewarms: [String] = []

    init(responses: [String]) {
        self.responses = responses
    }

    func prewarm(instructions: String) {
        prewarms.append(instructions)
    }

    func rewrite(
        _ text: String,
        instructions: String,
        maximumResponseTokens: Int,
        timeoutSeconds: UInt64
    ) async throws -> String {
        calls.append(Call(
            text: text,
            instructions: instructions,
            maximumResponseTokens: maximumResponseTokens,
            timeoutSeconds: timeoutSeconds
        ))
        return responses.removeFirst()
    }

    func recordedCalls() -> [Call] {
        calls
    }

    func recordedPrewarms() -> [String] {
        prewarms
    }
}

private final class FakeLaunchAtLoginManager: LaunchAtLoginManaging {
    let isAvailable = true
    private var currentState: LaunchAtLoginState
    var nextEnabledState: LaunchAtLoginState = .enabled
    private(set) var setEnabledValues: [Bool] = []
    private(set) var openSettingsCount = 0

    init(state: LaunchAtLoginState) {
        self.currentState = state
    }

    func state() -> LaunchAtLoginState {
        currentState
    }

    func setEnabled(_ enabled: Bool) throws {
        setEnabledValues.append(enabled)
        currentState = enabled ? nextEnabledState : .disabled
    }

    func openSystemSettings() {
        openSettingsCount += 1
    }
}

private final class FakePermissionManager: PermissionManaging {
    var currentStatus = WordhandPermissionStatus(
        accessibilityGranted: true,
        inputMonitoringGranted: true,
        microphone: .granted
    )
    private(set) var accessibilityRequestCount = 0
    private(set) var accessibilitySettingsCount = 0
    private(set) var inputMonitoringRequestCount = 0
    private(set) var inputMonitoringSettingsCount = 0
    private(set) var microphoneSettingsCount = 0

    func status() -> WordhandPermissionStatus {
        currentStatus
    }

    func requestAccessibility() {
        accessibilityRequestCount += 1
    }

    func requestInputMonitoring() {
        inputMonitoringRequestCount += 1
    }

    func requestMicrophone() async -> Bool {
        currentStatus.microphone = .granted
        return true
    }

    func openAccessibilitySettings() {
        accessibilitySettingsCount += 1
    }

    func openInputMonitoringSettings() {
        inputMonitoringSettingsCount += 1
    }

    func openMicrophoneSettings() {
        microphoneSettingsCount += 1
    }
}

private struct TemporarySettingsFixture {
    let directory: URL
    let store: SettingsStore

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wordhand-login-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        store = SettingsStore(fileURL: directory.appendingPathComponent("settings.json"))
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
